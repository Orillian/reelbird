import AppKit
import ReelbirdAI
import ReelbirdCapture
import ReelbirdCore
import ReelbirdRender
import ReelbirdShare

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
    func bringOnScreen(_ source: AvailableSource) async -> Bool {
        guard case .window(let id, _, let title) = source.source, let pid = source.processID else { return true }
        return await WindowActivation.bringOnScreen(windowID: id, processID: pid, title: title)
    }
    func microphones() -> [MediaDevice] { Devices.microphones() }
    func cameras() -> [MediaDevice] { Devices.cameras() }
    func inputVolume(deviceID: String) -> Float? { Devices.inputVolume(deviceID: deviceID) }
    func setInputVolume(_ volume: Float, deviceID: String) { Devices.setInputVolume(volume, deviceID: deviceID) }
}

extension RecordingSession: RecordingSessionHandle {}

struct LiveRecorder: RecorderService {
    /// Records generated frames and tones instead of the screen (`--synthetic`, `--selftest-live`).
    var synthetic = false

    func makeSession(options: RecordingOptions, bundleURL: URL, shareSink: (any ShareSegmentSink)?) throws -> any RecordingSessionHandle {
        RecordingSession(options: options, bundleURL: bundleURL, shareSink: shareSink,
                         frameSource: synthetic ? Self.syntheticSource(for: options) : nil)
    }

    func recoverIfNeeded(_ bundle: ProjectBundle, waitForLock: Bool) throws -> Bool {
        try ProjectRecovery.recoverIfNeeded(bundle, waitForLock: waitForLock)
    }
    func needsRecovery(_ bundle: ProjectBundle) -> Bool { ProjectRecovery.needsRecovery(bundle) }

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
    func setHearOriginal(_ on: Bool) { player.hearOriginal = on }
    func voiceStemDidChange() { player.voiceStemDidChange() }
    var isMuted: Bool { player.isMuted }
    func cameraBubble(atSource t: Double) -> (place: NormPoint, sizeScale: Double)? {
        let plan = player.plan
        return (plan.cameraPlace(at: t), plan.cameraSizeScale(at: t))
    }
    func screenMapping(atSource t: Double, width: Double, height: Double) -> ScreenMapping? {
        player.plan.screenMapping(atSource: t, width: width, height: height)
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
    func audioAnalysis(bundle: ProjectBundle, settings: AudioSettings) async -> AudioAnalysis? {
        await AudioAnalyzer.analysis(bundle: bundle, settings: settings)
    }
    func voiceStemStatus(bundle: ProjectBundle, settings: AudioSettings) -> VoiceStemStatus {
        VoiceStem.status(bundle: bundle, settings: settings)
    }
    func renderVoiceStem(bundle: ProjectBundle, settings: AudioSettings, progress: @escaping @Sendable (Double) -> Void) async throws {
        // Off the caller's actor, at utility priority; cancelling the caller stops the render.
        let task = Task.detached(priority: .utility) { try await VoiceStem.render(bundle: bundle, settings: settings, progress: progress) }
        try await withTaskCancellationHandler { _ = try await task.value } onCancel: { task.cancel() }
    }
    func autoZoomPlan(events: [InputEvent], duration: Double, intensity: Double, crop: NormRect?) -> [ZoomRegion] {
        AutoZoomPlanner.plan(events: events, duration: duration, intensity: intensity, crop: crop)
    }
    func cropSuggestion(bundle: ProjectBundle) async -> CropSuggestion? {
        await Task.detached(priority: .utility) { await ToolbarDetector.suggestion(bundle: bundle) }.value
    }
}

struct LiveAI: AIService {
    var transcriberAvailable: Bool { Transcriber.isAvailable }
    func captionsUnavailableReason() async -> String? {
        switch await Transcriber.availability() {
        case .available, .needsDownload: return nil
        case .unsupportedLocale(let id): return "On-device captions don't support your language (\(id)) yet."
        case .unavailable(let reason): return reason
        }
    }
    var storySupported: Bool { if #available(macOS 26, *) { true } else { false } }
    var storyUnavailableReason: String? { StorySuggester.unavailableReason }
    func suggestStory(transcript: Transcript) async throws -> (title: String, chapters: [Chapter]) {
        try await StorySuggester.suggest(transcript: transcript)
    }
    func transcribe(audio: URL, locale: Locale?) async throws -> Transcript {
        try await Transcriber.transcribe(audio: audio, locale: locale)
    }
    func webVTT(_ t: Transcript) -> String { Captions.webVTT(t) }
    func silentRanges(audio: URL) async throws -> [TimeRange] { try await SilenceDetector.silentRanges(audio: audio) }
}

/// `ReelbirdShare`: settings (JSON + Keychain), the live uploader and publish/unpublish.
struct LiveShare: ShareServiceProtocol {
    func loadDestination() -> ShareDestination? { ShareSettings.load() }
    func saveDestination(_ d: ShareDestination, secret: String) throws { try ShareSettings.save(d, secret: secret) }
    func secret() -> String? { ShareSettings.secret() }
    func clearDestination() { ShareSettings.clear() }
    func makeLiveUploader(destination: ShareDestination, secret: String) -> any ShareSegmentSink {
        LiveShareUploader(destination: destination, secret: secret)
    }
    func resumeIfNeeded(bundle: ProjectBundle) async throws -> ShareInfo? {
        guard let d = ShareSettings.load(), let secret = ShareSettings.secret() else { return nil }
        return try await LiveShareUploader(destination: d, secret: secret).resumeIfNeeded(bundle: bundle)
    }
    func testConnection(_ d: ShareDestination, secret: String) async throws {
        try await ShareService.testConnection(d, secret: secret)
    }
    func publish(bundle: ProjectBundle, video: URL?, poster: CGImage?, captions: URL?, destination: ShareDestination,
                 secret: String, progress: @escaping @Sendable (Double) -> Void) async throws -> ShareInfo {
        try await ShareService.publish(bundle: bundle, video: video, poster: poster, captions: captions,
                                       destination: destination, secret: secret, progress: progress)
    }
    func unpublish(_ info: ShareInfo, destination: ShareDestination, secret: String) async throws {
        try await ShareService.unpublish(info, destination: destination, secret: secret)
    }
    func destination(for share: ShareInfo) -> (destination: ShareDestination, secret: String)? {
        ShareSettings.destination(for: share)
    }
    func ownBucket() -> (destination: ShareDestination, secret: String?)? {
        guard let d = ShareSettings.ownBucket() else { return nil }
        return (d, ShareSettings.secret(forOwnBucket: d))
    }
}

/// `ReelbirdShare` Reelbird Cloud (`CloudSettings`, `CloudSignIn`, `CloudAPI`).
struct LiveCloud: CloudService {
    var isAvailable: Bool { CloudSettings.isAvailable }
    func status() -> CloudStatus? { isAvailable ? CloudSettings.load().map { Self.status($0, me: nil) } : nil }

