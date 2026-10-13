import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import ReelbirdCore
import Synchronization

/// Generates screen frames with moving content, an optional camera, and sine-wave audio on the host
/// clock. Used by tests and demos so the whole recording pipeline runs without Screen Recording permission.
public final class SyntheticFrameSource: FrameSource, @unchecked Sendable {
    public enum Mode: Sendable, Hashable {
        /// Frames and audio arrive at their real rate with live host-clock timestamps.
        case realTime
        /// Everything for `duration` seconds is generated back to back with virtual timestamps.
        case asFastAsPossible(duration: Double)
    }

    public enum AudioSignal: Sendable, Hashable {
        case sine(frequency: Double, amplitude: Double)
        case silence
        /// Mono 48 kHz samples played once from the start of the recording, then silence
        /// (e.g. synthesized speech for end-to-end transcription checks).
        case samples([Float])
    }

    public struct Configuration: Sendable {
        public var pixelSize = PixelSize(width: 1920, height: 1080)
        public var frameRate = 60
        /// `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (like ScreenCaptureKit) or `kCVPixelFormatType_32BGRA`.
        public var pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        public var microphone: AudioSignal? = .sine(frequency: 440, amplitude: 0.25)
        public var microphoneChannels = 1
        public var systemAudio: AudioSignal? = .sine(frequency: 660, amplitude: 0.2)
        public var camera: PixelSize?
        public var cameraFrameRate = 30
        public var mode: Mode = .realTime
        /// Frames per audio buffer (ScreenCaptureKit delivers about 10–20 ms).
        public var audioChunkFrames = 960
        /// Seconds (from the start) during which no system audio buffers are delivered at all, like
        /// ScreenCaptureKit while nothing is playing.
        public var systemAudioGaps: [TimeRange] = []
        /// Delay before `start` returns and the first frame arrives (a slow ScreenCaptureKit start).
        public var startDelay: Double = 0
        /// Fault injection: seconds added to every microphone timestamp, so the microphone looks like it
        /// runs on another clock (e.g. `-start` for a zero-based device clock).
        public var microphoneClockOffset: Double = 0
        /// Where the synthetic screen sits in global points (`capturedArea()`), so overlays such as the camera
        /// bubble can be placed against it. `nil` = not on a display.
        public var capturedArea: CGRect?
        public init() {}
    }

    public let configuration: Configuration
    private let sampleRate = 48_000.0
    private let videoQueue = DispatchQueue(label: "reelbird.synthetic.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "reelbird.synthetic.audio", qos: .userInteractive)
    private let cameraQueue = DispatchQueue(label: "reelbird.synthetic.camera", qos: .userInteractive)

    private struct RunState {
        var startHost: Double?
        var output: (any FrameSourceOutput)?
        var timers: [any DispatchSourceTimer] = []
        var running = false
        var finished = false
    }
    private let run = Mutex(RunState())

    private let screen: PatternRenderer
    private let camera: PatternRenderer?
    private var videoIndex: Int64 = -1
    private var cameraIndex: Int64 = -1
    private var audioFrames: Int64 = 0
    private let micFormat: CMAudioFormatDescription?
    private let systemFormat: CMAudioFormatDescription?
    /// Frames the generator itself skipped because its timer fired late (not the recorder's drops).
    public private(set) var sourceSkippedFrames = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        screen = PatternRenderer(size: configuration.pixelSize, pixelFormat: configuration.pixelFormat, text: true)
        camera = configuration.camera.map { PatternRenderer(size: $0, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, text: false) }
        micFormat = configuration.microphone == nil ? nil : Self.floatFormat(channels: configuration.microphoneChannels, rate: 48_000)
        systemFormat = configuration.systemAudio == nil ? nil : Self.floatFormat(channels: 2, rate: 48_000)
    }

    public func prepare() async throws -> FrameSourceFormat {
        var realTime = true
        if case .asFastAsPossible = configuration.mode { realTime = false }
        return FrameSourceFormat(
            source: .synthetic(name: "synthetic \(configuration.pixelSize.width)x\(configuration.pixelSize.height)@\(configuration.frameRate)"),
            pixelSize: configuration.pixelSize, scale: 1, frameRate: configuration.frameRate,
            hasMicrophone: configuration.microphone != nil, hasSystemAudio: configuration.systemAudio != nil,
            hasCamera: configuration.camera != nil, isRealTime: realTime)
    }

