import CoreMedia
import CoreVideo
import Foundation
import ReelbirdCore
import Synchronization
import VideoToolbox

/// The hot path: receives samples from the frame source on its queues, puts them on the recording
/// timeline and hands them to the writers. No actor hops, no allocation per video frame, and it never
/// blocks capture (a busy encoder means a dropped frame, counted in `metrics`).
final class CapturePipeline: FrameSourceOutput, @unchecked Sendable {
    struct Metrics: Sendable {
        var framesWritten = 0
        var droppedFrames = 0
        var lastScreenFrameHost = 0.0
        var lastScreenActivityHost = 0.0
        var lastScreenTime = 0.0
        var microphoneRMS: Float = 0
        var microphoneLastLoudHost = 0.0
        var microphoneLastSampleHost = 0.0
        var cameraFrames = 0
        var systemAudioBuffers = 0
    }

    let format: FrameSourceFormat
    let screenWriter: SegmentedWriter
    let microphone: AudioTrackFeed?
    let systemAudio: AudioTrackFeed?
    let composer: ShareComposer?
    let mixer: AudioMixer?
    let shareWriter: SegmentedWriter?
    private let cameraDirectory: URL

    private struct Timing {
        var origin: Double?
        var pauseStart: Double?
        var pauses: [TimeRange] = []
        var closed = false
        var waiter: CheckedContinuation<Double, any Error>?
    }
    private let timing = Mutex(Timing())

    private struct Screen {
        var last: CVPixelBuffer?
        var lastAppendHost = 0.0
        var conformer: FrameConformer?
    }
    private let screen = Locked(Screen())

    private struct Camera {
        var writer: SegmentedWriter?
        var failed = false
    }
    private let camera = Locked(Camera())

    let metrics = Mutex(Metrics())
    private var filler: (any DispatchSourceTimer)?
    private let fillerQueue = DispatchQueue(label: "reelbird.capture.filler", qos: .userInitiated)

    /// Called once with the host time of the first screen frame (timeline zero).
    var onFirstFrame: (@Sendable (Double) -> Void)?
    var onSourceStopped: (@Sendable (any Error) -> Void)?
    /// Called when the camera writer is created (the session adds the track to the manifest).
    var onCameraStarted: (@Sendable (PixelSize) -> Void)?
    var onCameraError: (@Sendable (String) -> Void)?

    init(format: FrameSourceFormat, screenWriter: SegmentedWriter, microphone: AudioTrackFeed?, systemAudio: AudioTrackFeed?,
         cameraDirectory: URL, shareWriter: SegmentedWriter?, composer: ShareComposer?) {
        self.format = format
        self.screenWriter = screenWriter
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.cameraDirectory = cameraDirectory
        self.shareWriter = shareWriter
        self.composer = composer
        if let shareWriter {
            let inputs = (microphone != nil ? 1 : 0) + (systemAudio != nil ? 1 : 0)
            if inputs > 0 {
                let factory = PCMBufferFactory(channels: 2)
                let mixer = AudioMixer(inputs: inputs) { frame, samples, n in
                    if let sb = factory.make(frame: frame, samples: samples, frames: n) { shareWriter.append(audio: sb) }
                }
                self.mixer = mixer
                var input = 0
                if let microphone {
                    let i = input
                    microphone.tap = { f, s, n, c in mixer.add(input: i, frame: f, samples: s, frames: n, channels: c) }
                    input += 1
                }
                if let systemAudio {
                    let i = input
                    systemAudio.tap = { f, s, n, c in mixer.add(input: i, frame: f, samples: s, frames: n, channels: c) }
                }
            } else {
                mixer = nil
            }
        } else {
            mixer = nil
        }
    }

    var origin: Double? { timing.withLock { $0.origin } }
    var pauses: [TimeRange] { timing.withLock { $0.pauses } }
    var cameraWriter: SegmentedWriter? { camera.withLock { $0.writer } }

