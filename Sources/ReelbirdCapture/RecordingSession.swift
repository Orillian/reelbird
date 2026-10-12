import AVFoundation
import Foundation
import ReelbirdCore
import Synchronization

/// Records one take into a `.reelbird` bundle.
///
/// All methods are safe to call from any task; state lives in an internal actor and media flows
/// on capture queues (never the main thread).
///
///     let session = RecordingSession(options: options, bundleURL: library.newBundleURL())
///     for await s in session.status { … }           // ~10 Hz: elapsed, mic level, warnings
///     try await session.start()                      // returns once the first frame is recorded
///     let bundle = try await session.stop()          // segments consolidated, project.json complete
public final class RecordingSession: Sendable {
    private let engine: SessionEngine
    private let broadcaster: StatusBroadcaster
    /// The bundle being written.
    public let bundle: ProjectBundle

    /// - Parameters:
    ///   - options: what to record.
    ///   - bundleURL: the `.reelbird` directory to create.
    ///   - shareSink: receives the quick-share stream while recording (optional).
    ///   - frameSource: overrides the ScreenCaptureKit source (tests use `SyntheticFrameSource`).
    public init(options: RecordingOptions, bundleURL: URL, shareSink: (any ShareSegmentSink)? = nil,
                frameSource: (any FrameSource)? = nil) {
        let broadcaster = StatusBroadcaster()
        self.broadcaster = broadcaster
        bundle = ProjectBundle(url: bundleURL)
        engine = SessionEngine(options: options, bundle: bundle, sink: shareSink, source: frameSource, broadcaster: broadcaster)
    }

    /// Live status (~10 Hz while recording). Each access returns a new stream that starts with the
    /// current status and finishes after the recording ends.
    public var status: AsyncStream<RecorderStatus> { broadcaster.subscribe() }

    /// The latest status without subscribing.
    public var currentStatus: RecorderStatus { broadcaster.current }

    /// Starts capture and returns once the first screen frame is recorded (timeline zero).
    /// The countdown is the UI's job.
    public func start() async throws { try await engine.start() }

    public func pause() async { await engine.pause() }

    public func resume() async { await engine.resume() }

    /// Stops, finalizes every writer, consolidates segments into one file per track and writes
    /// `project.json` with status `.complete`. Calling it again returns the same bundle.
    public func stop() async throws -> ProjectBundle { try await engine.stop() }

    /// Stops and deletes the bundle (and tells the share sink to delete its uploads).
    public func discard() async { await engine.discard() }

    /// Test hook: stops capture without finalizing anything, as if the app had crashed.
    func simulateCrash() async { await engine.simulateCrash() }

    /// Test hook: pipeline metrics.
    func metrics() async -> CapturePipeline.Metrics? { await engine.pipeline?.metrics.withLock { $0 } }
}

/// Fans status out to any number of subscribers.
final class StatusBroadcaster: Sendable {
    private struct State {
        var current = RecorderStatus()
        var continuations: [UUID: AsyncStream<RecorderStatus>.Continuation] = [:]
        var finished = false
    }
    private let state = Mutex(State())

    var current: RecorderStatus { state.withLock { $0.current } }

    func subscribe() -> AsyncStream<RecorderStatus> {
        let (stream, c) = AsyncStream<RecorderStatus>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let id = UUID()
        let finished = state.withLock { s -> Bool in
            c.yield(s.current)
            if !s.finished { s.continuations[id] = c }
            return s.finished
        }
        if finished { c.finish() }
        c.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) } }
        return stream
    }

    func publish(_ status: RecorderStatus) {
        let conts = state.withLock { s -> [AsyncStream<RecorderStatus>.Continuation] in
            s.current = status
            return Array(s.continuations.values)
        }
        conts.forEach { $0.yield(status) }
    }

    func finish() {
        let conts = state.withLock { s -> [AsyncStream<RecorderStatus>.Continuation] in
            s.finished = true
            defer { s.continuations = [:] }
            return Array(s.continuations.values)
        }
        conts.forEach { $0.finish() }
    }
}