    public func start(output: any FrameSourceOutput) async throws {
        if configuration.startDelay > 0 { try await Task.sleep(nanoseconds: UInt64(configuration.startDelay * 1e9)) }
        let start = HostClock.now()
        run.withLock { $0.startHost = start; $0.output = output; $0.running = true }
        switch configuration.mode {
        case .realTime:
            var timers: [any DispatchSourceTimer] = []
            timers.append(makeTimer(queue: videoQueue, interval: 1.0 / Double(configuration.frameRate)) { [weak self] in
                self?.videoTick(start: start)
            })
            if micFormat != nil || systemFormat != nil {
                timers.append(makeTimer(queue: audioQueue, interval: 0.01) { [weak self] in self?.audioTick(start: start, upTo: HostClock.now()) })
            }
            if camera != nil {
                timers.append(makeTimer(queue: cameraQueue, interval: 1.0 / Double(configuration.cameraFrameRate)) { [weak self] in
                    self?.cameraTick(start: start)
                })
            }
            run.withLock { $0.timers = timers }
            // First frame immediately, like ScreenCaptureKit.
            videoQueue.async { [weak self] in self?.videoTick(start: start) }
        case .asFastAsPossible(let duration):
            videoQueue.async { [weak self] in self?.generateOffline(start: start, duration: duration) }
        }
    }

    public func stop() async {
        let timers = run.withLock { s -> [any DispatchSourceTimer] in
            s.running = false; s.output = nil
            defer { s.timers = [] }
            return s.timers
        }
        timers.forEach { $0.cancel() }
        // Drain in-flight callbacks so nothing arrives after stop returns.
        for q in [videoQueue, audioQueue, cameraQueue] { await withCheckedContinuation { c in q.async { c.resume() } } }
    }

    /// For `.asFastAsPossible`: waits until every frame has been delivered.
    public func waitUntilFinished() async {
        while !run.withLock({ $0.finished }) { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    public func capturedArea() -> CGRect? { configuration.capturedArea }

    public func simulatedPointer(atHostTime t: Double) -> NormPoint? {
        guard let start = run.withLock({ $0.startHost }) else { return nil }
        return PatternRenderer.boxCenter(at: t - start)
    }

    // MARK: Generation

    private var currentOutput: (any FrameSourceOutput)? { run.withLock { $0.running ? $0.output : nil } }

    private func videoTick(start: Double) {
        guard let out = currentOutput else { return }
        let fps = Double(configuration.frameRate)
        var n = videoIndex + 1
        let late = HostClock.now() - (start + Double(n) / fps)
        if late > 2 / fps {
            let jump = Int64(late * fps)
            sourceSkippedFrames += Int(jump)
            n += jump
        }
        videoIndex = n
        emitScreen(index: n, pts: start + Double(n) / fps, contentTime: Double(n) / fps, to: out)
    }

    private func cameraTick(start: Double) {
        guard let out = currentOutput, let camera else { return }
        let fps = Double(configuration.cameraFrameRate)
        cameraIndex += 1
        let pts = start + Double(cameraIndex) / fps
        if let pb = camera.render(contentTime: Double(cameraIndex) / fps), let sb = Self.videoSample(pb, pts: pts, fps: fps) {
            out.frameSource(didOutput: sb, of: .camera)
        }
    }

    private func audioTick(start: Double, upTo host: Double) {
        guard let out = currentOutput else { return }
        let target = Int64((host - start) * sampleRate)
        let chunk = Int64(configuration.audioChunkFrames)
        while audioFrames + chunk <= target {
            let pts = CMTime(value: Int64((start * sampleRate).rounded()) + audioFrames, timescale: CMTimeScale(sampleRate))
            let micPTS = configuration.microphoneClockOffset == 0 ? pts
                : CMTimeAdd(pts, CMTime(seconds: configuration.microphoneClockOffset, preferredTimescale: CMTimeScale(sampleRate)))
            if let s = configuration.microphone, let f = micFormat,
               let sb = makeAudio(signal: s, format: f, channels: configuration.microphoneChannels, firstFrame: audioFrames, count: Int(chunk), pts: micPTS) {
                out.frameSource(didOutput: sb, of: .microphone)
            }
            let chunkTime = Double(audioFrames) / sampleRate
            if let s = configuration.systemAudio, let f = systemFormat,
               !configuration.systemAudioGaps.contains(where: { $0.contains(chunkTime) }),
               let sb = makeAudio(signal: s, format: f, channels: 2, firstFrame: audioFrames, count: Int(chunk), pts: pts) {
                out.frameSource(didOutput: sb, of: .systemAudio)
            }
            audioFrames += chunk
        }
    }

    private func generateOffline(start: Double, duration: Double) {
        let fps = Double(configuration.frameRate)
        let total = Int64(duration * fps)
        var n: Int64 = 0
        var camN: Int64 = 0
        // The whole take is generated in one dispatch block, so drain autoreleased objects per frame
        // (a real source returns to its queue after every sample, which drains them).
        while n < total, let out = currentOutput {
            autoreleasepool {
                let t = Double(n) / fps
                audioTick(start: start, upTo: start + t + 0.02)
                if let camera {
                    let cfps = Double(configuration.cameraFrameRate)
                    while Double(camN) / cfps <= t {
                        if let pb = camera.render(contentTime: Double(camN) / cfps),
                           let sb = Self.videoSample(pb, pts: start + Double(camN) / cfps, fps: cfps) {
                            out.frameSource(didOutput: sb, of: .camera)
                        }
                        camN += 1
                    }
                }
                emitScreen(index: n, pts: start + t, contentTime: t, to: out)
            }
            n += 1
        }
        run.withLock { $0.finished = true }
    }

    private func emitScreen(index: Int64, pts: Double, contentTime: Double, to out: any FrameSourceOutput) {
        guard let pb = screen.render(contentTime: contentTime),
              let sb = Self.videoSample(pb, pts: pts, fps: Double(configuration.frameRate)) else { return }
        out.frameSource(didOutput: sb, of: .screen)
    }

    private func makeTimer(queue: DispatchQueue, interval: Double, _ handler: @escaping @Sendable () -> Void) -> any DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .microseconds(500))
        t.setEventHandler(handler: handler)
        t.resume()
        return t
    }