    /// Waits for the first screen frame and returns its host time.
    func waitForFirstFrame(timeout: Double) async throws -> Double {
        if let o = origin { return o }
        let timer = Task { [weak self] in
            try await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
            self?.timing.withLock { t in
                t.waiter?.resume(throwing: CaptureError.noFrames)
                t.waiter = nil
            }
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { c in
            let immediate = timing.withLock { t -> Double? in
                if let o = t.origin { return o }
                t.waiter = c
                return nil
            }
            if let immediate { c.resume(returning: immediate) }
        }
    }

    func isPaused(_ t: Double) -> Bool {
        timing.withLock { s in Self.paused(s, t) }
    }

    private static func paused(_ s: Timing, _ t: Double) -> Bool {
        if let p = s.pauseStart, t >= p { return true }
        return s.pauses.contains { $0.contains(t) }
    }

    // MARK: FrameSourceOutput

    func frameSource(didOutput sampleBuffer: CMSampleBuffer, of kind: MediaKind) {
        let host = sampleBuffer.presentationTimeStamp.seconds
        guard host.isFinite else { return }
        switch kind {
        case .screen: handleScreen(sampleBuffer, host: host)
        case .camera: handleCamera(sampleBuffer, host: host)
        case .microphone: handleAudio(sampleBuffer, host: host, feed: microphone, isMic: true)
        case .systemAudio: handleAudio(sampleBuffer, host: host, feed: systemAudio, isMic: false)
        }
    }

    func frameSourceScreenIsIdle() {
        let now = HostClock.now()
        metrics.withLock { $0.lastScreenActivityHost = now }
    }

    func frameSource(didStopWithError error: any Error) {
        onSourceStopped?(error)
    }

    private func handleScreen(_ sb: CMSampleBuffer, host: Double) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        var first = false
        let (origin, paused, closed) = timing.withLock { s -> (Double, Bool, Bool) in
            if s.origin == nil {
                s.origin = host
                first = true
            }
            let o = s.origin ?? host
            return (o, Self.paused(s, host - o), s.closed)
        }
        let now = HostClock.now()
        metrics.withLock { $0.lastScreenActivityHost = now; $0.lastScreenFrameHost = now }
        guard !closed else { return }
        let t = host - origin
        let frame = conform(pb)
        if paused {
            // Keep the newest picture so the video resumes on what's on screen at resume time.
            screen.withLock { $0.last = frame }
            composer?.update(screen: frame)
            return
        }
        let result = screenWriter.append(pixelBuffer: frame, at: t)
        screen.withLock { s in
            s.last = frame
            if result == .appended { s.lastAppendHost = now }
        }
        metrics.withLock { m in
            switch result {
            case .appended: m.framesWritten += 1; m.lastScreenTime = t
            case .notReady: m.droppedFrames += 1
            case .closed: break
            }
        }
        if let composer {
            composer.update(screen: frame)
            if !format.isRealTime { composer.tick(at: t) }
        }
        if first {
            if let waiter = timing.withLock({ s in defer { s.waiter = nil }; return s.waiter }) { waiter.resume(returning: origin) }
            onFirstFrame?(origin)
            if format.isRealTime {
                startFiller()
                composer?.startTimer(origin: origin) { [weak self] t in self?.isPaused(t) ?? true }
            }
        }
    }

    /// Scales frames whose size differs from the writer's (display mode change, window resize) back
    /// to the recording size, so the encoder never sees a size change.
    private func conform(_ pb: CVPixelBuffer) -> CVPixelBuffer {
        let target = format.pixelSize
        guard CVPixelBufferGetWidth(pb) != target.width || CVPixelBufferGetHeight(pb) != target.height else { return pb }
        return screen.withLock { s -> CVPixelBuffer in
            if s.conformer == nil { s.conformer = FrameConformer(size: target, pixelFormat: CVPixelBufferGetPixelFormatType(pb)) }
            return s.conformer?.conform(pb) ?? pb
        }
    }

