import Foundation
import Observation
import ReelbirdCore

enum SourceTab: String, CaseIterable, Codable { case display, window, area }

enum CameraBubbleSize: String, CaseIterable, Codable {
    case small, medium, large
    var points: CGFloat { switch self { case .small: 140; case .medium: 200; case .large: 280 } }
    var title: String { rawValue.capitalized }
    /// The live bubble's size in points for a shape (the portrait tile is taller, at about the same area).
    func size(_ shape: CameraLayout.Shape) -> CGSize {
        let s = CameraPlacement.bubbleSize(shape: shape, size: Double(points), short: 1)
        return CGSize(width: s.width.rounded(), height: s.height.rounded())
    }
}

/// What happens when a recording stops.
enum AfterRecording: String, CaseIterable, Codable {
    /// A small card in the bottom-left corner: Copy link, Copy video, Save, Edit.
    case quickActions
    /// The editor opens with the new recording.
    case openEditor
    /// Nothing opens; the recording is in the Library.
    case nothing

    var title: String {
        switch self {
        case .quickActions: "Show quick actions"
        case .openEditor: "Open the editor"
        case .nothing: "Do nothing"
        }
    }

    /// Before this setting, a toggle chose between opening the editor (the default) and nothing. A choice someone
    /// made with the toggle is kept; everyone else gets quick actions.
    static func migrated(stored: String?, legacyOpenEditor: Bool?) -> AfterRecording {
        if let stored, let v = AfterRecording(rawValue: stored) { return v }
        switch legacyOpenEditor {
        case true?: return .openEditor
        case false?: return .nothing
        case nil: return .quickActions
        }
    }
}

/// Persistent user choices. Every property writes through to UserDefaults.
@MainActor @Observable final class Preferences {
    @ObservationIgnored private let d: UserDefaults

    init(defaults: UserDefaults = .standard) {
        d = defaults
        sourceTab = SourceTab(rawValue: d.string(forKey: "sourceTab") ?? "") ?? .display
        lastSourceID = d.string(forKey: "lastSourceID")
        lastArea = (d.data(forKey: "lastArea")).flatMap { try? JSONDecoder().decode(CGRect.self, from: $0) }
        microphoneEnabled = d.object(forKey: "microphoneEnabled") as? Bool ?? true
        // "Automatic" (the best connected mic, locked at start). Older builds stored "default" (the system
        // default, which follows macOS onto AirPods); move those to Automatic.
        let mic = d.string(forKey: "microphoneID")
        microphoneID = mic == nil || mic == MicPolicy.systemDefaultID ? MicPolicy.automaticID : mic ?? MicPolicy.automaticID
        cameraEnabled = d.object(forKey: "cameraEnabled") as? Bool ?? false
        cameraID = d.string(forKey: "cameraID")
        systemAudio = d.object(forKey: "systemAudio") as? Bool ?? true
        shareWhileRecording = d.object(forKey: "shareWhileRecording") as? Bool ?? false
        quality = RecordingOptions.Quality(rawValue: d.string(forKey: "quality") ?? "") ?? .high
        frameRate = d.object(forKey: "frameRate") as? Int ?? 60
        countdown = d.object(forKey: "countdown") as? Int ?? 3
        captureKeystrokes = d.object(forKey: "captureKeystrokes") as? Bool ?? false
        showCursorDefault = d.object(forKey: "showCursorDefault") as? Bool ?? true
        clickEffectDefault = CursorSettings.ClickEffect(rawValue: d.string(forKey: "clickEffectDefault") ?? "") ?? .ripple
        recordHotKey = (d.data(forKey: "recordHotKey")).flatMap { try? JSONDecoder().decode(HotKey.self, from: $0) } ?? .defaultRecord
        pauseHotKey = (d.data(forKey: "pauseHotKey")).flatMap { try? JSONDecoder().decode(HotKey.self, from: $0) } ?? .defaultPause
        markerHotKey = (d.data(forKey: "markerHotKey")).flatMap { try? JSONDecoder().decode(HotKey.self, from: $0) } ?? .defaultMarker
        layoutHotKey = (d.data(forKey: "layoutHotKey")).flatMap { try? JSONDecoder().decode(HotKey.self, from: $0) } ?? .defaultLayout
        libraryPath = d.string(forKey: "libraryPath")
        onboardingDone = d.bool(forKey: "onboardingDone")
        cameraBubbleSize = CameraBubbleSize(rawValue: d.string(forKey: "cameraBubbleSize") ?? "") ?? .medium
        cameraShape = CameraLayout.Shape(rawValue: d.string(forKey: "cameraShape") ?? "") ?? .circle
        afterRecording = AfterRecording.migrated(stored: d.string(forKey: "afterRecording"),
                                                 legacyOpenEditor: d.object(forKey: "openEditorAfterRecording") as? Bool)
    }

