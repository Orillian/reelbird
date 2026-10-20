import AppKit
import Foundation
import ReelbirdAI
import ReelbirdCapture
import ReelbirdCore
import ReelbirdRender

// The app talks to the engine modules only through these protocols. Each one mirrors a module's
// public contract (REELBIRD-BRIEF.md) one to one, turning its static API into instance methods
// so mocks can stand in for snapshots and `--mock`. The live adapters are in Services/Live.

/// `ReelbirdCapture.Permissions`
protocol PermissionsService: Sendable {
    func status(_ p: Permission) -> PermissionState
    func request(_ p: Permission) async -> PermissionState
    @MainActor func openSettings(for p: Permission)
}

/// `ReelbirdCapture.CaptureSources` and `ReelbirdCapture.Devices`
protocol CaptureSourceService: Sendable {
    func list() async throws -> [AvailableSource]
    /// A preview of `source`, or `nil` when it can't be captured.
    func thumbnail(for source: AvailableSource, maxPixelWidth: Int) async -> CGImage?
    /// Brings an off-screen window (other desktop, minimized) on screen, waiting up to ~2 s.
    /// Returns whether it is on screen.
    func bringOnScreen(_ source: AvailableSource) async -> Bool
    func microphones() -> [MediaDevice]
    func cameras() -> [MediaDevice]
    /// The microphone's hardware input volume (0…1), or `nil` when the device doesn't offer one.
    func inputVolume(deviceID: String) -> Float?
    func setInputVolume(_ volume: Float, deviceID: String)
}

/// `ReelbirdCapture.RecordingSession`
protocol RecordingSessionHandle: AnyObject, Sendable {
    var status: AsyncStream<RecorderStatus> { get }
    func start() async throws
    func pause() async
    func resume() async
    func stop() async throws -> ProjectBundle
    func discard() async
    /// Live microphone peak/RMS in dBFS (HUD meter target zone).
    var microphoneLevels: MicLevelReading { get }
    /// After `stop()`: how much the microphone picked up (`nil` without a microphone).
    var microphoneTakeSummary: MicTakeSummary? { get }
    /// After `stop()`: tracks that stopped early or were left out, with the reason.
    var trackIssues: [TrackKind: String] { get async }
    /// The live camera bubble's frame (global points, top-left origin; `nil` = hidden) and shape, at host time
    /// `host` (`nil` = now). Logged as `camera` events so the editor places the camera where it was.
    func updateCameraBubble(frame: CGRect?, shape: CameraLayout.Shape, atHostTime host: Double?)
    /// Drops a marker now (a `marker` event on the recording clock). `nil` when no take is running.
    func addMarker(label: String?) async -> RecordedMarker?
    /// The live camera layout switched (the layout shortcut) at host time `host` (`nil` = now). Logged with the
    /// `camera` events, so the first edit gets matching layout segments.
    func updateCameraLayout(_ layout: LayoutSegment.Kind, atHostTime host: Double?)
}

/// Creates recording sessions (`RecordingSession.init`) and recovers crashed ones (`ProjectRecovery`).
protocol RecorderService: Sendable {
    func makeSession(options: RecordingOptions, bundleURL: URL, shareSink: (any ShareSegmentSink)?) throws -> any RecordingSessionHandle
    /// Rebuilds a take cut short by a crash (blocks: call it off the main thread). `waitForLock == false`
    /// returns `false` at once when another recorder or recovery holds the bundle.
    func recoverIfNeeded(_ bundle: ProjectBundle, waitForLock: Bool) throws -> Bool
    /// Cheap check: the manifest says `.recording`, or it is unreadable but media is there.
    func needsRecovery(_ bundle: ProjectBundle) -> Bool
}

extension RecorderService {
    func recoverIfNeeded(_ bundle: ProjectBundle) throws -> Bool { try recoverIfNeeded(bundle, waitForLock: true) }
}