    // MARK: Sample buffers

    static func videoSample(_ pb: CVPixelBuffer, pts: Double, fps: Double) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
                                        presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 600_000),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sb)
        return sb
    }

    static func floatFormat(channels: Int, rate: Double) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)
        var f: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &f)
        return f
    }

    private func makeAudio(signal: AudioSignal, format: CMAudioFormatDescription, channels: Int,
                           firstFrame: Int64, count: Int, pts: CMTime) -> CMSampleBuffer? {
        let bytes = count * 4 * channels
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        var ptr: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &ptr)
        guard let raw = ptr else { return nil }
        raw.withMemoryRebound(to: Float.self, capacity: count * channels) { f in
            switch signal {
            case .silence:
                f.update(repeating: 0, count: count * channels)
            case .sine(let freq, let amp):
                let w = 2 * Double.pi * freq / sampleRate
                for i in 0..<count {
                    let v = Float(amp * sin(w * Double(firstFrame + Int64(i))))
                    for c in 0..<channels { f[c * count + i] = v }  // non-interleaved planes
                }
            case .samples(let pcm):
                for i in 0..<count {
                    let n = Int(firstFrame) + i
                    let v = n < pcm.count ? pcm[n] : 0
                    for c in 0..<channels { f[c * count + i] = v }
                }
            }
        }
        // Non-interleaved planes are laid out back to back in the block buffer.
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
            presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }
}

/// Draws a text-like background with a moving box into IOSurface-backed pixel buffers.
/// Only the box's old and new rectangles are redrawn per frame, so generation is cheap even at 4K.
final class PatternRenderer: @unchecked Sendable {
    let size: PixelSize
    let pixelFormat: OSType
    private var pool: CVPixelBufferPool?
    private var background: [[UInt8]] = []          // per plane, tightly packed
    private var planeBytesPerPixel: [Int] = []
    private var dirty: [IOSurfaceID: CGRect] = [:]

