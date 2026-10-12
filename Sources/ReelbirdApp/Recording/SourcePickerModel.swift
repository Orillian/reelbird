import AppKit
import Observation
import ReelbirdCore

struct AreaSelection: Equatable {
    /// Global points, top-left origin.
    var rect: CGRect
    var displayID: UInt32
}

/// State behind the source picker: what can be recorded and the live input previews.
@MainActor @Observable final class SourcePickerModel {
    private(set) var sources: [AvailableSource] = []
    private(set) var loading = false
    private(set) var loadError: String?
    private(set) var microphones: [MediaDevice] = []
    private(set) var cameras: [MediaDevice] = []
    private(set) var micLevel: Double = 0
    var selectedDisplayID: String?
    var selectedWindowID: String?
    var area: AreaSelection?
    var shareAvailable = false
    var windowQuery = ""

    @ObservationIgnored private let services: Services
    @ObservationIgnored private let prefs: Preferences

    init(services: Services, prefs: Preferences) {
        self.services = services
        self.prefs = prefs
        if let a = prefs.lastArea { area = AreaSelection(rect: a, displayID: 0) }
    }

    var displays: [AvailableSource] { sources.filter { $0.kind == .display } }
    var windows: [AvailableSource] {
        let all = sources.filter { $0.kind == .window }
        let q = windowQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(q) || ($0.appName ?? "").localizedCaseInsensitiveContains(q) }
    }

    func load() {
        microphones = services.capture.microphones()
        cameras = services.capture.cameras()
        if prefs.cameraID == nil { prefs.cameraID = cameras.first(where: \.isDefault)?.id ?? cameras.first?.id }
        loading = sources.isEmpty
        loadError = nil
        Task {
            do {
                let list = try await services.capture.list()
                apply(list)
            } catch {
                loadError = "Reelbird can't see your screen yet. Allow Screen Recording in System Settings, then reopen Reelbird."
            }
            loading = false
        }
    }

    /// Sets sources directly (snapshots).
    func apply(_ list: [AvailableSource]) {
        sources = list
        let last = prefs.lastSourceID
        if selectedDisplayID == nil {
            selectedDisplayID = displays.first(where: { $0.id == last })?.id ?? displays.first?.id
        }
        if selectedWindowID == nil {
            selectedWindowID = windows.first(where: { $0.id == last })?.id ?? windows.first?.id
        }
        microphones = services.capture.microphones()
        cameras = services.capture.cameras()
    }

    func startMeters() {
        guard prefs.microphoneEnabled else { micLevel = 0; return }
        services.inputs.startMicrophoneMeter(deviceID: prefs.microphoneID) { [weak self] level in
            self?.micLevel = level
        }
    }

    func stopMeters() {
        services.inputs.stopMicrophoneMeter()
        micLevel = 0
    }

    func setMicLevelForSnapshot(_ v: Double) { micLevel = v }

    /// The capture source for the current tab and selection.
    func captureSource() -> CaptureSource? {
        switch prefs.sourceTab {
        case .display:
            guard let s = displays.first(where: { $0.id == selectedDisplayID }) else { return nil }
            prefs.lastSourceID = s.id
            return s.source
        case .window:
            guard let s = sources.first(where: { $0.id == selectedWindowID }) else { return nil }
            prefs.lastSourceID = s.id
            return s.source
        case .area:
            guard let a = area else { return nil }
            return .area(displayID: a.displayID, x: a.rect.minX, y: a.rect.minY, width: a.rect.width, height: a.rect.height)
        }
    }

    var canRecord: Bool {
        switch prefs.sourceTab {
        case .display: selectedDisplayID != nil
        case .window: selectedWindowID != nil
        case .area: true // opens the area selector when no area yet
        }
    }
}