    private func handleCamera(_ sb: CMSampleBuffer, host: Double) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let (origin, paused, closed) = timing.withLock { s -> (Double?, Bool, Bool) in
            guard let o = s.origin else { return (nil, false, s.closed) }
            return (o, Self.paused(s, host - o), s.closed)
        }
        guard let origin, !closed else { return }
        let t = host - origin
        guard t >= 0 else { return }
        composer?.update(camera: pb)
        guard !paused else { return }
        var created: PixelSize?
        let writer: SegmentedWriter? = camera.withLock { c in
            if c.writer == nil && !c.failed {
                let size = PixelSize(width: CVPixelBufferGetWidth(pb) & ~1, height: CVPixelBufferGetHeight(pb) & ~1)
                do {
                    let w = try SegmentedWriter(kind: .camera, directory: cameraDirectory,
                                                video: EncoderSettings.camera(size: size, frameRate: 30), audio: nil,
                                                realTime: format.isRealTime)
                    try w.start(at: 0)
                    // Hold the first picture from timeline zero so every track starts at 0.
                    if t > 0.001 { w.append(pixelBuffer: pb, at: 0) }
                    c.writer = w
                    created = size
                } catch {
                    c.failed = true
                    onCameraError?(error.localizedDescription)
                }
            }
            return c.writer
        }
        if let created { onCameraStarted?(created) }
        guard let writer else { return }
        if writer.append(pixelBuffer: pb, at: t) == .appended { metrics.withLock { $0.cameraFrames += 1 } }
    }

    private func handleAudio(_ sb: CMSampleBuffer, host: Double, feed: AudioTrackFeed?, isMic: Bool) {
        guard let feed else { return }
        let (origin, paused, closed) = timing.withLock { s -> (Double?, Bool, Bool) in
            guard let o = s.origin else { return (nil, false, s.closed) }
            return (o, Self.paused(s, host - o), s.closed)
        }
        guard let origin, !closed else { return }
        let rms = feed.ingest(sb, origin: origin, muted: paused)
        let now = HostClock.now()
        metrics.withLock { m in
            if isMic {
                m.microphoneLastSampleHost = now
                if let rms {
                    m.microphoneRMS = rms
                    if rms > HealthMonitor.silenceRMS { m.microphoneLastLoudHost = now }
                }
            } else {
                m.systemAudioBuffers += 1
            }
        }
    }

    // MARK: Control

    /// Starts a pause at host time `host`. Returns the timeline time.
    func pause(atHost host: Double) -> Double? {
        timing.withLock { s -> Double? in
            guard let o = s.origin, s.pauseStart == nil else { return nil }
            s.pauseStart = host - o
            return host - o
        }
    }

    /// Ends the pause and restarts the video with the newest picture at the resume point.
    func resume(atHost host: Double) -> TimeRange? {
        let range = timing.withLock { s -> TimeRange? in
            guard let o = s.origin, let p = s.pauseStart else { return nil }
            let r = TimeRange(start: p, end: max(p, host - o))
            s.pauses.append(r)
            s.pauseStart = nil
            return r
        }
        guard let range else { return nil }
        restartVideo(at: range.end)
        return range
    }

    private func restartVideo(at t: Double) {
        let last = screen.withLock { $0.last }
        if let last, screenWriter.append(pixelBuffer: last, at: t) == .appended {
            let now = HostClock.now()
            screen.withLock { $0.lastAppendHost = now }
        }
        composer?.resume(at: t)
    }

    /// Re-appends the last picture when the screen has been static for a second, so segments keep
    /// closing every ~2 s (bounded loss on a crash, steady live share) even when nothing changes.
    private func startFiller() {
        let t = DispatchSource.makeTimerSource(queue: fillerQueue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = HostClock.now()
            let (origin, paused, closed) = self.timing.withLock { s -> (Double?, Bool, Bool) in
                guard let o = s.origin else { return (nil, true, s.closed) }
                return (o, Self.paused(s, now - o), s.closed)
            }
            guard let origin, !paused, !closed else { return }
            let (last, lastAppend) = self.screen.withLock { ($0.last, $0.lastAppendHost) }
            guard let last, now - lastAppend > 1.0 else { return }
            if self.screenWriter.append(pixelBuffer: last, at: now - origin) == .appended {
                self.screen.withLock { $0.lastAppendHost = now }
            }
        }
        t.resume()
        filler = t
    }

    /// Stops accepting samples and brings every track to `endTime` (call after the source stopped).
    /// If recording ends while paused, the open pause is closed at `endTime`.
    func close(endTime: Double) {
        filler?.cancel()
        filler = nil
        fillerQueue.sync {}
        let wasPausedAt = timing.withLock { s -> Double? in
            s.closed = true
            guard let p = s.pauseStart else { return nil }
            s.pauses.append(TimeRange(start: p, end: max(p, endTime)))
            s.pauseStart = nil
            return p
        }
        composer?.stop()
        // Extend the screen to the end with the last picture (static screens deliver no frames).
        let videoEnd = wasPausedAt ?? endTime
        let frame = 1.0 / Double(max(1, format.frameRate))
        if let last = screen.withLock({ $0.last }), videoEnd - frame > screenWriter.lastVideoTime + 1e-4 {
            screenWriter.append(pixelBuffer: last, at: videoEnd - frame)
        }
        microphone?.pad(to: endTime)
        systemAudio?.pad(to: endTime)
        mixer?.flush()
    }

    /// Stops everything without finishing (discard or simulated crash).
    func abandon() {
        filler?.cancel()
        filler = nil
        timing.withLock { $0.closed = true }
        composer?.stop()
        screenWriter.abandon()
        microphone?.writer.abandon()
        systemAudio?.writer.abandon()
        shareWriter?.abandon()
        cameraWriter?.abandon()
    }
}

/// Scales pixel buffers to a fixed size with VideoToolbox (letterboxed), into its own pool.
final class FrameConformer {
    private var session: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?

    init(size: PixelSize, pixelFormat: OSType) {
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        if let session {
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
        }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary, attrs as CFDictionary, &pool)
    }

    func conform(_ pb: CVPixelBuffer) -> CVPixelBuffer? {
        guard let session, let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }
        guard VTPixelTransferSessionTransferImage(session, from: pb, to: out) == noErr else { return nil }
        return out
    }
}
