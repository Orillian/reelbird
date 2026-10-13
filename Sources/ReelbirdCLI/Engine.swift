import Foundation
import ReelbirdCore

// The CLI reaches capture, rendering and sharing only through `Engine` (`LiveEngine` in production,
// `DemoEngine` for flow tests), so those modules stay behind one small adapter. Everything that needs only ReelbirdCore
// and ReelbirdAI (info, list, edit, captions, suggest, silences, MCP) is implemented directly.

/// A recordable source or input device, as listed by `reelbird sources`.
struct SourceInfo: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable { case display, window, microphone, camera }
    var kind: Kind
    /// Stable ID to pass back (`--display`, `--window`, `--mic`, `--camera`).
    var id: String
    var name: String
    /// App name for windows; model or transport for devices.
    var detail: String?
    var isDefault: Bool = false
    var width: Int?
    var height: Int?
}

/// What to record, before it is resolved to a concrete `CaptureSource`.
enum SourceSelector: Hashable, Sendable {
    case mainDisplay
    /// Display ID or 1-based index from `reelbird sources`.
    case display(String)
    /// Window ID.
    case window(String)
    /// Rectangle in global display points (top-left origin), on `display` (default: the display containing it).
    case area(x: Double, y: Double, width: Double, height: Double, display: String?)
    /// Generated frames and tones instead of the screen (end-to-end checks without Screen Recording permission).
    case synthetic
}

/// A running recording.
protocol RecordingControl: Sendable {
    /// Live status (elapsed time, levels, warnings). Finishes when the recording ends.
    var status: AsyncStream<RecorderStatus> { get }
    /// Stops, finalises the bundle (manifest `.complete`) and returns it.
    func stop() async throws -> ProjectBundle
    /// Stops and deletes the bundle (and any live share upload).
    func discard() async
}

enum ExportFormat: String, CaseIterable, Codable, Sendable {
    case mp4, hevc, prores, gif
    var fileExtension: String {
        switch self {
        case .mp4, .hevc: return "mp4"
        case .prores: return "mov"
        case .gif: return "gif"
        }
    }
}

struct ExportRequest: Hashable, Sendable {
    var format: ExportFormat = .mp4
    var height: Int?
    var frameRate: Int?
    /// Output file; `nil` = `exports/` inside the bundle.
    var destination: URL?
}

/// Capture, render and share operations the CLI needs from the other Reelbird modules.
protocol Engine: Sendable {
    // Capture (ReelbirdCapture)
    func sources() async throws -> [SourceInfo]
    func resolve(_ selector: SourceSelector) async throws -> CaptureSource
    /// Starts recording into a new bundle at `bundleURL` (first frame as soon as possible; no countdown).
    func startRecording(options: RecordingOptions, bundleURL: URL) async throws -> any RecordingControl
    /// Rebuilds a bundle left in `recording` state by a crash. Returns false if it didn't need recovery.
    func recover(bundle: ProjectBundle) async throws -> Bool

    // Render (ReelbirdRender)
    func export(bundle: ProjectBundle, edit: EditDocument, request: ExportRequest,
                progress: @escaping @Sendable (Double) -> Void) async throws -> URL
    /// Renders the enhanced voice (`voice/`) for these settings, even when one matches.
    func renderVoiceStem(bundle: ProjectBundle, settings: AudioSettings,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> VoiceStemInfo

    // Share (ReelbirdShare)
    /// Publishes (or updates in place) the project's link. `polished` renders the current edit first;
    /// otherwise the existing quick stream is published when there is one. The CLI stores the returned info in project.json.
    func share(bundle: ProjectBundle, edit: EditDocument, polished: Bool,
               progress: @escaping @Sendable (Double) -> Void) async throws -> ShareInfo
    func unshare(bundle: ProjectBundle, info: ShareInfo) async throws
    func shareDestination() -> ShareDestination?
    func hasShareSecret() -> Bool
    func saveShareDestination(_ destination: ShareDestination, secret: String) throws
    func testShareConnection(_ destination: ShareDestination, secret: String) async throws
}

enum EngineFactory {
    /// The engine the CLI uses: `LiveEngine`, or `DemoEngine` when `REELBIRD_DEMO_ENGINE=1`.
    static func make(syntheticMicrophone: URL? = nil) -> any Engine {
        if ProcessInfo.processInfo.environment["REELBIRD_DEMO_ENGINE"] == "1" { return DemoEngine() }
        return LiveEngine(syntheticMicrophone: syntheticMicrophone)
    }
}

/// Every call fails with a clear message. Backs the parts of an engine that aren't wired in yet (sharing).
struct UnavailableEngine: Engine {
    private func unavailable(_ what: String, _ module: String) -> CLIError {
        CLIError("\(what) isn't available in this build yet (\(module) is not wired into the CLI).", code: .unavailable)
    }

    func sources() async throws -> [SourceInfo] { throw unavailable("Listing capture sources", "ReelbirdCapture") }
    func resolve(_ selector: SourceSelector) async throws -> CaptureSource { throw unavailable("Screen capture", "ReelbirdCapture") }
    func startRecording(options: RecordingOptions, bundleURL: URL) async throws -> any RecordingControl {
        throw unavailable("Recording", "ReelbirdCapture")
    }
    func recover(bundle: ProjectBundle) throws -> Bool { throw unavailable("Recovery", "ReelbirdCapture") }
    func export(bundle: ProjectBundle, edit: EditDocument, request: ExportRequest,
                progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        throw unavailable("Export", "ReelbirdRender")
    }
    func renderVoiceStem(bundle: ProjectBundle, settings: AudioSettings,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> VoiceStemInfo {
        throw unavailable("Voice enhancement", "ReelbirdRender")
    }
    func share(bundle: ProjectBundle, edit: EditDocument, polished: Bool,
               progress: @escaping @Sendable (Double) -> Void) async throws -> ShareInfo {
        throw unavailable("Sharing", "ReelbirdShare")
    }
    func unshare(bundle: ProjectBundle, info: ShareInfo) async throws { throw unavailable("Sharing", "ReelbirdShare") }
    func shareDestination() -> ShareDestination? { nil }
    func hasShareSecret() -> Bool { false }
    func saveShareDestination(_ destination: ShareDestination, secret: String) throws {
        throw unavailable("Saving share settings", "ReelbirdShare")
    }
    func testShareConnection(_ destination: ShareDestination, secret: String) async throws {
        throw unavailable("Testing the share connection", "ReelbirdShare")
    }
}
