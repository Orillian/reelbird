import AVFoundation
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import Synchronization
import UniformTypeIdentifiers

/// Generates real H.264 + AAC media with AVAssetWriter: CMAF/HLS segments through the
/// segment delegate (exactly what the capture writer produces) or a fast-start MP4.
enum Synthetic {
    struct Options: Sendable {
        var width = 640
        var height = 360
        var fps = 30
        var seconds = 6.0
        var segmentSeconds = 2.0
        var title = "Reelbird test pattern"
        var bitrate = 1_200_000
    }

    struct Stream: Sendable {
        var initSegment: Data
        var segments: [(data: Data, duration: Double)]
        var totalDuration: Double { segments.reduce(0) { $0 + $1.duration } }
    }

    final class Collector: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var initData: Data?
        private var segments: [(Data, Double)] = []

        func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                         segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
            lock.lock(); defer { lock.unlock() }
            switch segmentType {
            case .initialization:
                initData = segmentData
            case .separable:
                let reports = segmentReport?.trackReports ?? []
                let d = (reports.first { $0.mediaType == .video } ?? reports.first)?.duration
                segments.append((segmentData, d.map { CMTimeGetSeconds($0) }.flatMap { $0.isFinite ? $0 : nil } ?? 2))
            @unknown default:
                break
            }
        }

        var result: Stream? {
            lock.lock(); defer { lock.unlock() }
            guard let initData else { return nil }
            return Stream(initSegment: initData, segments: segments.map { ($0.0, $0.1) })
        }
    }

    static func cmaf(_ o: Options = Options()) async throws -> Stream {
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: o.segmentSeconds, preferredTimescale: 600)
        writer.initialSegmentStartTime = .zero
        let collector = Collector()
        writer.delegate = collector
        try await write(writer, o)
        guard let s = collector.result else { throw CocoaError(.fileWriteUnknown) }
        return s
    }

    static func mp4(_ o: Options = Options(), to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        try await write(writer, o)
    }

    private static func write(_ writer: AVAssetWriter, _ o: Options) async throws {
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: o.width,
            AVVideoHeightKey: o.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: o.bitrate,
                AVVideoMaxKeyFrameIntervalKey: Int(Double(o.fps) * o.segmentSeconds),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: o.fps,
            ] as [String: Any],
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: o.width,
            kCVPixelBufferHeightKey as String: o.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ])
        audio.expectsMediaDataInRealTime = false
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let frames = Int(o.seconds * Double(o.fps))
        let sampleRate = 48_000
        let audioChunk = 1024
        let audioTotal = Int(o.seconds * Double(sampleRate))
        nonisolated(unsafe) let painter = Painter(o)
        let format = try audioFormat(sampleRate: sampleRate)

        // One requestMediaDataWhenReady pull per input, each on its own queue: AVAssetWriter then
        // interleaves without the two inputs ever waiting on each other (a single polling loop can
        // deadlock when both report not-ready).
        nonisolated(unsafe) let writerRef = writer
        nonisolated(unsafe) let videoRef = video, audioRef = audio, adaptorRef = adaptor
        let failure = Mutex<(any Error)?>(nil)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    nonisolated(unsafe) var frame = 0
                    nonisolated(unsafe) var done = false
                    videoRef.requestMediaDataWhenReady(on: DispatchQueue(label: "synthetic.video")) {
                        while videoRef.isReadyForMoreMediaData && !done {
                            if frame >= frames || writerRef.status != .writing {
                                done = true
                                videoRef.markAsFinished()
                                c.resume()
                                return
                            }
                            var pb: CVPixelBuffer?
                            if let pool = adaptorRef.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) }
                            guard let pb else {
                                failure.withLock { $0 = $0 ?? CocoaError(.fileWriteUnknown) }
                                done = true; videoRef.markAsFinished(); c.resume(); return
                            }
                            painter.draw(into: pb, time: Double(frame) / Double(o.fps))
                            if !adaptorRef.append(pb, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(o.fps))) {
                                failure.withLock { $0 = $0 ?? (writerRef.error ?? CocoaError(.fileWriteUnknown)) }
                                done = true; videoRef.markAsFinished(); c.resume(); return
                            }
                            frame += 1
                        }
                    }
                }
            }
            group.addTask {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    nonisolated(unsafe) var pos = 0
                    nonisolated(unsafe) var done = false
                    audioRef.requestMediaDataWhenReady(on: DispatchQueue(label: "synthetic.audio")) {
                        while audioRef.isReadyForMoreMediaData && !done {
                            if pos >= audioTotal || writerRef.status != .writing {
                                done = true; audioRef.markAsFinished(); c.resume(); return
                            }
                            let n = min(audioChunk, audioTotal - pos)
                            guard let sb = try? audioBuffer(format: format, start: pos, frames: n, sampleRate: sampleRate),
                                  audioRef.append(sb) else {
                                failure.withLock { $0 = $0 ?? (writerRef.error ?? CocoaError(.fileWriteUnknown)) }
                                done = true; audioRef.markAsFinished(); c.resume(); return
                            }
                            pos += n
                        }
                    }
                }
            }
        }
        if let e = failure.withLock({ $0 }) { throw e }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    private static func audioFormat(sampleRate: Int) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        let s = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                               magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        guard s == noErr, let fmt else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(s)) }
        return fmt
    }

    /// A short soft tick at the start of every second (440 Hz), silence otherwise.
    private static func audioBuffer(format: CMAudioFormatDescription, start: Int, frames: Int, sampleRate: Int) throws -> CMSampleBuffer {
        var samples = [Int16](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let n = start + i
            let inSecond = n % sampleRate
            if inSecond < sampleRate / 10 {
                let env = 1 - Double(inSecond) / Double(sampleRate / 10)
                let v = Int16(sin(2 * .pi * 440 * Double(n) / Double(sampleRate)) * 5000 * env)
                samples[i * 2] = v
                samples[i * 2 + 1] = v
            }
        }
        let bytes = samples.count * 2
        var block: CMBlockBuffer?
        var s = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                   customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                                   blockBufferOut: &block)
        guard s == noErr, let block else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(s)) }
        s = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        guard s == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(s)) }
        var sb: CMSampleBuffer?
        s = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                                 sampleCount: frames,
                                                                 presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(sampleRate)),
                                                                 packetDescriptions: nil, sampleBufferOut: &sb)
        guard s == noErr, let sb else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(s)) }
        return sb
    }

    /// Draws a warm test pattern: ink background, an amber dot sweeping across, a big timecode.
    final class Painter {
        let o: Options
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let big: CTFont
        let small: CTFont
        init(_ o: Options) {
            self.o = o
            let base = CTFontCreateUIFontForLanguage(.system, CGFloat(o.height) * 0.2, nil)!
            big = CTFontCreateCopyWithSymbolicTraits(base, CGFloat(o.height) * 0.2, nil, .traitBold, .traitBold) ?? base
            small = CTFontCreateUIFontForLanguage(.system, CGFloat(o.height) * 0.05, nil)!
        }

        func draw(into pb: CVPixelBuffer, time t: Double) {
            CVPixelBufferLockBaseAddress(pb, [])
            defer { CVPixelBufferUnlockBaseAddress(pb, []) }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            let W = CGFloat(w), H = CGFloat(h)
            ctx.setFillColor(CGColor(srgbRed: 0.09, green: 0.08, blue: 0.07, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            // Grid of faint columns that shift slowly, so motion is visible.
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.93, blue: 0.85, alpha: 0.04))
            let col = W / 12
            let shift = CGFloat(t.truncatingRemainder(dividingBy: 4) / 4) * col * 2
            var x = -col * 2 + shift
            while x < W { ctx.fill(CGRect(x: x, y: 0, width: col, height: H)); x += col * 2 }
            // Sweeping amber dot.
            let phase = CGFloat((sin(t * 1.3) + 1) / 2)
            let r = H * 0.06
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.553, blue: 0.302, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: W * 0.1 + phase * (W * 0.8 - 2 * r), y: H * 0.18, width: 2 * r, height: 2 * r))
            // Progress bar.
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.93, blue: 0.85, alpha: 0.12))
            ctx.fill(CGRect(x: W * 0.1, y: H * 0.12, width: W * 0.8, height: 3))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.553, blue: 0.302, alpha: 1))
            ctx.fill(CGRect(x: W * 0.1, y: H * 0.12, width: W * 0.8 * CGFloat(min(1, t / o.seconds)), height: 3))
            // Timecode.
            let secs = Int(t), tenths = Int((t - Double(secs)) * 10)
            let text = String(format: "%02d:%02d.%d", secs / 60, secs % 60, tenths)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): big,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0.97, green: 0.94, blue: 0.9, alpha: 1),
            ]))
            let bounds = CTLineGetImageBounds(line, ctx)
            ctx.textPosition = CGPoint(x: (W - bounds.width) / 2 - bounds.minX, y: H * 0.42)
            CTLineDraw(line, ctx)
            let label = CTLineCreateWithAttributedString(NSAttributedString(string: o.title, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): small,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0.97, green: 0.94, blue: 0.9, alpha: 0.55),
            ]))
            ctx.textPosition = CGPoint(x: W * 0.1, y: H * 0.82)
            CTLineDraw(label, ctx)
        }
    }
}