/// `ReelbirdRender.PreviewPlayer`
@MainActor protocol PreviewPlayerHandle: AnyObject {
    var view: NSView { get }
    func update(edit: EditDocument)
    func play()
    func pause()
    func seek(to outputTime: Double)
    var currentTime: Double { get }
    var duration: Double { get }
    var onTimeChange: (@MainActor (Double) -> Void)? { get set }
    /// Called once media has loaded (`nil`) or failed to load.
    var onReady: (@MainActor ((any Error)?) -> Void)? { get set }
    /// Plays the raw microphone instead of the enhanced voice while true (press-and-hold "Hear original").
    func setHearOriginal(_ on: Bool)
    /// The voice stem was rendered: swap it in at the playhead.
    func voiceStemDidChange()
    /// Playback is silent (automated runs).
    var isMuted: Bool { get }
    /// The camera bubble as the renderer draws it at recording time `t`: its place (stepped aside during a zoom)
    /// and its size as a share of `camera.size` (smaller during a zoom). `nil` when the player can't say.
    func cameraBubble(atSource t: Double) -> (place: NormPoint, sizeScale: Double)?
    /// Where full-screen coordinates land on a `width` × `height` canvas at recording time `t` (crop, padding,
    /// layout and zoom), so overlays drawn on the preview line up with the frame. `nil` when the player can't say.
    func screenMapping(atSource t: Double, width: Double, height: Double) -> ScreenMapping?
}

/// `ReelbirdRender` (PreviewPlayer, Exporter, Thumbnailer) and `ReelbirdCore.Motion.AutoZoomPlanner`.
protocol RenderService: Sendable {
    @MainActor func makePreviewPlayer(bundle: ProjectBundle) throws -> any PreviewPlayerHandle
    func export(bundle: ProjectBundle, edit: EditDocument, options: ExportOptions,
                progress: @escaping @Sendable (Double) -> Void) async throws -> URL
    func poster(bundle: ProjectBundle, at t: Double, maxWidth: Int) async throws -> CGImage
    /// The voice's measured loudness (`AudioAnalyzer`), measured on first call and cached in the bundle.
    func audioAnalysis(bundle: ProjectBundle, settings: AudioSettings) async -> AudioAnalysis?
    /// `ReelbirdRender.VoiceStem`: whether the enhanced voice matches `settings`, and rendering it.
    func voiceStemStatus(bundle: ProjectBundle, settings: AudioSettings) -> VoiceStemStatus
    func renderVoiceStem(bundle: ProjectBundle, settings: AudioSettings, progress: @escaping @Sendable (Double) -> Void) async throws
    /// `AutoZoomPlanner.plan(events:duration:intensity:crop:)`: zooms only for what happens inside the crop.
    func autoZoomPlan(events: [InputEvent], duration: Double, intensity: Double, crop: NormRect?) -> [ZoomRegion]
    /// `ReelbirdRender.ToolbarDetector`: the browser toolbar found in the screen video (cached in the bundle),
    /// `nil` when the video can't be read.
    func cropSuggestion(bundle: ProjectBundle) async -> CropSuggestion?
}

/// `ReelbirdShare.ShareSettings`, `LiveShareUploader` and `ShareService`.
protocol ShareServiceProtocol: Sendable {
    func loadDestination() -> ShareDestination?
    func saveDestination(_ d: ShareDestination, secret: String) throws
    func secret() -> String?
    func clearDestination()
    func makeLiveUploader(destination: ShareDestination, secret: String) -> any ShareSegmentSink
    /// Finishes a live upload cut short by a crash or quit (uploads what's left of `share/`).
    /// Returns the share when there was work to do.
    func resumeIfNeeded(bundle: ProjectBundle) async throws -> ShareInfo?
    func testConnection(_ d: ShareDestination, secret: String) async throws
    func publish(bundle: ProjectBundle, video: URL?, poster: CGImage?, captions: URL?, destination: ShareDestination,
                 secret: String, progress: @escaping @Sendable (Double) -> Void) async throws -> ShareInfo
    func unpublish(_ info: ShareInfo, destination: ShareDestination, secret: String) async throws
    /// Where an existing link lives (Reelbird Cloud or your bucket), so it updates in place after switching.
    func destination(for share: ShareInfo) -> (destination: ShareDestination, secret: String)?
    /// Your own bucket, whether or not Reelbird Cloud is on.
    func ownBucket() -> (destination: ShareDestination, secret: String?)?
}

/// The Cloud account as the UI shows it.
struct CloudStatus: Equatable, Sendable {
    var email: String
    var isPro: Bool
    /// New shares go to Reelbird Cloud.
    var enabled: Bool
    var linksUsed: Int?
    var linkLimit: Int?
    var storageUsed: Int64?
    var storageLimit: Int64?
    var accountURL: URL?
    var upgradeURL: URL? = nil
}