actor SessionEngine {
    let options: RecordingOptions
    let bundle: ProjectBundle
    let sink: (any ShareSegmentSink)?
    let providedSource: (any FrameSource)?
    let broadcaster: StatusBroadcaster

    private(set) var pipeline: CapturePipeline?
    private var source: (any FrameSource)?
    private var format: FrameSourceFormat?
    private var recorder: InputEventRecorder?
    private var eventLog: EventLogWriter?
    private var pump: SharePump?
    private var manifest: ProjectManifest?
    private var phase: RecorderStatus.Phase = .idle
    private var origin = 0.0
    private var pausedTotal = 0.0
    private var pauseStartHost: Double?
    private var ticker: Task<Void, Never>?
    private var health = HealthMonitor()
    private var status = RecorderStatus()
    private var level = 0.0
    private var backlog = 0
    private var freeDisk: Int64?
    private var shareFailure: String?
    private var sourceFailure: String?
    private var stopTask: Task<ProjectBundle, any Error>?
    private var cameraSize: PixelSize?

    init(options: RecordingOptions, bundle: ProjectBundle, sink: (any ShareSegmentSink)?, source: (any FrameSource)?,
         broadcaster: StatusBroadcaster) {
        self.options = options
        self.bundle = bundle
        self.sink = sink
        self.providedSource = source
        self.broadcaster = broadcaster
    }

    // MARK: Start

    func start() async throws {
        guard phase == .idle, manifest == nil else { throw CaptureError.alreadyStarted }
        phase = .countdown  // "starting": guards against a second start while we await
        do {
            try await startCapture()
        } catch {
            await teardownAfterFailedStart()
            phase = .failed
            publish()
            broadcaster.finish()
            throw error
        }
    }

    private func startCapture() async throws {
        let src = providedSource ?? ScreenCaptureKitSource(options: options)
        source = src
        let fmt = try await src.prepare()
        format = fmt
        _ = try ProjectBundle.create(at: bundle.url)

        let screenSpec = EncoderSettings.screen(size: fmt.pixelSize, frameRate: fmt.frameRate, quality: options.quality)
        let screen = try SegmentedWriter(kind: .screen, directory: bundle.directory(for: .screen), video: screenSpec, audio: nil,
                                         realTime: fmt.isRealTime)
        try screen.start(at: 0)
        var tracks = [TrackInfo(kind: .screen, directory: TrackKind.screen.rawValue, codec: screenSpec.codec.rawValue,
                                pixelSize: fmt.pixelSize)]

        func audioFeed(_ kind: TrackKind, _ spec: AudioSpec) throws -> AudioTrackFeed {
            let w = try SegmentedWriter(kind: kind, directory: bundle.directory(for: kind), video: nil, audio: spec, realTime: fmt.isRealTime)
            try w.start(at: 0)
            tracks.append(TrackInfo(kind: kind, directory: kind.rawValue, codec: "aac", sampleRate: spec.sampleRate, channels: spec.channels))
            return AudioTrackFeed(writer: w, channels: spec.channels)
        }
        let mic = fmt.hasMicrophone ? try audioFeed(.microphone, EncoderSettings.microphone) : nil
        let system = fmt.hasSystemAudio ? try audioFeed(.systemAudio, EncoderSettings.systemAudio) : nil

        let title = bundle.url.deletingPathExtension().lastPathComponent
        var m = ProjectManifest(title: title, appVersion: ReelbirdInfo.version,
                                capture: CaptureInfo(source: fmt.source, pixelSize: fmt.pixelSize, scale: fmt.scale, frameRate: fmt.frameRate),
                                clock: ClockInfo(originHostTime: 0))

        var shareWriter: SegmentedWriter?
        var composer: ShareComposer?
        if let sink {
            let spec = EncoderSettings.share(screen: fmt.pixelSize)
            let pump = SharePump(sink: sink, recordingID: m.id, title: title) { [weak self] result in
                Task { await self?.shareBegan(result) }
            }
            self.pump = pump
            let w = try SegmentedWriter(kind: .share, directory: bundle.directory(for: .share), video: spec,
                                        audio: (mic != nil || system != nil) ? EncoderSettings.shareAudio : nil,
                                        profile: .mpeg4AppleHLS, realTime: fmt.isRealTime) { pump.send($0) }
            try w.start(at: 0)
            shareWriter = w
            composer = ShareComposer(writer: w, size: spec.size)
            tracks.append(TrackInfo(kind: .share, directory: TrackKind.share.rawValue, codec: "h264", pixelSize: spec.size,
                                    sampleRate: 48_000, channels: 2))
        }
        m.tracks = tracks
        manifest = m
        try bundle.writeManifest(m)

        let pipeline = CapturePipeline(format: fmt, screenWriter: screen, microphone: mic, systemAudio: system,
                                       cameraDirectory: bundle.directory(for: .camera), shareWriter: shareWriter, composer: composer)
        pipeline.onSourceStopped = { [weak self] error in Task { await self?.sourceStopped(error) } }
        pipeline.onCameraStarted = { [weak self] size in Task { await self?.cameraStarted(size) } }
        self.pipeline = pipeline
        eventLog = try EventLogWriter(url: bundle.eventsURL)

        try await src.start(output: pipeline)
        let first = try await pipeline.waitForFirstFrame(timeout: fmt.isRealTime ? 6 : 30)
        didStart(origin: first)
    }

    private func didStart(origin: Double) {
        guard let fmt = format, let pipeline, let eventLog else { return }
        self.origin = origin
        manifest?.clock.originHostTime = origin
        writeManifest()
        let src: (any FrameSource)? = source
        let simulated = src?.simulatedPointer(atHostTime: HostClock.now()) != nil
        let area: @Sendable () -> CGRect? = { src?.capturedArea() }
        var pointer: (@Sendable (Double) -> NormPoint?)?
        if simulated { pointer = { @Sendable t in src?.simulatedPointer(atHostTime: t) } }
        let config = InputEventRecorder.Configuration(captureKeystrokes: options.captureKeystrokes,
                                                      capturedArea: area, simulatedPointer: pointer)
        let recorder = InputEventRecorder(log: eventLog, bundle: bundle, configuration: config)
        if fmt.isRealTime { recorder.start(origin: origin) { [weak pipeline] t in pipeline?.isPaused(t) ?? false } }
        self.recorder = recorder
        phase = .recording
        publish()
        ticker = Task { [weak self] in
            var n = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self else { return }
                await self.tick(n)
                n += 1
            }
        }
    }

    private func teardownAfterFailedStart() async {
        ticker?.cancel()
        await source?.stop()
        pipeline?.abandon()
        await pump?.cancel()
        eventLog?.close()
        try? FileManager.default.removeItem(at: bundle.url)
    }

    // MARK: Pause / resume

    func pause() {
        guard phase == .recording, let pipeline else { return }
        let host = HostClock.now()
        guard let t = pipeline.pause(atHost: host) else { return }
        recorder?.mark(.pause, at: t)
        pauseStartHost = host
        phase = .paused
        publish()
    }

    func resume() {
        guard phase == .paused, let pipeline else { return }
        let host = HostClock.now()
        guard let range = pipeline.resume(atHost: host) else { return }
        recorder?.mark(.resume, at: range.end)
        if let p = pauseStartHost { pausedTotal += host - p }
        pauseStartHost = nil
        manifest?.pauses = pipeline.pauses
        writeManifest()
        phase = .recording
        publish()
    }

    // MARK: Stop

    func stop() async throws -> ProjectBundle {
        if let stopTask { return try await stopTask.value }
        guard phase == .recording || phase == .paused || (phase == .failed && pipeline != nil) else {
            throw CaptureError.notRecording
        }
        let task = Task { try await self.finalize() }
        stopTask = task
        return try await task.value
    }

    private func finalize() async throws -> ProjectBundle {
        guard let pipeline, let fmt = format, var m = manifest else { throw CaptureError.notRecording }
        let failed = phase == .failed
        phase = .finishing
        publish()
        let host = HostClock.now()
        let endTime = fmt.isRealTime ? max(0, host - origin) : pipeline.metrics.withLock { $0.lastScreenTime } + 1 / Double(fmt.frameRate)
        if let p = pauseStartHost { pausedTotal += host - p; pauseStartHost = nil }

        await source?.stop()
        recorder?.stop()
        pipeline.close(endTime: endTime)
        if pipeline.pauses.count > m.pauses.count, let last = pipeline.pauses.last { recorder?.mark(.resume, at: last.end) }
        eventLog?.close()

        // Finish every writer in parallel.
        var writers: [(TrackKind, SegmentedWriter, Double?)] = [(.screen, pipeline.screenWriter, endTime)]
        if let w = pipeline.microphone?.writer { writers.append((.microphone, w, nil)) }
        if let w = pipeline.systemAudio?.writer { writers.append((.systemAudio, w, nil)) }
        if let w = pipeline.cameraWriter { writers.append((.camera, w, endTime)) }
        if let w = pipeline.shareWriter { writers.append((.share, w, endTime)) }
        var errors: [TrackKind: String] = [:]
        await withTaskGroup(of: (TrackKind, String?).self) { group in
            for (kind, writer, end) in writers {
                group.addTask {
                    do { try await writer.finish(endTime: end); return (kind, nil) } catch { return (kind, error.localizedDescription) }
                }
            }
            for await (kind, error) in group { if let error { errors[kind] = error } }
        }
        await pump?.finish(totalDuration: endTime, timeout: 1.5)

        // Consolidate segments into one file per track and verify each opens with AVFoundation.
        var tracks: [TrackInfo] = []
        for (kind, writer, _) in writers {
            var info = m.track(kind) ?? TrackInfo(kind: kind, directory: kind.rawValue, codec: "unknown")
            info.segmentCount = writer.segmentCount
            info.startTime = writer.startTime
            do {
                guard let summary = try SegmentStore.consolidate(directory: bundle.directory(for: kind), kind: kind) else {
                    throw CaptureError.consolidationFailed(kind, errors[kind] ?? "no segments were written")
                }
                let url = bundle.resolve(summary.file)
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration).seconds
                let assetTracks = try await asset.load(.tracks)
                guard !assetTracks.isEmpty, duration.isFinite, duration > 0 else {
                    throw CaptureError.consolidationFailed(kind, "the file has no playable media")
                }
                info.file = summary.file
                info.duration = duration
                info.codec = summary.codec
                info.pixelSize = summary.pixelSize ?? info.pixelSize
                info.sampleRate = summary.sampleRate ?? info.sampleRate
                info.channels = summary.channels ?? info.channels
                info.segmentCount = summary.segmentCount
                tracks.append(info)
            } catch {
                CaptureLog.debug("consolidate \(kind): \(error)")
                if kind == .screen {
                    // Leave status .recording so ProjectRecovery can try again on next launch.
                    m.tracks = tracks
                    manifest = m
                    phase = .failed
                    publish()
                    broadcaster.finish()
                    throw error
                }
            }
        }
        m.tracks = tracks
        m.pauses = pipeline.pauses
        m.duration = endTime
        m.status = .complete
        m.share = manifest?.share ?? m.share
        manifest = m
        try bundle.writeManifest(m)

        ticker?.cancel()
        phase = failed ? .failed : .finished
        status.elapsed = max(0, endTime - pausedTotal)
        publish()
        broadcaster.finish()
        return bundle
    }

    // MARK: Discard / crash

    func discard() async {
        ticker?.cancel()
        let wasRunning = pipeline != nil
        await source?.stop()
        recorder?.stop()
        pipeline?.abandon()
        eventLog?.close()
        await pump?.cancel()
        if wasRunning || FileManager.default.fileExists(atPath: bundle.manifestURL.path) {
            try? FileManager.default.removeItem(at: bundle.url)
        }
        phase = .idle
        status = RecorderStatus()
        publish()
        broadcaster.finish()
    }

    func simulateCrash() async {
        ticker?.cancel()
        await source?.stop()
        recorder?.stop()
        pipeline?.abandon()
        eventLog?.close()
        pump?.abandon()
        phase = .failed
        publish()
        broadcaster.finish()
    }

    // MARK: Callbacks

    private func shareBegan(_ result: Result<ShareInfo, any Error>) {
        switch result {
        case .success(let info):
            manifest?.share = info
            status.shareURL = info.url
            writeManifest()
        case .failure(let error):
            shareFailure = error.localizedDescription
        }
    }

    private func cameraStarted(_ size: PixelSize) {
        cameraSize = size
        guard manifest?.track(.camera) == nil else { return }
        manifest?.tracks.append(TrackInfo(kind: .camera, directory: TrackKind.camera.rawValue, codec: "h264", pixelSize: size))
        writeManifest()
    }

    private func sourceStopped(_ error: any Error) {
        guard phase == .recording || phase == .paused else { return }
        sourceFailure = error.localizedDescription
        CaptureLog.debug("source stopped: \(error)")
        phase = .failed
        publish()
        // Never lose the take: finalize what we have.
        Task { _ = try? await self.stop() }
    }

    // MARK: Status

    private func tick(_ n: Int) async {
        guard phase == .recording || phase == .paused, let pipeline, let fmt = format else { return }
        let host = HostClock.now()
        let t = host - origin
        let m = pipeline.metrics.withLock { $0 }
        let paused = phase == .paused
        let meter = paused ? 0 : AudioPCM.meter(rms: m.microphoneRMS)
        level = max(meter, level * 0.8)

        if n % 10 == 0, let sink {
            Task { [weak self] in
                let b = await sink.backlog
                await self?.setBacklog(b)
            }
        }
        if n % 50 == 0 {
            freeDisk = (try? bundle.url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
        }
        if n % 20 == 19, var man = manifest {
            man.duration = t
            man.pauses = pipeline.pauses
            for i in man.tracks.indices {
                switch man.tracks[i].kind {
                case .screen: man.tracks[i].segmentCount = pipeline.screenWriter.segmentCount
                case .microphone: man.tracks[i].segmentCount = pipeline.microphone?.writer.segmentCount ?? 0
                case .systemAudio: man.tracks[i].segmentCount = pipeline.systemAudio?.writer.segmentCount ?? 0
                case .camera: man.tracks[i].segmentCount = pipeline.cameraWriter?.segmentCount ?? 0
                case .share: man.tracks[i].segmentCount = pipeline.shareWriter?.segmentCount ?? 0
                }
                man.tracks[i].duration = t
            }
            manifest = man
            writeManifest()
        }

        let micStart = max(origin, m.microphoneLastLoudHost)
        let lastInput = recorder?.lastActivityHost ?? 0
        var inputs = HealthInputs(now: t)
        inputs.paused = paused
        inputs.realTime = fmt.isRealTime
        inputs.microphoneEnabled = fmt.hasMicrophone
        inputs.microphoneSilentFor = host - micStart
        inputs.screenQuietFor = host - max(origin, m.lastScreenActivityHost)
        inputs.inputSinceLastFrame = lastInput > m.lastScreenActivityHost + 0.3
        inputs.audioCorrection = (pipeline.microphone?.correctionSeconds ?? 0) + (pipeline.systemAudio?.correctionSeconds ?? 0)
        inputs.freeDiskBytes = freeDisk
        inputs.uploadBacklog = backlog
        inputs.shareFailure = shareFailure
        if options.captureKeystrokes, Permissions.status(.inputMonitoring) != .granted { inputs.missingPermission = .inputMonitoring }
        var warnings = health.evaluate(inputs)
        if let sourceFailure {
            warnings.append(HealthWarning(kind: .captureStalled, message: "Capture stopped: \(sourceFailure). The recording so far is saved.", since: t))
        }

        status.elapsed = max(0, t - pausedTotal - (pauseStartHost.map { host - $0 } ?? 0))
        status.droppedFrames = m.droppedFrames
        status.microphoneLevel = level
        status.warnings = warnings
        status.uploadBacklog = backlog
        publish()

        if let max = options.maxDuration, status.elapsed >= max, stopTask == nil {
            Task { _ = try? await self.stop() }
        }
    }

    private func setBacklog(_ b: Int) { backlog = b }

    private func publish() {
        status.phase = phase
        broadcaster.publish(status)
    }

    private func writeManifest() {
        guard let manifest else { return }
        do { try bundle.writeManifest(manifest) } catch { CaptureLog.debug("manifest: \(error)") }
    }
}
