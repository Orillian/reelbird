import AppKit
import ReelbirdAI
import ReelbirdCapture
import ReelbirdCore
import ReelbirdRender

// Thin adapters from the service protocols to the engine modules. No logic lives here beyond
// forwarding; behaviour belongs in the modules so the CLI and the app share it.

struct LivePermissions: PermissionsService {
    func status(_ p: Permission) -> PermissionState { Permissions.status(p) }
    func request(_ p: Permission) async -> PermissionState { await Permissions.request(p) }
    @MainActor func openSettings(for p: Permission) { Permissions.openSettings(for: p) }
}

struct LiveCaptureSources: CaptureSourceService {
    func list() async throws -> [AvailableSource] { try await CaptureSources.list() }
    func thumbnail(for source: AvailableSource, maxPixelWidth: Int) async -> CGImage? {
        try? await CaptureSources.thumbnail(for: source, maxPixelWidth: maxPixelWidth)
    }
    func microphones() -> [MediaDevice] { Devices.microphones() }
    func cameras() -> [MediaDevice] { Devices.cameras() }
}

extension RecordingSession: RecordingSessionHandle {}

struct LiveRecorder: RecorderService {
    /// Records generated frames and tones instead of the screen (`--synthetic`, `--selftest-live`).
    var synthetic = false

    func makeSession(options: RecordingOptions, bundleURL: URL, shareSink: (any ShareSegmentSink)?) throws -> any RecordingSessionHandle {
        RecordingSession(options: options, bundleURL: bundleURL, shareSink: shareSink,
                         frameSource: synthetic ? Self.syntheticSource(for: options) : nil)
    }

    func recoverIfNeeded(_ bundle: ProjectBundle) throws -> Bool { try ProjectRecovery.recoverIfNeeded(bundle) }

    static func syntheticSource(for options: RecordingOptions) -> SyntheticFrameSource {
        var c = SyntheticFrameSource.Configuration()
        c.frameRate = min(60, options.frameRate)
        c.microphone = options.microphoneID == nil ? nil : .sine(frequency: 440, amplitude: 0.25)
        c.systemAudio = options.captureSystemAudio ? .sine(frequency: 660, amplitude: 0.15) : nil
        c.camera = options.cameraID == nil ? nil : PixelSize(width: 1280, height: 720)
        return SyntheticFrameSource(configuration: c)
    }
}

/// `PreviewPlayer` behind the editor's player protocol.
@MainActor final class LivePreviewPlayer: PreviewPlayerHandle {
    private let player: PreviewPlayer

    init(bundle: ProjectBundle) throws { player = try PreviewPlayer(bundle: bundle) }

    var view: NSView { player.view }
    func update(edit: EditDocument) { player.update(edit: edit) }
    func play() { player.play() }
    func pause() { player.pause() }
    func seek(to outputTime: Double) { player.seek(to: outputTime) }
    var currentTime: Double { player.currentTime }
    var duration: Double { player.duration }
    var onTimeChange: (@MainActor (Double) -> Void)? {
        get { player.onTimeChange }
        set { player.onTimeChange = newValue }
    }
    var onReady: (@MainActor ((any Error)?) -> Void)? {
        get { player.onReady }
        set { player.onReady = newValue }
    }
}

struct LiveRender: RenderService {
    @MainActor func makePreviewPlayer(bundle: ProjectBundle) throws -> any PreviewPlayerHandle {
        try LivePreviewPlayer(bundle: bundle)
    }
    func export(bundle: ProjectBundle, edit: EditDocument, options: ExportOptions,
                progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await Exporter.export(bundle: bundle, edit: edit, options: options, progress: progress)
    }
    func poster(bundle: ProjectBundle, at t: Double, maxWidth: Int) async throws -> CGImage {
        try await Thumbnailer.poster(bundle: bundle, at: t, maxWidth: maxWidth)
    }
    func autoZoomPlan(events: [InputEvent], duration: Double, intensity: Double) -> [ZoomRegion] {
        AutoZoomPlanner.plan(events: events, duration: duration, intensity: intensity)
    }
}

struct LiveAI: AIService {
    var transcriberAvailable: Bool { Transcriber.isAvailable }
    func transcribe(audio: URL, locale: Locale?) async throws -> Transcript {
        try await Transcriber.transcribe(audio: audio, locale: locale)
    }
    func webVTT(_ t: Transcript) -> String { Captions.webVTT(t) }
    func silentRanges(audio: URL) throws -> [TimeRange] { try SilenceDetector.silentRanges(audio: audio) }
}

/// Sharing until ReelbirdShare is wired in: nothing is configured and every upload explains why.
struct PendingShare: ShareServiceProtocol {
    struct Unavailable: LocalizedError {
        var errorDescription: String? { "Sharing isn't available in this build yet." }
    }
    func loadDestination() -> ShareDestination? { nil }
    func saveDestination(_ d: ShareDestination, secret: String) throws { throw Unavailable() }
    func secret() -> String? { nil }
    func clearDestination() {}
    func makeLiveUploader(destination: ShareDestination, secret: String) -> any ShareSegmentSink { NoShareSink() }
    func testConnection(_ d: ShareDestination, secret: String) async throws { throw Unavailable() }
    func publish(bundle: ProjectBundle, video: URL?, poster: CGImage?, captions: URL?, destination: ShareDestination,
                 secret: String, progress: @escaping @Sendable (Double) -> Void) async throws -> ShareInfo { throw Unavailable() }
    func unpublish(_ info: ShareInfo, destination: ShareDestination, secret: String) async throws { throw Unavailable() }

    private final class NoShareSink: ShareSegmentSink {
        func begin(recordingID: String, title: String) async throws -> ShareInfo { throw Unavailable() }
        func initSegment(_ data: Data) async {}
        func mediaSegment(index: Int, data: Data, duration: Double) async {}
        func finish(totalDuration: Double, timeout: Double) async {}
        func cancel() async {}
        var backlog: Int { get async { 0 } }
    }
}

extension Services {
    /// The real engine. `synthetic` records generated frames instead of the screen (no permission needed).
    static func live(synthetic: Bool = false) -> Services {
        Services(permissions: LivePermissions(),
                 capture: LiveCaptureSources(),
                 recorder: LiveRecorder(synthetic: synthetic),
                 render: LiveRender(),
                 share: PendingShare(),
                 ai: LiveAI(),
                 inputs: LiveInputPreview(),
                 isMock: false)
    }
}