    func refresh() async throws -> CloudStatus? {
        guard let (account, me) = try await CloudSettings.refresh() else { return nil }
        return Self.status(account, me: me)
    }

    func beginSignIn() async throws -> CloudSignInCode {
        let s = try await CloudSignIn.start()
        return CloudSignInCode(userCode: s.userCode, verifyURL: s.verifyURL) {
            let account = try await s.wait()
            return Self.status(account, me: try? await CloudSettings.refresh()?.me)
        }
    }

    func signOut() async { await CloudSettings.signOut() }
    func setEnabled(_ on: Bool) throws { try CloudSettings.setEnabled(on) }

    func viewCounts() async throws -> [String: Int] {
        guard let a = CloudSettings.load(), let t = CloudSettings.token(for: a.server) else { return [:] }
        let links = try await CloudAPI(server: a.server, token: t).links()
        return Dictionary(links.map { ($0.url, $0.views) }, uniquingKeysWith: { a, _ in a })
    }

    func statsURL(forLink url: String) -> URL? {
        guard let a = CloudSettings.load(), url.hasPrefix(a.storage.publicBaseURL + "/r/") else { return nil }
        let id = url.dropFirst(a.storage.publicBaseURL.count + 3).split(separator: "/").first.map(String.init) ?? ""
        return id.isEmpty ? nil : URL(string: "\(a.server)/account/s/\(id)")
    }

    static func status(_ a: CloudAccount, me: CloudAPI.Me?) -> CloudStatus {
        CloudStatus(email: a.email, isPro: a.isPro, enabled: a.enabled,
                    linksUsed: me?.usage.activeLinks, linkLimit: me?.limits.activeLinks,
                    storageUsed: me?.usage.storageBytes, storageLimit: me?.limits.storageBytes,
                    accountURL: me.flatMap { URL(string: $0.accountURL) } ?? URL(string: a.server + "/account"),
                    upgradeURL: me?.upgradeURL.flatMap(URL.init(string:)) ?? URL(string: a.server + "/upgrade"))
    }
}

extension Services {
    /// The real engine. `synthetic` records generated frames instead of the screen (no permission needed).
    static func live(synthetic: Bool = false) -> Services {
        Services(permissions: LivePermissions(),
                 capture: LiveCaptureSources(),
                 recorder: LiveRecorder(synthetic: synthetic),
                 render: LiveRender(),
                 share: LiveShare(),
                 cloud: LiveCloud(),
                 ai: LiveAI(),
                 inputs: LiveInputPreview(),
                 isMock: false)
    }
}
