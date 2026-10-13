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
    private let micMonitor = MicrophoneMonitor()
    private let cameraLog = CameraBubbleLog()
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
        engine = SessionEngine(options: options, bundle: bundle, sink: shareSink, source: frameSource, broadcaster: broadcaster,
                               micMonitor: micMonitor, cameraLog: cameraLog)
    }

    /// Where the live camera bubble is: its frame in global display points (top-left origin, `nil` while
    /// hidden) and shape. Call it when the bubble appears and whenever a drag or resize ends; it is logged
    /// as a `camera` event (at t = 0 for the place it has when recording starts), so the editor puts the
    /// camera where it was. Safe from any thread.
    /// `host` is when it got there (`RecordingSession.hostTime`), default now.
    public func updateCameraBubble(frame: CGRect?, shape: CameraLayout.Shape, atHostTime host: Double? = nil) {
        cameraLog.update(frame: frame, shape: shape, atHostTime: host ?? HostClock.now())
    }

    /// Now on the host clock that recording timestamps use (seconds).
    public static var hostTime: Double { HostClock.now() }

    /// Live microphone peak and RMS in dBFS, for a meter with a target zone. Silence when there is no
    /// microphone or it stopped delivering.
    public var microphoneLevels: MicLevelReading { micMonitor.reading() }

    /// After `stop()`: how much of the take the microphone picked up (`nil` without a microphone).
    /// `isEssentiallySilent` means the voice is almost certainly missing.
    public var microphoneTakeSummary: MicTakeSummary? { micMonitor.summary }

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

    /// Test hook: locks the take to a named microphone and replaces the device-presence probe.
    func setMicrophoneProbe(id: String, name: String, probe: @escaping @Sendable () -> MicrophonePresence) async {
        await engine.setMicrophoneProbe(id: id, name: name, probe: probe)
    }

    /// Test hook: replaces the free-disk-space probe.
    func setFreeDiskProbe(_ probe: @escaping @Sendable () -> Int64?) async { await engine.setFreeDiskProbe(probe) }

    /// Test hook: end of the media written so far for a track (timeline seconds) and its audio correction.
    func written(_ kind: TrackKind) async -> (end: Double, correction: Double)? {
        guard let p = await engine.pipeline else { return nil }
        switch kind {
        case .screen: return (p.screenWriter.lastSampleEnd, 0)
        case .microphone: return p.microphone.map { ($0.writer.lastSampleEnd, $0.correctionSeconds) }
        case .systemAudio: return p.systemAudio.map { ($0.writer.lastSampleEnd, $0.correctionSeconds) }
        case .camera: return p.cameraWriter.map { ($0.lastSampleEnd, 0) }
        case .share: return p.shareWriter.map { ($0.lastSampleEnd, 0) }
        }
    }

    /// Test hook: pipeline metrics.
    func metrics() async -> CapturePipeline.Metrics? { await engine.pipeline?.metrics.withLock { $0 } }

    /// Tracks that stopped early or were left out of the finished project, with the reason (a camera
    /// that couldn't start, an encoder that failed, a file that didn't open at stop). Empty when every
    /// requested track made it. Read it after `stop()` to tell the person; the warnings in `status`
    /// say the same while recording.
    public var trackIssues: [TrackKind: String] { get async { await engine.trackIssues } }

    /// Test hook: the next `count` audio appends to `kind`'s writer report a busy encoder.
    func injectAudioRefusals(_ kind: TrackKind, count: Int) async {
        guard let p = await engine.pipeline else { return }
        (kind == .microphone ? p.microphone : p.systemAudio)?.writer.injectAudioRefusals(count)
    }

    /// Test hook: these tracks fail the AVFoundation check at stop.
    func failVerification(_ kinds: Set<TrackKind>) async { await engine.setFailVerification(kinds) }
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
    private var trackFailures: [TrackKind: String] = [:]
    private var failVerification: Set<TrackKind> = []
    var trackIssues: [TrackKind: String] { trackFailures }
    func setFailVerification(_ kinds: Set<TrackKind>) { failVerification = kinds }
    private var diskFull = false
    private var freeDiskProbe: @Sendable () -> Int64?
    private var stopTask: Task<ProjectBundle, any Error>?
    private var cameraSize: PixelSize?
    /// The first frame arrived (there is a take to finalize).
    private var recordingStarted = false
    private var discardRequested = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    /// Held from the moment the bundle exists until the take is finalized, discarded or abandoned, so
    /// recovery (app, CLI or MCP) never touches a take its recorder is still writing or consolidating.
    private var bundleLock: BundleLock?

    let micMonitor: MicrophoneMonitor
    let cameraLog: CameraBubbleLog
    /// The microphone the take is locked to (an explicit device, resolved at start).
    private var lockedMic: (id: String, name: String)?
    private var micProbe: (@Sendable () -> MicrophonePresence)?
    private var micPresence: MicrophonePresence?

    init(options: RecordingOptions, bundle: ProjectBundle, sink: (any ShareSegmentSink)?, source: (any FrameSource)?,
         broadcaster: StatusBroadcaster, micMonitor: MicrophoneMonitor, cameraLog: CameraBubbleLog = CameraBubbleLog()) {
        self.micMonitor = micMonitor
        self.cameraLog = cameraLog
        self.options = options
        self.bundle = bundle
        self.sink = sink
        self.providedSource = source
        self.broadcaster = broadcaster
        let url = bundle.url
        freeDiskProbe = {
            let dir = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
            return (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
        }
    }

    func setFreeDiskProbe(_ probe: @escaping @Sendable () -> Int64?) { freeDiskProbe = probe }

    func setMicrophoneProbe(id: String, name: String, probe: @escaping @Sendable () -> MicrophonePresence) {
        lockedMic = (id, name)
        micProbe = probe
    }

    /// Below this much free space the recording stops by itself, leaving room for project.json and
    /// for the writers to close their last segments.
    static let criticalFreeDisk: Int64 = 300_000_000

    // MARK: Start

    func start() async throws {
        guard phase == .idle, manifest == nil, !discardRequested else { throw CaptureError.alreadyStarted }
        phase = .countdown  // "starting": guards against a second start while we await
        defer { resumeStartWaiters() }
        do {
            try await startCapture()
        } catch {
            await teardownAfterFailedStart()
            phase = .failed
            publish()
            broadcaster.finish()
            throw discardRequested ? CancellationError() : error
        }
    }

    /// Waits while `start()` is still bringing capture up.
    private func waitForStart() async {
        guard phase == .countdown else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    private func resumeStartWaiters() {
        let w = startWaiters
        startWaiters = []
        w.forEach { $0.resume() }
    }

    /// Throws if `discard()` was called while starting.
    private func checkNotDiscarded() throws {
        if discardRequested { throw CancellationError() }
    }

    private func startCapture() async throws {
        var sourceOptions = options
        if providedSource == nil, let requested = options.microphoneID, let device = Devices.resolveMicrophone(requested) {
            // Lock the take to one explicit device: macOS switching its default input (AirPods
            // reconnecting) never changes what this take records.
            sourceOptions.microphoneID = device.id
            lockedMic = (device.id, device.name)
            let uid = device.id
            micProbe = { Devices.microphonePresence(uid: uid) }
        }
        let src = providedSource ?? ScreenCaptureKitSource(options: sourceOptions)
        source = src
        let fmt = try await src.prepare()
        try checkNotDiscarded()
        format = fmt
        _ = try ProjectBundle.create(at: bundle.url)
        bundleLock = try BundleLock.acquire(bundle, purpose: .recording, wait: false)

        let (screen, screenSpec) = try EncoderSettings.makeWriter(
            EncoderSettings.screen(size: fmt.pixelSize, frameRate: fmt.frameRate, quality: options.quality)) { spec in
            let w = try SegmentedWriter(kind: .screen, directory: bundle.directory(for: .screen), video: spec, audio: nil,
                                        realTime: fmt.isRealTime)
            try w.start(at: 0)
            return w
        }
        var tracks = [TrackInfo(kind: .screen, directory: TrackKind.screen.rawValue, codec: screenSpec.codec.rawValue,
                                pixelSize: fmt.pixelSize)]

        func audioFeed(_ kind: TrackKind, _ spec: AudioSpec, monitor: MicrophoneMonitor? = nil) throws -> AudioTrackFeed {
            let w = try SegmentedWriter(kind: kind, directory: bundle.directory(for: kind), video: nil, audio: spec, realTime: fmt.isRealTime)
            try w.start(at: 0)
            tracks.append(TrackInfo(kind: kind, directory: kind.rawValue, codec: "aac", sampleRate: spec.sampleRate, channels: spec.channels))
            return AudioTrackFeed(writer: w, channels: spec.channels, monitor: monitor)
        }
        let mic = fmt.hasMicrophone ? try audioFeed(.microphone, EncoderSettings.microphone, monitor: micMonitor) : nil
        if mic != nil { micMonitor.enable(realTime: fmt.isRealTime) }
        let system = fmt.hasSystemAudio ? try audioFeed(.systemAudio, EncoderSettings.systemAudio) : nil

        let title = bundle.url.deletingPathExtension().lastPathComponent
        var m = ProjectManifest(title: title, appVersion: ReelbirdInfo.version,
                                capture: CaptureInfo(source: fmt.source, pixelSize: fmt.pixelSize, scale: fmt.scale, frameRate: fmt.frameRate),
                                clock: ClockInfo(originHostTime: 0))

        var shareWriter: SegmentedWriter?
        var composer: ShareComposer?
        if let sink {
            let pump = SharePump(sink: sink, recordingID: m.id, title: title) { [weak self] result in
                Task { await self?.shareBegan(result) }
            }
            self.pump = pump
            let shareAudio = (mic != nil || system != nil) ? EncoderSettings.shareAudio : nil
            let (w, spec) = try EncoderSettings.makeWriter(EncoderSettings.share(screen: fmt.pixelSize)) { spec in
                let w = try SegmentedWriter(kind: .share, directory: bundle.directory(for: .share), video: spec, audio: shareAudio,
                                            profile: .mpeg4AppleHLS, realTime: fmt.isRealTime) { pump.send($0) }
                try w.start(at: 0)
                return w
            }
            shareWriter = w
            composer = ShareComposer(writer: w, size: spec.size)
            tracks.append(TrackInfo(kind: .share, directory: TrackKind.share.rawValue, codec: spec.codec.rawValue, pixelSize: spec.size,
                                    sampleRate: 48_000, channels: 2))
        }
        m.tracks = tracks
        manifest = m
        try bundle.writeManifest(m)

        let pipeline = CapturePipeline(format: fmt, screenWriter: screen, microphone: mic, systemAudio: system,
                                       cameraDirectory: bundle.directory(for: .camera), shareWriter: shareWriter, composer: composer)
        pipeline.onSourceStopped = { [weak self] error in Task { await self?.sourceStopped(error) } }
        pipeline.onCameraStarted = { [weak self] size in Task { await self?.cameraStarted(size) } }
        pipeline.onCameraError = { [weak self] message in
            Task { await self?.writerFailed(.camera, "the camera couldn't start (\(message))") }
        }
        pipeline.onWriterFailed = { [weak self] kind, message in Task { await self?.writerFailed(kind, message) } }
        self.pipeline = pipeline
        eventLog = try EventLogWriter(url: bundle.eventsURL)

        try await src.start(output: pipeline)
        try checkNotDiscarded()
        let first = try await pipeline.waitForFirstFrame(timeout: fmt.isRealTime ? 6 : 30)
        try checkNotDiscarded()
        didStart(origin: first)
    }

    private func didStart(origin: Double) {
        guard let fmt = format, let pipeline, let eventLog else { return }
        self.origin = origin
        recordingStarted = true
        manifest?.clock.originHostTime = origin
        writeManifest()
        let src: (any FrameSource)? = source
        let simulated = src?.simulatedPointer(atHostTime: HostClock.now()) != nil
        let area: @Sendable () -> CGRect? = { src?.capturedArea() }
        var pointer: (@Sendable (Double) -> NormPoint?)?
        if simulated { pointer = { @Sendable t in src?.simulatedPointer(atHostTime: t) } }
        var config = InputEventRecorder.Configuration(captureKeystrokes: options.captureKeystrokes,
                                                      capturedArea: area, simulatedPointer: pointer)
        if options.captureKeystrokes, case .window(let id, _, _) = fmt.source { config.keystrokeOwnerPID = Self.ownerPID(ofWindow: id) }
        let recorder = InputEventRecorder(log: eventLog, bundle: bundle, configuration: config)
        if fmt.isRealTime { recorder.start(origin: origin) { [weak pipeline] t in pipeline?.isPaused(t) ?? false } }
        self.recorder = recorder
        if fmt.hasCamera {
            let composer = pipeline.composer, screen = fmt.pixelSize
            cameraLog.begin(writer: eventLog, origin: origin, realTime: fmt.isRealTime, area: area,
                            isPaused: { [weak pipeline] t in pipeline?.isPaused(t) ?? false }) { rect, shape, t in
                composer?.setCamera(position: CameraPlacement.position(recorded: rect, screen: screen), shape: shape,
                                    size: CameraPlacement.size(recorded: rect, shape: shape, screen: screen), at: t)
            }
        }
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

    /// The process that owns a window (keystrokes are logged only while it's in front).
    static func ownerPID(ofWindow id: UInt32) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(id)) as? [[CFString: Any]],
              let pid = list.first?[kCGWindowOwnerPID] as? pid_t, pid > 0 else { return nil }
        return pid
    }

    private func teardownAfterFailedStart() async {
        ticker?.cancel()
        await source?.stop()
        pipeline?.abandon()
        await pump?.cancel()
        cameraLog.end()
        eventLog?.close()
        try? FileManager.default.removeItem(at: bundle.url)
        releaseLock()
    }

    private func releaseLock() {
        bundleLock?.release()
        bundleLock = nil
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
        cameraLog.resumed(at: range.end)
        if let p = pauseStartHost { pausedTotal += host - p }
        pauseStartHost = nil
        manifest?.pauses = pipeline.pauses
        writeManifest()
        phase = .recording
        publish()
    }

    // MARK: Stop

    func stop() async throws -> ProjectBundle {
        // Stop pressed while capture is still starting (slow first frame): finish starting, then stop.
        await waitForStart()
        if let stopTask { return try await stopTask.value }
        guard !discardRequested, recordingStarted, phase == .recording || phase == .paused || phase == .failed else {
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
        cameraLog.end()
        eventLog?.close()

        // Finish every writer in parallel.
        var writers: [(TrackKind, SegmentedWriter, Double?)] = [(.screen, pipeline.screenWriter, endTime)]
        if let w = pipeline.microphone?.writer { writers.append((.microphone, w, nil)) }
        if let w = pipeline.systemAudio?.writer { writers.append((.systemAudio, w, nil)) }
        if let w = pipeline.cameraWriter { writers.append((.camera, w, endTime)) }
        // The share stream leaves pauses out, so it ends earlier.
        let shareEnd = pipeline.shareTimeMap.time(endTime) ?? max(0, endTime - pipeline.shareTimeMap.pausedTotal)
        if let w = pipeline.shareWriter { writers.append((.share, w, shareEnd)) }
        var errors: [TrackKind: String] = [:]
        await withTaskGroup(of: (TrackKind, String?).self) { group in
            for (kind, writer, end) in writers {
                group.addTask {
                    do { try await writer.finish(endTime: end); return (kind, nil) } catch { return (kind, error.localizedDescription) }
                }
            }
            for await (kind, error) in group { if let error { errors[kind] = error } }
        }
        await pump?.finish(totalDuration: shareEnd, timeout: 1.5)

        // Consolidate segments into one file per track and verify each opens with AVFoundation.
        // A track whose segments can't be copied (disk full, I/O error) leaves the project in the
        // `.recording` state so ProjectRecovery finishes it later; nothing on disk is removed.
        var tracks: [TrackInfo] = []
        var verifiedWhole: Set<TrackKind> = []
        var deferred: (any Error)?
        for (kind, writer, _) in writers {
            var info = m.track(kind) ?? TrackInfo(kind: kind, directory: kind.rawValue, codec: "unknown")
            info.segmentCount = writer.segmentCount
            info.startTime = writer.startTime
            let summary: SegmentStore.TrackSummary?
            do {
                if let free = freeDiskProbe(), free < writer.bytesWritten + 64_000_000 {
                    let need = ByteCountFormatter.string(fromByteCount: writer.bytesWritten + 64_000_000 - free, countStyle: .file)
                    throw CaptureError.consolidationFailed(kind, "there isn't enough free disk space to finish (about \(need) more is needed). Free up space and open the project again")
                }
                summary = try SegmentStore.consolidate(directory: bundle.directory(for: kind), kind: kind)
            } catch {
                CaptureLog.debug("consolidate \(kind): \(error)")
                let e = (error as? CaptureError) ?? CaptureError.consolidationFailed(kind, DurableFile.isOutOfSpace(error) ? "the disk is full" : error.localizedDescription)
                if deferred == nil || kind == .screen { deferred = e }
                if kind == .screen { break }
                continue
            }
            do {
                guard let summary else {
                    throw CaptureError.consolidationFailed(kind, errors[kind] ?? "no segments were written")
                }
                let url = bundle.resolve(summary.file)
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration).seconds
                let assetTracks = try await asset.load(.tracks)
                guard !assetTracks.isEmpty, duration.isFinite, duration > 0, !failVerification.contains(kind) else {
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
                if summary.includesEverySegment { verifiedWhole.insert(kind) }
            } catch {
                CaptureLog.debug("verify \(kind): \(error)")
                if kind == .screen { deferred = error; break }
                // Left out of the project, but never silently: the person is told, and its segments stay
                // on disk (they are deleted only for verified tracks).
                if trackFailures[kind] == nil {
                    trackFailures[kind] = "its file didn't open after recording (\(Self.reason(error))); its segments are kept in the project"
                }
            }
        }
        if let deferred {
            // Keep status .recording (every track entry, final pauses and duration) for recovery.
            m.pauses = pipeline.pauses
            m.duration = endTime
            m.share = manifest?.share ?? m.share
            manifest = m
            try? bundle.writeManifest(m)
            releaseLock()
            ticker?.cancel()
            phase = .failed
            status.warnings = failureWarnings(at: endTime)
            publish()
            broadcaster.finish()
            throw deferred
        }
        m.tracks = tracks
        m.pauses = pipeline.pauses
        m.duration = endTime
        m.status = .complete
        m.share = manifest?.share ?? m.share
        manifest = m
        try bundle.writeManifest(m)   // fully flushed: the consolidated files are now what the project points at
        removeFinishedSegments(tracks, verified: verifiedWhole, manifest: m)
        releaseLock()

        if fmt.hasMicrophone { micMonitor.finish(activeSeconds: max(0, endTime - pausedTotal)) }
        ticker?.cancel()
        phase = failed ? .failed : .finished
        if failed || !trackFailures.isEmpty { status.warnings = failureWarnings(at: endTime) }
        status.elapsed = max(0, endTime - pausedTotal)
        publish()
        broadcaster.finish()
        return bundle
    }

    /// The take is finished: each track's consolidated file opened with AVFoundation and `project.json`
    /// (status `.complete`) is on disk, so the segments are only a second copy. Deletes them for every
    /// track whose file holds all of its segments. The share stream's segments stay while its live upload
    /// may still need them (resume after a quit reads them) and go once the upload is done.
    private func removeFinishedSegments(_ tracks: [TrackInfo], verified: Set<TrackKind>, manifest: ProjectManifest) {
        let bundle = bundle
        for t in tracks where verified.contains(t.kind) && t.kind != .share {
            SegmentStore.removeSegments(directory: bundle.directory(for: t.kind), kind: t.kind)
        }
        guard verified.contains(.share) else { return }
        guard let sink, manifest.share != nil || shareFailure == nil else {
            // No live upload (sharing failed to start): nothing will read them again.
            SegmentStore.removeSegments(directory: bundle.directory(for: .share), kind: .share)
            return
        }
        Task.detached(priority: .utility) {
            guard await sink.waitUntilUploaded() else { return }
            // Only once the project is still there and finished (not trashed or discarded meanwhile).
            guard let m = try? bundle.readManifest(), m.status != .recording, m.track(.share)?.file != nil,
                  let lock = try? BundleLock.acquire(bundle, purpose: .cleanup, wait: false) else { return }
            defer { lock.release() }
            SegmentStore.removeSegments(directory: bundle.directory(for: .share), kind: .share)
        }
    }

    // MARK: Discard / crash

    func discard() async {
        discardRequested = true
        pipeline?.cancelFirstFrameWait()
        await waitForStart()
        // Stop already finishing: let it settle so nothing writes into the folder after it is deleted.
        if let stopTask { _ = try? await stopTask.value }
        ticker?.cancel()
        let wasRunning = pipeline != nil
        await source?.stop()
        recorder?.stop()
        pipeline?.abandon()
        cameraLog.end()
        eventLog?.close()
        await pump?.cancel()
        if wasRunning || recordingStarted || FileManager.default.fileExists(atPath: bundle.manifestURL.path) {
            try? FileManager.default.removeItem(at: bundle.url)
        }
        releaseLock()
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
        cameraLog.end()
        eventLog?.close()
        pump?.abandon()
        releaseLock()   // a crashed process's lock goes with it
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
        CaptureLog.debug("source stopped: \(error)")
        guard phase == .recording || phase == .paused else { return }
        sourceFailure = error.localizedDescription
        stopForFailure()
    }

    /// A writer failed. The screen track or a full disk ends the recording (finalizing what is on
    /// disk); another track failing only stops that track and shows a warning.
    private func writerFailed(_ kind: TrackKind, _ message: String) {
        CaptureLog.debug("writer \(kind) failed: \(message)")
        let outOfSpace = message == "the disk is full"
        trackFailures[kind] = message
        if outOfSpace { diskFull = true }
        guard kind == .screen || outOfSpace else { return }
        stopForFailure()
    }

    private func stopForFailure() {
        guard phase == .recording || phase == .paused else { return }
        phase = .failed
        status.warnings = failureWarnings(at: max(0, HostClock.now() - origin))
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
        if n % 10 == 0 {
            freeDisk = freeDiskProbe()
            if let free = freeDisk, free < Self.criticalFreeDisk {
                diskFull = true
                stopForFailure()
                return
            }
        }
        if n % 10 == 5, let micProbe { micPresence = micProbe() }
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
        if fmt.hasMicrophone {
            let h = micMonitor.health(now: fmt.isRealTime ? host : nil)
            inputs.microphoneClipEvents = h.clipEvents
            inputs.microphoneTooQuiet = h.tooQuiet
            inputs.talkingWhilePaused = h.talkingWhilePaused
            inputs.lockedMicrophoneID = lockedMic?.id
            inputs.lockedMicrophoneName = lockedMic?.name
            if let p = micPresence {
                inputs.microphoneMissing = !p.connected
                inputs.systemDefaultMicrophoneID = p.systemDefaultID
                inputs.systemDefaultMicrophoneName = p.systemDefaultName
            }
        }
        inputs.freeDiskBytes = freeDisk
        inputs.uploadBacklog = backlog
        inputs.shareFailure = shareFailure
        // The tap can only be created with Input Monitoring; warn whenever it isn't running.
        if options.captureKeystrokes, fmt.isRealTime, recorder?.keystrokesActive != true { inputs.missingPermission = .inputMonitoring }
        var warnings = health.evaluate(inputs)
        warnings.append(contentsOf: failureWarnings(at: t))

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

    private static func trackName(_ kind: TrackKind) -> String {
        switch kind {
        case .screen: "the screen"
        case .camera: "the camera"
        case .microphone: "the microphone"
        case .systemAudio: "system audio"
        case .share: "the share stream"
        }
    }

    private static func reason(_ error: any Error) -> String {
        if case CaptureError.consolidationFailed(_, let detail) = error { return detail }
        return error.localizedDescription
    }

    private func failureWarnings(at t: Double) -> [HealthWarning] {
        var out: [HealthWarning] = []
        if diskFull {
            out.append(HealthWarning(kind: .lowDisk, message: "Recording stopped: the disk is full. Everything recorded so far is saved.", since: t))
        }
        if let sourceFailure {
            out.append(HealthWarning(kind: .captureStalled, message: "Capture stopped: \(sourceFailure). The recording so far is saved.", since: t))
        } else if let screen = trackFailures[.screen], !diskFull {
            out.append(HealthWarning(kind: .captureStalled, message: "Recording stopped: \(screen). The recording so far is saved.", since: t))
        }
        let others = trackFailures.filter { $0.key != .screen && !diskFull }.sorted { $0.key.rawValue < $1.key.rawValue }
        if !others.isEmpty, sourceFailure == nil {
            let tail = phase == .recording || phase == .paused ? "The screen keeps recording." : "The rest of the recording is saved."
            let message = others.count == 1
                ? "Stopped recording \(Self.trackName(others[0].key)): \(others[0].value). \(tail)"
                : "Stopped recording \(others.map { Self.trackName($0.key) }.joined(separator: " and ")) after errors (\(others.map(\.value).joined(separator: "; "))). \(tail)"
            out.append(HealthWarning(kind: .captureStalled, message: message, since: t))
        }
        return out
    }

    private func publish() {
        status.phase = phase
        broadcaster.publish(status)
    }

    private func writeManifest() {
        guard let manifest else { return }
        do { try bundle.writeManifest(manifest) } catch { CaptureLog.debug("manifest: \(error)") }
    }
}
