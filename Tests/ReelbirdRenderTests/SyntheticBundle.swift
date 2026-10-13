@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import ReelbirdCore
import UniformTypeIdentifiers

/// Builds real `.reelbird` bundles from generated media (real AVAssetWriter files), independent of capture.
///
/// Screen: mid-grey with a black square covering the centre 10% × 10% (for zoom checks) and a white bar
/// moving along the top edge (so frames differ). Camera: solid green. Microphone: 440 Hz sine.
enum Synthetic {
    struct Options {
        var width = 1280
        var height = 720
        var fps = 30
        var seconds = 3.0
        var codec: AVVideoCodecType = .h264
        var camera = false
        var microphone = true
        /// Adds a 32×32 pt red square cursor image (hot spot top-left).
        var redCursor = false
        /// Pointer position for the whole recording (nil = a slow sweep with clicks).
        var stillPointer: NormPoint?
        var captureScale = 1.0
        /// Draws the screen frames instead of the default grey test card.
        var screen: Draw?
        /// Capture source written to the manifest (default: synthetic).
        var source: CaptureSource = .synthetic(name: "test")
        /// Replaces the generated pointer events.
        var events: [InputEvent]?
    }

    /// Y/Cb/Cr (video range) for the screen grey: RGB ≈ (128,128,128).
    static let greyYUV: (UInt8, UInt8, UInt8) = (126, 128, 128)
    static let greyRGB: (Int, Int, Int) = (128, 128, 128)

