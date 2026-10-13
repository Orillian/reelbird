@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
import ReelbirdCore
import UniformTypeIdentifiers
import VideoToolbox

/// Renders the edited recording to a file.
///
/// Pipeline: `AVAssetReader` decodes (hardware, ahead of use) → the Metal compositor renders straight into
/// the encoder's IOSurface pixel buffers (up to 3 frames in flight on the GPU) → `AVAssetWriter` encodes with
/// VideoToolbox. Audio is mixed and encoded to AAC on its own thread. Decode, render and encode overlap.
public enum Exporter {
    /// Exports and returns the file URL. Cancel the calling task to stop; the partial file is removed.
    /// `progress` (0...1) is called from a background thread.
    public static func export(bundle: ProjectBundle, edit: EditDocument, options: ExportOptions,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let manifest = try bundle.readManifest()
        let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: edit)
        guard plan.duration > 0.02 else { throw RenderError.nothingToExport }
        let withAudio = options.format != .gif
        if withAudio, edit.audio.enhance, !edit.audio.microphoneMuted {
            // The enhanced voice for these settings (usually already rendered by the editor). If it can't be made, the
            // export still goes ahead with the last stem or the raw microphone.
            do { try await VoiceStem.ensure(bundle: bundle, settings: edit.audio) } catch is CancellationError { throw CancellationError() } catch {}
        }
        let sources = try await MediaSources.load(bundle: bundle, manifest: manifest, audio: edit.audio)
        guard sources.screen != nil else { throw RenderError.missingScreenTrack }
        let url = try destination(bundle: bundle, manifest: manifest, edit: edit, options: options)
        var analysis: AudioAnalysis?
        if withAudio, !sources.audio.isEmpty {
            analysis = await AudioAnalyzer.analysis(bundle: bundle, settings: edit.audio)
        }
        let job = try ExportJob(plan: plan, sources: sources, options: options, url: url, analysis: analysis, progress: progress)
        return try await withTaskCancellationHandler {
            try await job.run()
        } onCancel: {
            job.cancel()
        }
    }

    /// Output size and frame rate for these options.
    static func outputGeometry(plan: RenderPlan, options: ExportOptions) -> (size: PixelSize, fps: Int) {
        var height = options.height ?? plan.edit.canvas.outputHeight
        var fps = options.frameRate ?? plan.frameRate
        if options.format == .gif {
            height = options.height ?? min(540, plan.canvasSize.height)
            fps = min(50, options.frameRate ?? 15)
        }
        let size = RenderPlan.canvasSize(source: plan.sourceSize, aspect: plan.edit.canvas.aspect, height: height)
        return (size, max(1, min(240, fps)))
    }

    /// The output file: `options.destination` if it names a file; inside it, with the default name, if it
    /// names a folder; otherwise `<bundle>/exports/<name>.<ext>`.
    ///
    /// The name is the title, plus the export time unless the title already carries a date (the default
    /// "Reelbird 2026-10-12 at 16.09.51" bundle name), so names never repeat the date. Collisions get " 2",
    /// " 3", ….
    static func destination(bundle: ProjectBundle, manifest: ProjectManifest, edit: EditDocument, options: ExportOptions,
                            now: Date = Date()) throws -> URL {
        var folder = bundle.exportsURL
        if let d = options.destination {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: d.path, isDirectory: &isDir)
            guard (exists && isDir.boolValue) || (!exists && d.hasDirectoryPath) else { return d }
            folder = d
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var title = (edit.title?.isEmpty == false ? edit.title! : manifest.title)
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = "Reelbird" }
        if title.count > 80 { title = String(title.prefix(80)) }
        var base = title
        if title.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) == nil {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            base = "\(title) \(f.string(from: now))"
        }
        var url = folder.appendingPathComponent("\(base).\(options.format.fileExtension)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).\(options.format.fileExtension)")
            n += 1
        }
        return url
    }

    /// A temporary file to write into, moved to `url` only when the export succeeds, so a failed or
    /// cancelled export never leaves a half-written file behind. It lives in the system's replacement
    /// folder on the same volume (not next to `url`), because privacy-protected folders such as Downloads
    /// only let the app write the file the person chose.
    static func partialURL(for url: URL) -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                               appropriateFor: url.deletingLastPathComponent(), create: true))
            ?? fm.temporaryDirectory
        return dir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).\(UUID().uuidString.prefix(8)).partial.\(url.pathExtension)")
    }

    /// Average bitrate: ~10 Mbit/s for 1080p30 H.264, scaled by pixel count and √(fps/30). HEVC needs ~65%.
    static func bitrate(size: PixelSize, fps: Int, hevc: Bool) -> Int {
        let pixels = Double(size.width * size.height) / (1920.0 * 1080.0)
        let rate = 10_000_000 * pixels * (Double(fps) / 30).squareRoot() * (hevc ? 0.65 : 1)
        return Int(max(1_000_000, min(200_000_000, rate)))
    }
}