/// A device sign-in in progress: show `userCode`, open `verifyURL`, then await `wait`.
struct CloudSignInCode: Sendable {
    var userCode: String
    var verifyURL: URL
    var wait: @Sendable () async throws -> CloudStatus
}

/// `ReelbirdShare` Reelbird Cloud: hosted links and their view counts.
protocol CloudService: Sendable {
    /// Whether Reelbird Cloud is offered at all (it stays hidden until the hosted service launches).
    var isAvailable: Bool { get }
    /// The signed-in account from disk (no network). `nil` when signed out.
    func status() -> CloudStatus?
    /// Plan and usage from the server.
    func refresh() async throws -> CloudStatus?
    func beginSignIn() async throws -> CloudSignInCode
    func signOut() async
    func setEnabled(_ on: Bool) throws
    /// Views per hosted link, keyed by the link URL.
    func viewCounts() async throws -> [String: Int]
    /// The stats page for a hosted link, or `nil` for links in your own bucket.
    func statsURL(forLink url: String) -> URL?
}

/// `ReelbirdAI` (Transcriber, Captions, SilenceDetector, StorySuggester).
protocol AIService: Sendable {
    var transcriberAvailable: Bool { get }
    /// Why captions can't be made on this Mac (language, missing model), or `nil` when they can.
    func captionsUnavailableReason() async -> String?
    /// Whether title and chapter suggestions exist on this OS at all (macOS 26+). The UI hides them otherwise.
    var storySupported: Bool { get }
    /// Why suggestions can't run right now (Apple Intelligence off, model downloading), or `nil`.
    var storyUnavailableReason: String? { get }
    func suggestStory(transcript: Transcript) async throws -> (title: String, chapters: [Chapter])
    func transcribe(audio: URL, locale: Locale?) async throws -> Transcript
    func webVTT(_ t: Transcript) -> String
    func silentRanges(audio: URL) async throws -> [TimeRange]
    /// `ReelbirdAI.SensitiveInfoScanner`: emails, keys, card and phone numbers on screen, found on this Mac.
    func findSensitiveInfo(bundle: ProjectBundle, options: SensitiveInfoScanner.Options,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> SensitiveInfoScanner.Result
}

/// Live input monitoring for the source picker (microphone meter, camera preview). App-owned:
/// `ReelbirdCapture.CameraPreview` draws the camera; the meter is a small AVCaptureSession.
@MainActor protocol InputPreviewService: AnyObject {
    /// Starts metering `deviceID` ("default" = system default). Levels 0...1 arrive on the main actor.
    func startMicrophoneMeter(deviceID: String, onLevel: @escaping @MainActor (Double) -> Void)
    func stopMicrophoneMeter()
    /// A live camera view for the picker and the floating bubble.
    func makeCameraView(deviceID: String) -> NSView
}

/// Everything the app needs, injected once at launch.
@MainActor final class Services {
    let permissions: any PermissionsService
    let capture: any CaptureSourceService
    let recorder: any RecorderService
    let render: any RenderService
    let share: any ShareServiceProtocol
    let cloud: any CloudService
    let ai: any AIService
    let inputs: any InputPreviewService
    /// True when the engine is simulated (`--mock`, snapshots, `--selftest`).
    let isMock: Bool

    init(permissions: any PermissionsService, capture: any CaptureSourceService, recorder: any RecorderService,
         render: any RenderService, share: any ShareServiceProtocol, cloud: any CloudService, ai: any AIService,
         inputs: any InputPreviewService, isMock: Bool) {
        self.permissions = permissions; self.capture = capture; self.recorder = recorder
        self.render = render; self.share = share; self.cloud = cloud; self.ai = ai; self.inputs = inputs; self.isMock = isMock
    }

    /// Simulated engine with real system permission checks (`--mock`, snapshots, `--selftest`).
    static func mock(permissions: (any PermissionsService)? = nil) -> Services {
        Services(permissions: permissions ?? LivePermissions(),
                 capture: MockCaptureSources(),
                 recorder: MockRecorder(),
                 render: MockRender(),
                 share: MockShare(),
                 cloud: MockCloud(),
                 ai: MockAI(),
                 inputs: MockInputPreview(),
                 isMock: true)
    }
}