    var sourceTab: SourceTab { didSet { d.set(sourceTab.rawValue, forKey: "sourceTab") } }
    var lastSourceID: String? { didSet { d.set(lastSourceID, forKey: "lastSourceID") } }
    /// Last area in global top-left-origin points.
    var lastArea: CGRect? { didSet { d.set(try? JSONEncoder().encode(lastArea), forKey: "lastArea") } }
    var microphoneEnabled: Bool { didSet { d.set(microphoneEnabled, forKey: "microphoneEnabled") } }
    /// `MicPolicy.automaticID` or an explicit device ID.
    var microphoneID: String { didSet { d.set(microphoneID, forKey: "microphoneID") } }
    var cameraEnabled: Bool { didSet { d.set(cameraEnabled, forKey: "cameraEnabled") } }
    var cameraID: String? { didSet { d.set(cameraID, forKey: "cameraID") } }
    var systemAudio: Bool { didSet { d.set(systemAudio, forKey: "systemAudio") } }
    var shareWhileRecording: Bool { didSet { d.set(shareWhileRecording, forKey: "shareWhileRecording") } }
    var quality: RecordingOptions.Quality { didSet { d.set(quality.rawValue, forKey: "quality") } }
    var frameRate: Int { didSet { d.set(frameRate, forKey: "frameRate") } }
    var countdown: Int { didSet { d.set(countdown, forKey: "countdown") } }
    var captureKeystrokes: Bool { didSet { d.set(captureKeystrokes, forKey: "captureKeystrokes") } }
    var showCursorDefault: Bool { didSet { d.set(showCursorDefault, forKey: "showCursorDefault") } }
    var clickEffectDefault: CursorSettings.ClickEffect { didSet { d.set(clickEffectDefault.rawValue, forKey: "clickEffectDefault") } }
    var recordHotKey: HotKey { didSet { d.set(try? JSONEncoder().encode(recordHotKey), forKey: "recordHotKey") } }
    var pauseHotKey: HotKey { didSet { d.set(try? JSONEncoder().encode(pauseHotKey), forKey: "pauseHotKey") } }
    var markerHotKey: HotKey { didSet { d.set(try? JSONEncoder().encode(markerHotKey), forKey: "markerHotKey") } }
    /// Cycles the live camera layout while recording (overlay → full camera → screen only).
    var layoutHotKey: HotKey { didSet { d.set(try? JSONEncoder().encode(layoutHotKey), forKey: "layoutHotKey") } }
    var libraryPath: String? { didSet { d.set(libraryPath, forKey: "libraryPath") } }
    var onboardingDone: Bool { didSet { d.set(onboardingDone, forKey: "onboardingDone") } }
    var cameraBubbleSize: CameraBubbleSize { didSet { d.set(cameraBubbleSize.rawValue, forKey: "cameraBubbleSize") } }
    /// The live bubble's shape; recorded with the take, so the editor starts with the same one.
    var cameraShape: CameraLayout.Shape { didSet { d.set(cameraShape.rawValue, forKey: "cameraShape") } }
    var afterRecording: AfterRecording { didSet { d.set(afterRecording.rawValue, forKey: "afterRecording") } }

    var library: ProjectLibrary {
        libraryPath.map { ProjectLibrary(root: URL(fileURLWithPath: $0, isDirectory: true)) } ?? ProjectLibrary()
    }
}
