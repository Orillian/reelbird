import AppKit
import Foundation
import ReelbirdCore

// The app talks to the engine modules only through these protocols. Each one mirrors a module's
// public contract (REELBIRD-BRIEF.md) one to one, turning its static API into instance methods
// so mocks can stand in. A live adapter is a few lines per method: forward to the module.

/// `ReelbirdCapture.Permissions`
protocol PermissionsService: Sendable {
    func status(_ p: Permission) -> PermissionState
    func request(_ p: Permission) async -> PermissionState
    @MainActor func openSettings(for p: Permission)
}

/// `ReelbirdCapture.CaptureSources` and `ReelbirdCapture.Devices`
protocol CaptureSourceService: Sendable {
    func list() async throws -> [AvailableSource]
    func microphones() -> [MediaDevice]
    func cameras() -> [MediaDevice]
}

/// `ReelbirdCapture.RecordingSession`
protocol RecordingSessionHandle: AnyObject, Sendable {
    var status: AsyncStream<RecorderStatus> { get }
    func start() async throws
    func pause() async
    func resume() async
    func stop() async throws -> ProjectBundle
    func discard() async
}

/// Creates recording sessions (`RecordingSession.init`) and recovers crashed ones (`ProjectRecovery`).
protocol RecorderService: Sendable {
    func makeSession(options: RecordingOptions, bundleURL: URL, shareSink: (any ShareSegmentSink)?) throws -> any RecordingSessionHandle
    func recoverIfNeeded(_ bundle: ProjectBundle) throws -> Bool
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
}

/// `ReelbirdRender` (PreviewPlayer, Exporter, Thumbnailer) and `ReelbirdCore.Motion.AutoZoomPlanner`.
protocol RenderService: Sendable {
    @MainActor func makePreviewPlayer(bundle: ProjectBundle) throws -> any PreviewPlayerHandle
    func export(bundle: ProjectBundle, edit: EditDocument, options: ExportOptions,
                progress: @escaping @Sendable (Double) -> Void) async throws -> URL
    func poster(bundle: ProjectBundle, at t: Double, maxWidth: Int) async throws -> CGImage
    func autoZoomPlan(events: [InputEvent], duration: Double, intensity: Double) -> [ZoomRegion]
}

/// `ReelbirdShare.ShareSettings`, `LiveShareUploader` and `ShareService`.
protocol ShareServiceProtocol: Sendable {
    func loadDestination() -> ShareDestination?
    func saveDestination(_ d: ShareDestination, secret: String) throws
    func secret() -> String?
    func clearDestination()
    func makeLiveUploader(destination: ShareDestination, secret: String) -> any ShareSegmentSink
    func testConnection(_ d: ShareDestination, secret: String) async throws
    func publish(bundle: ProjectBundle, video: URL?, poster: CGImage?, captions: URL?, destination: ShareDestination,
                 secret: String, progress: @escaping @Sendable (Double) -> Void) async throws -> ShareInfo
    func unpublish(_ info: ShareInfo, destination: ShareDestination, secret: String) async throws
}

/// `ReelbirdAI` (Transcriber, Captions, SilenceDetector).
protocol AIService: Sendable {
    var transcriberAvailable: Bool { get }
    func transcribe(audio: URL, locale: Locale?) async throws -> Transcript
    func webVTT(_ t: Transcript) -> String
    func silentRanges(audio: URL) throws -> [TimeRange]
}

/// Live input monitoring for the source picker (microphone meter, camera preview). App-owned:
/// the brief's `CameraPreview` covers the camera; the meter is a small AVCaptureSession here.
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
    let ai: any AIService
    let inputs: any InputPreviewService
    /// True when everything is simulated (no engine modules wired yet, or `--mock`).
    let isMock: Bool

    init(permissions: any PermissionsService, capture: any CaptureSourceService, recorder: any RecorderService,
         render: any RenderService, share: any ShareServiceProtocol, ai: any AIService,
         inputs: any InputPreviewService, isMock: Bool) {
        self.permissions = permissions; self.capture = capture; self.recorder = recorder
        self.render = render; self.share = share; self.ai = ai; self.inputs = inputs; self.isMock = isMock
    }

    /// Simulated engine with real system permission checks. INTEGRATION: add `static func live()`
    /// that wraps ReelbirdCapture/Render/Share/AI and switch `AppDelegate` to it.
    static func mock(permissions: (any PermissionsService)? = nil) -> Services {
        Services(permissions: permissions ?? SystemPermissions(),
                 capture: MockCaptureSources(),
                 recorder: MockRecorder(),
                 render: MockRender(),
                 share: MockShare(),
                 ai: MockAI(),
                 inputs: MockInputPreview(),
                 isMock: true)
    }
}