    init(size: PixelSize, pixelFormat: OSType, text: Bool) {
        self.size = size
        self.pixelFormat = pixelFormat
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 8] as CFDictionary, attrs as CFDictionary, &pool)
        buildBackground(text: text)
    }

    static func boxCenter(at t: Double) -> NormPoint {
        NormPoint(x: 0.5 + 0.35 * cos(2 * .pi * t / 4), y: 0.5 + 0.3 * sin(2 * .pi * t / 3))
    }

    private func buildBackground(text: Bool) {
        let w = size.width, h = size.height
        var rng: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt64 { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng }
        var luma = [UInt8](repeating: text ? 235 : 90, count: w * h)
        if text {
            // Lines of dark "glyphs" (rough stand-in for text-heavy screens).
            let lineH = max(8, h / 60)
            var y = lineH
            while y + lineH < h {
                var x = w / 20
                let lineEnd = w - Int(next() % UInt64(max(1, w / 3)))
                while x < lineEnd {
                    let gw = 3 + Int(next() % UInt64(max(4, lineH / 2)))
                    let gh = lineH * 2 / 3
                    let shade = UInt8(16 + Int(next() % 60))
                    for yy in y..<(y + gh) {
                        let row = yy * w
                        for xx in x..<min(w, x + gw) { luma[row + xx] = shade }
                    }
                    x += gw + 2 + (next() % 5 == 0 ? lineH / 2 : 0)
                }
                y += lineH * 3 / 2
            }
        }
        if pixelFormat == kCVPixelFormatType_32BGRA {
            var bgra = [UInt8](repeating: 255, count: w * h * 4)
            for i in 0..<(w * h) { let v = luma[i]; bgra[i * 4] = v; bgra[i * 4 + 1] = v; bgra[i * 4 + 2] = v }
            background = [bgra]
            planeBytesPerPixel = [4]
        } else {
            background = [luma, [UInt8](repeating: 128, count: (w / 2) * 2 * (h / 2))]
            planeBytesPerPixel = [1, 2]
        }
    }

    func render(contentTime t: Double) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let pb = out else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let side = Double(min(size.width, size.height)) / 6
        let c = Self.boxCenter(at: t)
        let box = CGRect(x: c.x * Double(size.width) - side / 2, y: c.y * Double(size.height) - side / 2, width: side, height: side)
            .integral.intersection(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        let surfaceID = CVPixelBufferGetIOSurface(pb).map { IOSurfaceGetID($0.takeUnretainedValue()) } ?? 0
        if let old = dirty[surfaceID] {
            restore(pb, rect: old)
        } else {
            restore(pb, rect: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        }
        // Colour cycles over time so every frame differs.
        let hue = t.truncatingRemainder(dividingBy: 3) / 3
        fill(pb, rect: box, y: UInt8(60 + 120 * hue), u: UInt8(64 + 128 * (1 - hue)), v: UInt8(200 - 100 * hue))
        dirty[surfaceID] = box
        return pb
    }

    private func restore(_ pb: CVPixelBuffer, rect: CGRect) {
        for plane in 0..<background.count {
            let (div, bpp) = plane == 0 ? (1, planeBytesPerPixel[0]) : (2, planeBytesPerPixel[1])
            let planeW = size.width / div
            guard let base = (background.count == 1 ? CVPixelBufferGetBaseAddress(pb) : CVPixelBufferGetBaseAddressOfPlane(pb, plane)) else { continue }
            let stride = background.count == 1 ? CVPixelBufferGetBytesPerRow(pb) : CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
            let x0 = Int(rect.minX) / div, x1 = min(planeW, Int(rect.maxX.rounded(.up)) / div + 1)
            let y0 = Int(rect.minY) / div, y1 = min(size.height / div, Int(rect.maxY.rounded(.up)) / div + 1)
            guard x1 > x0, y1 > y0 else { continue }
            background[plane].withUnsafeBytes { src in
                for y in y0..<y1 {
                    (base + y * stride + x0 * bpp).copyMemory(from: src.baseAddress! + (y * planeW + x0) * bpp, byteCount: (x1 - x0) * bpp)
                }
            }
        }
    }

    private func fill(_ pb: CVPixelBuffer, rect: CGRect, y: UInt8, u: UInt8, v: UInt8) {
        let x0 = Int(rect.minX), x1 = Int(rect.maxX), y0 = Int(rect.minY), y1 = Int(rect.maxY)
        guard x1 > x0, y1 > y0 else { return }
        if background.count == 1 {
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
            let stride = CVPixelBufferGetBytesPerRow(pb)
            let px: UInt32 = UInt32(255) << 24 | UInt32(v) << 16 | UInt32(y) << 8 | UInt32(u)
            for yy in y0..<y1 {
                (base + yy * stride + x0 * 4).bindMemory(to: UInt32.self, capacity: x1 - x0).update(repeating: px, count: x1 - x0)
            }
            return
        }
        guard let lb = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let cb = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return }
        let ls = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        for yy in y0..<y1 { memset(lb + yy * ls + x0, Int32(y), x1 - x0) }
        let uv = UInt16(v) << 8 | UInt16(u)
        for yy in (y0 / 2)..<(y1 / 2) {
            (cb + yy * cs + (x0 / 2) * 2).bindMemory(to: UInt16.self, capacity: (x1 - x0) / 2).update(repeating: uv, count: (x1 - x0) / 2)
        }
    }
}
