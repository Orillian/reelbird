import AppKit
import Observation
import ReelbirdCore

/// Root of the app's state. Owns the services, preferences, the recording flow and the windows.
@MainActor @Observable final class AppModel {
    let services: Services
    let prefs: Preferences
    @ObservationIgnored private var _windows: WindowManager?
    @ObservationIgnored private var _recording: RecordingController?
    var windows: WindowManager { _windows! }
    var recording: RecordingController { _recording! }
    let library: LibraryStore

    /// Whether a share destination with a secret is configured.
    private(set) var shareConfigured = false

    init(services: Services, prefs: Preferences) {
        self.services = services
        self.prefs = prefs
        self.library = LibraryStore(services: services, prefs: prefs)
        self._windows = WindowManager(app: self)
        self._recording = RecordingController(app: self)
        refreshShareState()
    }

    func refreshShareState() {
        shareConfigured = services.share.loadDestination() != nil && services.share.secret() != nil
    }

    // MARK: Commands

    func newRecording() { recording.showPicker() }

    /// The global record shortcut: stop if recording, otherwise start with the picker's choices.
    func toggleRecordingFromHotKey() {
        switch recording.phase {
        case .recording, .paused: recording.stop()
        case .picking: recording.startFromPicker()
        case .countdown: recording.skipCountdown()
        case .idle: recording.showPicker()
        case .selectingArea, .finishing: break
        }
    }

    func togglePauseFromHotKey() { recording.togglePause() }

    func open(bundle: ProjectBundle) { windows.openEditor(bundle: bundle) }

    func openLibrary() { windows.openLibrary() }
    func openSettings(_ tab: SettingsTab = .general) { windows.openSettings(tab) }
    func showOnboarding() { windows.openOnboarding() }

    func registerHotKeys() {
        HotKeyCenter.shared.register(.record, prefs.recordHotKey) { [weak self] in self?.toggleRecordingFromHotKey() }
        HotKeyCenter.shared.register(.pause, prefs.pauseHotKey) { [weak self] in self?.togglePauseFromHotKey() }
    }

    /// Presents an error as a plain-English alert.
    func present(_ error: any Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate()
        alert.runModal()
    }
}