    static func makeBundle(_ o: Options = Options()) async throws -> ProjectBundle {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rb-render-\(UUID().uuidString).reelbird")
        let bundle = try ProjectBundle.create(at: dir)
        let fm = FileManager.default
        for k in [TrackKind.screen, .camera, .microphone] { try fm.createDirectory(at: bundle.directory(for: k), withIntermediateDirectories: true) }

        try await writeVideo(url: bundle.directory(for: .screen).appendingPathComponent("screen.mp4"), width: o.width, height: o.height,
                             fps: o.fps, seconds: o.seconds, codec: o.codec, draw: o.screen ?? drawScreen)
        var tracks = [TrackInfo(kind: .screen, directory: "screen", file: "screen/screen.mp4", codec: o.codec == .hevc ? "hevc" : "h264",
                                pixelSize: PixelSize(width: o.width, height: o.height), duration: o.seconds)]
        if o.camera {
            try await writeVideo(url: bundle.directory(for: .camera).appendingPathComponent("camera.mp4"), width: 640, height: 480,
                                 fps: 30, seconds: o.seconds, codec: .h264, draw: drawCamera)
            tracks.append(TrackInfo(kind: .camera, directory: "camera", file: "camera/camera.mp4", codec: "h264",
                                    pixelSize: PixelSize(width: 640, height: 480), duration: o.seconds))
        }
        if o.microphone {
            try await writeTone(url: bundle.directory(for: .microphone).appendingPathComponent("microphone.m4a"), seconds: o.seconds)
            tracks.append(TrackInfo(kind: .microphone, directory: "microphone", file: "microphone/microphone.m4a", codec: "aac",
                                    sampleRate: 48_000, channels: 1, duration: o.seconds))
        }

        let manifest = ProjectManifest(title: "Synthetic", appVersion: "test", status: .complete,
                                       capture: CaptureInfo(source: o.source, pixelSize: PixelSize(width: o.width, height: o.height),
                                                            scale: o.captureScale, frameRate: o.fps),
                                       clock: ClockInfo(originHostTime: 0), tracks: tracks, duration: o.seconds)
        try bundle.writeManifest(manifest)

        let log = try EventLogWriter(url: bundle.eventsURL)
        if o.redCursor { log.append(InputEvent(t: 0, type: .cursor, image: "red")) }
        if let events = o.events {
            events.forEach(log.append)
        } else if let p = o.stillPointer {
            log.append(.move(0, p))
        } else {
            var t = 0.0
            while t < o.seconds {
                log.append(.move(t, NormPoint(x: 0.2 + 0.6 * t / o.seconds, y: 0.4 + 0.1 * sin(t))))
                t += 1.0 / 60
            }
            log.append(.down(o.seconds * 0.4, NormPoint(x: 0.2 + 0.6 * 0.4, y: 0.4 + 0.1 * sin(o.seconds * 0.4))))
        }
        log.close()

        if o.redCursor {
            let side = 64
            let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let img = ctx.makeImage()!
            let dest = CGImageDestinationCreateWithURL(bundle.cursorsURL.appendingPathComponent("red.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
            let info = [CursorImageInfo(id: "red", hotX: 0, hotY: 0, width: 32, height: 32)]
            try JSONCoding.writeAtomically(info, to: bundle.cursorIndexURL)
        }
        return bundle
    }

    /// Fills an NV12 frame.
    typealias Draw = @Sendable (_ y: UnsafeMutablePointer<UInt8>, _ yStride: Int, _ uv: UnsafeMutablePointer<UInt8>, _ uvStride: Int,
                      _ w: Int, _ h: Int, _ frame: Int) -> Void

    static let drawScreen: Draw = { y, ys, uv, uvs, w, h, n in
        for r in 0..<h { memset(y + r * ys, Int32(greyYUV.0), w) }
        for r in 0..<(h / 2) { memset(uv + r * uvs, 128, w) }
        // Centre black square: 10% of each side.
        let x0 = Int(Double(w) * 0.45), x1 = Int(Double(w) * 0.55), y0 = Int(Double(h) * 0.45), y1 = Int(Double(h) * 0.55)
        for r in y0..<y1 { memset(y + r * ys + x0, 16, x1 - x0) }
        // Moving white bar along the top.
        let bw = max(8, w / 20), bh = max(4, h / 40)
        let bx = (n * max(1, w / 120)) % max(1, w - bw)
        for r in 0..<bh { memset(y + r * ys + bx, 235, bw) }
        // Busy "text" rows in the top-left quadrant for encoder realism.
        var seed = UInt32(12345)
        for row in stride(from: h / 10, to: h * 2 / 5, by: max(6, h / 60)) {
            var x = w / 20
            while x < w * 2 / 5 {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let len = 3 + Int(seed >> 28)
                for r in row..<min(h, row + max(2, h / 180)) { memset(y + r * ys + x, 40, min(len, w - x)) }
                x += len + 2 + Int((seed >> 24) & 3)
            }
        }
    }

    static let drawCamera: Draw = { y, ys, uv, uvs, w, h, n in
        // Green: Y 145, Cb 54, Cr 34 (video range, 709-ish).
        for r in 0..<h { memset(y + r * ys, 145, w) }
        for r in 0..<(h / 2) {
            let row = uv + r * uvs
            for c in stride(from: 0, to: w, by: 2) { row[c] = 54; row[c + 1] = 34 }
        }
        let sx = (n * 4) % w
        for r in 0..<h { y[r * ys + sx] = 200 }
    }

    static func writeVideo(url: URL, width: Int, height: Int, fps: Int, seconds: Double, codec: AVVideoCodecType, draw: Draw) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: fps, AVVideoAllowFrameReorderingKey: false],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let frames = Int(seconds * Double(fps))
        for n in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            guard let pb else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(pb, [])
            draw(CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRowOfPlane(pb, 0),
                 CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRowOfPlane(pb, 1),
                 width, height, n)
            CVPixelBufferUnlockBaseAddress(pb, [])
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            adaptor.append(pb, withPresentationTime: CMTime(value: Int64(n), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    static func writeTone(url: URL, seconds: Double) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
                                               mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &fmt)
        let total = Int(seconds * 48_000)
        let chunk = 4800
        var pos = 0
        while pos < total {
            let n = min(chunk, total - pos)
            var samples = [Float](repeating: 0, count: n)
            for i in 0..<n { samples[i] = 0.3 * sin(2 * .pi * 440 * Float(pos + i) / 48_000) }
            var bb: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n * 4, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: n * 4, flags: 0, blockBufferOut: &bb)
            samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb!, offsetIntoDestination: 0, dataLength: n * 4) }
            var sb: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: bb!, formatDescription: fmt!, sampleCount: n,
                                                                 presentationTimeStamp: CMTime(value: Int64(pos), timescale: 48_000),
                                                                 packetDescriptions: nil, sampleBufferOut: &sb)
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            input.append(sb!)
            pos += n
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}

/// RGBA8 pixels of a CGImage for assertions.
struct Pixels: CustomStringConvertible {
    var description: String { "Pixels(\(width)×\(height))" }
    let width: Int, height: Int
    let data: [UInt8]
    init(_ img: CGImage) {
        width = img.width; height = img.height
        var d = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &d, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
        data = d
    }
    subscript(x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * width + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }
    func near(_ x: Int, _ y: Int, _ c: (Int, Int, Int), tol: Int = 12) -> Bool {
        let p = self[x, y]
        return abs(p.r - c.0) <= tol && abs(p.g - c.1) <= tol && abs(p.b - c.2) <= tol
    }
}