/// One export run. Owns its threads; all state below is touched by one thread at a time.
final class ExportJob: @unchecked Sendable {
    let plan: RenderPlan
    let sources: MediaSources
    let options: ExportOptions
    /// Final destination; the job writes to `partial` and renames on success.
    let finalURL: URL
    let url: URL
    let progress: @Sendable (Double) -> Void
    let size: PixelSize
    let fps: Int
    /// Voice loudness for auto level.
    let analysis: AudioAnalysis?
    private let cancelled = Atomic()
    private let ctx: MetalContext

    init(plan: RenderPlan, sources: MediaSources, options: ExportOptions, url: URL, analysis: AudioAnalysis? = nil,
         progress: @escaping @Sendable (Double) -> Void) throws {
        self.plan = plan; self.sources = sources; self.options = options; self.progress = progress; self.analysis = analysis
        finalURL = url
        self.url = Exporter.partialURL(for: url)
        (size, fps) = Exporter.outputGeometry(plan: plan, options: options)
        ctx = try MetalContext.shared()
    }

    func cancel() { cancelled.set() }

    /// Removes the per-export replacement folder `partialURL` created (never the shared temp folder).
    private func removeScratchFolder() {
        let dir = url.deletingLastPathComponent()
        guard dir.lastPathComponent.hasPrefix("NSIRD") else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    func run() async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, any Error>) in
            let t = Thread { [self] in
                do {
                    if options.format == .gif { try runGIF() } else { try runVideo() }
                    if cancelled.isSet { throw CancellationError() }
                    let fm = FileManager.default
                    if fm.fileExists(atPath: finalURL.path) {
                        _ = try fm.replaceItemAt(finalURL, withItemAt: url)
                    } else {
                        try fm.moveItem(at: url, to: finalURL)
                    }
                    removeScratchFolder()
                    cont.resume(returning: finalURL)
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    removeScratchFolder()
                    cont.resume(throwing: cancelled.isSet ? CancellationError() : error)
                }
            }
            t.qualityOfService = .userInitiated
            t.name = "Reelbird export"
            t.start()
        }
    }

    // MARK: Video

    private func videoSettings() -> [String: Any] {
        // Frames hold sRGB values (screens are captured in sRGB), so the file says so: BT.709 primaries and
        // matrix with the sRGB (IEC 61966-2-1) transfer. Tagging the transfer as BT.709 instead makes
        // QuickTime, Safari and AVFoundation apply Apple's 1.96 video gamma and show sRGB 128 as 139 (measured):
        // the washed-out "QuickTime gamma shift". Chrome and Firefox honour transfer 13 as well.
        let color: [String: Any] = MediaSources.sdrColorProperties
        var s: [String: Any] = [AVVideoWidthKey: size.width, AVVideoHeightKey: size.height, AVVideoColorPropertiesKey: color]
        switch options.format {
        case .mp4H264:
            s[AVVideoCodecKey] = AVVideoCodecType.h264
            s[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Exporter.bitrate(size: size, fps: fps, hevc: false),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoAllowFrameReorderingKey: true,
            ] as [String: Any]
        case .mp4HEVC:
            s[AVVideoCodecKey] = AVVideoCodecType.hevc
            var props: [String: Any] = [
                AVVideoAverageBitRateKey: Exporter.bitrate(size: size, fps: fps, hevc: true),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoAllowFrameReorderingKey: true,
            ]
            // Above 1080p60 the HEVC engine is the bottleneck; speed priority lifts 4K60 from ~63 to ~107 fps
            // on M4 Pro (measured), and the bitrate is generous enough that quality holds.
            if size.width * size.height * fps > 1920 * 1080 * 60 {
                props[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] = true
            }
            s[AVVideoCompressionPropertiesKey] = props
        case .proRes:
            s[AVVideoCodecKey] = AVVideoCodecType.proRes422
        case .gif:
            break
        }
        return s
    }

    private struct InFlight {
        let commandBuffer: any MTLCommandBuffer
        let pixelBuffer: CVPixelBuffer
        let index: Int
        let keep: [CVMetalTexture]
        let sources: [CMSampleBuffer]
    }

    private func runVideo() throws {
        let comp = try sources.composition(timeline: plan.timeline, camera: plan.showsCamera, audio: plan.edit.audio, analysis: analysis)
        guard let screenTrack = comp.screen else { throw RenderError.missingScreenTrack }
        try? FileManager.default.removeItem(at: url)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: options.format == .proRes ? .mov : .mp4) } catch {
            throw RenderError.writerFailed(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = options.format != .proRes
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings())
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
        ])
        guard writer.canAdd(vIn) else { throw RenderError.writerFailed("video input rejected") }
        writer.add(vIn)

        var aIn: AVAssetWriterInput?
        let mix = comp.audioMix(forPlayback: false)
        if mix != nil {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
            ])
            a.expectsMediaDataInRealTime = false
            if writer.canAdd(a) { writer.add(a); aIn = a }
        }

        // Readers: one for video tracks, one for audio, so neither stalls waiting for the other.
        let vReader: AVAssetReader
        do { vReader = try AVAssetReader(asset: comp.asset) } catch { throw RenderError.readerFailed(error.localizedDescription) }
        let screenOut = AVAssetReaderTrackOutput(track: screenTrack, outputSettings: sources.decodeSettings(for: .screen))
        screenOut.alwaysCopiesSampleData = false
        vReader.add(screenOut)
        var cameraOut: AVAssetReaderTrackOutput?
        if let ct = comp.camera {
            let o = AVAssetReaderTrackOutput(track: ct, outputSettings: sources.decodeSettings(for: .camera))
            o.alwaysCopiesSampleData = false
            vReader.add(o)
            cameraOut = o
        }
        var aReader: AVAssetReader?
        var aOut: AVAssetReaderAudioMixOutput?
        if let aIn, let mix {
            let r = try AVAssetReader(asset: comp.asset)
            // Stretched sound can run a little past the last piece (the stretcher's tail). The mix output still hands
            // out whole buffers past this range; `MixFinisher` cuts the sound at the picture's last frame exactly.
            r.timeRange = CMTimeRange(start: .zero, duration: MediaSources.time(comp.duration))
            let o = AVAssetReaderAudioMixOutput(audioTracks: comp.audio.map(\.track), audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            o.audioMix = mix.mix
            o.audioTimePitchAlgorithm = MediaSources.timePitch // speed segments keep the voice's pitch
            r.add(o)
            aReader = r; aOut = o
            _ = aIn
        }

        guard writer.startWriting() else { throw RenderError.writerFailed(writer.error?.localizedDescription ?? "start failed") }
        writer.startSession(atSourceTime: .zero)
        guard vReader.startReading() else { throw RenderError.readerFailed(vReader.error?.localizedDescription ?? "start failed") }

        // The picture is `total` whole frames; the file and its sound end exactly where the last one does.
        let total = max(1, Int((comp.duration * Double(fps)).rounded(.down)))
        let end = CMTime(value: CMTimeValue(total), timescale: CMTimeScale(fps))

        // Audio on its own thread: per-track gain and limiting happen in the mix's taps; the finisher limits
        // the sum, removes the limiters' look-ahead delay and makes the sound exactly as long as the picture.
        let audioDone = DispatchSemaphore(value: 0)
        let audioError = Box<(any Error)?>(nil)
        if let aReader, let aOut, let aIn, let mix {
            let captured = Unchecked((aReader, aOut, aIn, writer, mix.processors))
            let t = Thread { [self] in
                let (aReader, aOut, aIn, writer, processors) = captured.value
                defer { audioDone.signal() }
                guard aReader.startReading() else {
                    audioError.value = RenderError.readerFailed(aReader.error?.localizedDescription ?? "audio")
                    aIn.markAsFinished()
                    return
                }
                let finisher = MixFinisher(sampleRate: 48_000, channels: 2, length: MixFinisher.frames(end.seconds, sampleRate: 48_000))
                func append(_ sb: CMSampleBuffer) -> Bool {
                    while !aIn.isReadyForMoreMediaData, !cancelled.isSet, writer.status == .writing { usleep(300) }
                    if cancelled.isSet || writer.status != .writing { return false }
                    return aIn.append(sb)
                }
                var ok = true
                while ok, !finisher.isComplete, !cancelled.isSet, writer.status == .writing {
                    guard let sb = aOut.copyNextSampleBuffer() else { break }
                    for out in finisher.process(sb) where ok { ok = append(out) }
                }
                if aReader.status == .failed {
                    audioError.value = RenderError.readerFailed(aReader.error?.localizedDescription ?? "audio")
                } else if ok, !cancelled.isSet {
                    if aReader.status == .reading { aReader.cancelReading() } // the rest is past the end
                    for out in finisher.finish() where ok { ok = append(out) }
                }
                withExtendedLifetime(processors) {}
                aIn.markAsFinished()
            }
            t.qualityOfService = .userInitiated
            t.name = "Reelbird export audio"
            t.start()
        } else {
            audioDone.signal()
        }

        // Video: decode → render → encode, pipelined.
        guard let queue = ctx.device.makeCommandQueue(maxCommandBufferCount: 8) else { throw RenderError.metalUnavailable }
        let compositor = Compositor(context: ctx, queue: queue)
        let screenSteps = FrameStepper(screenOut)
        let cameraSteps = cameraOut.map(FrameStepper.init)
        let tolerance = 0.5 / Double(fps)
        var inflight: [InFlight] = []
        inflight.reserveCapacity(4)
        var lastReported = -1

        func drainOne() throws {
            let f = inflight.removeFirst()
            f.commandBuffer.waitUntilCompleted()
            if f.commandBuffer.status == .error {
                throw RenderError.writerFailed("GPU: \(f.commandBuffer.error?.localizedDescription ?? "render failed")")
            }
            while !vIn.isReadyForMoreMediaData {
                if cancelled.isSet { return }
                if writer.status == .failed { throw RenderError.writerFailed(writer.error?.localizedDescription ?? "encoder failed") }
                usleep(200)
            }
            if !adaptor.append(f.pixelBuffer, withPresentationTime: CMTime(value: Int64(f.index), timescale: CMTimeScale(fps))) {
                throw RenderError.writerFailed(writer.error?.localizedDescription ?? "append failed")
            }
            let pct = (f.index + 1) * 100 / total
            if pct != lastReported { lastReported = pct; progress(Double(f.index + 1) / Double(total)) }
        }

        do {
            for n in 0..<total {
                if cancelled.isSet { break }
                try autoreleasepool {
                    let t = Double(n) / Double(fps)
                    let screenPB = screenSteps.frame(at: t, tolerance: tolerance)
                    let cameraPB = cameraSteps?.frame(at: t, tolerance: tolerance)
                    if vReader.status == .failed { throw RenderError.readerFailed(vReader.error?.localizedDescription ?? "decode failed") }
                    guard let pool = adaptor.pixelBufferPool else { throw RenderError.writerFailed(writer.error?.localizedDescription ?? "no pixel buffer pool") }
                    var out: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out)
                    guard let out, let tex = ctx.texture(out, plane: 0, format: .bgra8Unorm, renderTarget: true),
                          let target = CVMetalTextureGetTexture(tex), let cb = queue.makeCommandBuffer() else {
                        throw RenderError.writerFailed("couldn't allocate a frame")
                    }
                    let keep = compositor.encode(plan: plan, outputTime: t, screen: screenPB, camera: cameraPB, target: target,
                                                 frameInterval: 1 / Double(fps), commandBuffer: cb)
                    cb.commit()
                    var held: [CMSampleBuffer] = []
                    if let s = screenSteps.current { held.append(s) }
                    if let c = cameraSteps?.current { held.append(c) }
                    inflight.append(InFlight(commandBuffer: cb, pixelBuffer: out, index: n, keep: keep + [tex], sources: held))
                    if inflight.count >= 3 { try drainOne() }
                }
            }
            while !inflight.isEmpty, !cancelled.isSet { try drainOne() }
        } catch {
            cancelled.set()
            vReader.cancelReading(); aReader?.cancelReading()
            audioDone.wait()
            writer.cancelWriting()
            throw error
        }

        vIn.markAsFinished()
        audioDone.wait()
        if cancelled.isSet {
            vReader.cancelReading(); aReader?.cancelReading()
            writer.cancelWriting()
            throw CancellationError()
        }
        vReader.cancelReading()
        if let e = audioError.value { writer.cancelWriting(); throw e }
        writer.endSession(atSourceTime: end)
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed {
            throw RenderError.writerFailed(writer.error?.localizedDescription ?? "finish failed")
        }
        progress(1)
    }

    // MARK: GIF

    private func runGIF() throws {
        let comp = try sources.composition(timeline: plan.timeline, camera: plan.showsCamera, audio: nil)
        guard let screenTrack = comp.screen else { throw RenderError.missingScreenTrack }
        try? FileManager.default.removeItem(at: url)
        let reader = try AVAssetReader(asset: comp.asset)
        let screenOut = AVAssetReaderTrackOutput(track: screenTrack, outputSettings: sources.decodeSettings(for: .screen))
        screenOut.alwaysCopiesSampleData = false
        reader.add(screenOut)
        var cameraOut: AVAssetReaderTrackOutput?
        if let ct = comp.camera {
            let o = AVAssetReaderTrackOutput(track: ct, outputSettings: sources.decodeSettings(for: .camera))
            o.alwaysCopiesSampleData = false
            reader.add(o); cameraOut = o
        }
        guard reader.startReading() else { throw RenderError.readerFailed(reader.error?.localizedDescription ?? "start failed") }
        defer { reader.cancelReading() }

        let total = max(1, Int((comp.duration * Double(fps)).rounded(.down)))
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, total, nil) else {
            throw RenderError.writerFailed("can't create GIF")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let pool = try makePool(width: size.width, height: size.height)
        guard let queue = ctx.device.makeCommandQueue() else { throw RenderError.metalUnavailable }
        let compositor = Compositor(context: ctx, queue: queue)
        let screenSteps = FrameStepper(screenOut)
        let cameraSteps = cameraOut.map(FrameStepper.init)
        let tolerance = 0.5 / Double(fps)
        var pending: (any MTLCommandBuffer, CVPixelBuffer, Int, [CVMetalTexture])?

        func emit(_ p: (any MTLCommandBuffer, CVPixelBuffer, Int, [CVMetalTexture])) throws {
            p.0.waitUntilCompleted()
            guard let img = cgImage(from: p.1) else { throw RenderError.writerFailed("GIF frame") }
            // Delays are whole centiseconds; spread the rounding so the total duration stays exact.
            let cs = (Double(p.2 + 1) * 100 / Double(fps)).rounded() - (Double(p.2) * 100 / Double(fps)).rounded()
            let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: cs / 100,
                                                         kCGImagePropertyGIFUnclampedDelayTime: cs / 100]] as CFDictionary
            CGImageDestinationAddImage(dest, img, props)
            progress(Double(p.2 + 1) / Double(total))
        }

        for n in 0..<total {
            if cancelled.isSet { throw CancellationError() }
            try autoreleasepool {
                let t = Double(n) / Double(fps)
                let spb = screenSteps.frame(at: t, tolerance: tolerance)
                let cpb = cameraSteps?.frame(at: t, tolerance: tolerance)
                var out: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out)
                guard let out, let tex = ctx.texture(out, plane: 0, format: .bgra8Unorm, renderTarget: true),
                      let target = CVMetalTextureGetTexture(tex), let cb = queue.makeCommandBuffer() else {
                    throw RenderError.writerFailed("couldn't allocate a frame")
                }
                let keep = compositor.encode(plan: plan, outputTime: t, screen: spb, camera: cpb, target: target,
                                             frameInterval: 1 / Double(fps), commandBuffer: cb)
                cb.commit()
                if let p = pending { try emit(p) }
                pending = (cb, out, n, keep + [tex])
            }
        }
        if let p = pending { try emit(p) }
        guard CGImageDestinationFinalize(dest) else { throw RenderError.writerFailed("GIF finalize failed") }
    }
}

func makePool(width: Int, height: Int) throws -> CVPixelBufferPool {
    var pool: CVPixelBufferPool?
    let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
    ]
    CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary, attrs as CFDictionary, &pool)
    guard let pool else { throw RenderError.writerFailed("pixel buffer pool") }
    return pool
}

/// Copies a BGRA pixel buffer into a CGImage (sRGB).
func cgImage(from pb: CVPixelBuffer) -> CGImage? {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb),
          let ctx = CGContext(data: base, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb),
                              bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    return ctx.makeImage()
}

/// Hands non-Sendable AVFoundation objects to a thread that becomes their only user.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ v: T) { value = v }
}

/// A thread-safe flag.
final class Atomic: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// A lock-protected mutable box.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}
