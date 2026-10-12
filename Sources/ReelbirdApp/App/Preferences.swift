import Foundation
import Observation
import ReelbirdCore

enum SourceTab: String, CaseIterable, Codable { case display, window, area }

enum CameraBubbleSize: String, CaseIterable, Codable {
    case small, medium, large
    var points: CGFloat { switch self { case .small: 140; case .medium: 200; case .large: 280 } }
    var title: String { rawValue.capitalized }
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
        microphoneID = d.string(forKey: "microphoneID") ?? "default"
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
        libraryPath = d.string(forKey: "libraryPath")
        onboardingDone = d.bool(forKey: "onboardingDone")
        cameraBubbleSize = CameraBubbleSize(rawValue: d.string(forKey: "cameraBubbleSize") ?? "") ?? .medium
        openEditorAfterRecording = d.object(forKey: "openEditorAfterRecording") as? Bool ?? true
    }

    var sourceTab: SourceTab { didSet { d.set(sourceTab.rawValue, forKey: "sourceTab") } }
    var lastSourceID: String? { didSet { d.set(lastSourceID, forKey: "lastSourceID") } }
    /// Last area in global top-left-origin points.
    var lastArea: CGRect? { didSet { d.set(try? JSONEncoder().encode(lastArea), forKey: "lastArea") } }
    var microphoneEnabled: Bool { didSet { d.set(microphoneEnabled, forKey: "microphoneEnabled") } }
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
    var libraryPath: String? { didSet { d.set(libraryPath, forKey: "libraryPath") } }
    var onboardingDone: Bool { didSet { d.set(onboardingDone, forKey: "onboardingDone") } }
    var cameraBubbleSize: CameraBubbleSize { didSet { d.set(cameraBubbleSize.rawValue, forKey: "cameraBubbleSize") } }
    var openEditorAfterRecording: Bool { didSet { d.set(openEditorAfterRecording, forKey: "openEditorAfterRecording") } }

    var library: ProjectLibrary {
        libraryPath.map { ProjectLibrary(root: URL(fileURLWithPath: $0, isDirectory: true)) } ?? ProjectLibrary()
    }
}
