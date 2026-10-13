import AppKit
import AVFoundation
import Observation
import ReelbirdCapture
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
    /// Screen Recording isn't allowed yet: the picker asks for it instead of listing sources.
    private(set) var needsScreenPermission = false
    private(set) var microphones: [MediaDevice] = []
    private(set) var cameras: [MediaDevice] = []
    private(set) var micLevel: Double = 0
    var selectedDisplayID: String?
    var selectedWindowID: String? { didSet { if selectedWindowID != oldValue { notice = nil } } }
    /// A one-line note above the sources (e.g. the chosen window closed); the list stays usable.
    private(set) var notice: String?
    var area: AreaSelection?
    var shareAvailable = false
    var windowQuery = ""
    private(set) var microphoneAccess: PermissionState = .granted
    private(set) var cameraAccess: PermissionState = .granted
    /// Free space where recordings are saved, when it's low enough to mention.
    private(set) var lowDiskBytes: Int64?

    @ObservationIgnored private let services: Services
    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored private var metering = false
    /// The device the meter is listening to (resolved, so "Automatic" meters the mic it will record).
    @ObservationIgnored private var meteredID: String?

    init(services: Services, prefs: Preferences) {
        self.services = services
        self.prefs = prefs
        if let a = prefs.lastArea { area = AreaSelection(rect: a, displayID: Self.display(containing: a)) }
        // Coming back from System Settings: pick up a permission that took effect without a relaunch.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshInputAccess()
                guard self.needsScreenPermission, self.services.permissions.status(.screen) == .granted else { return }
                self.load()
            }
        }
        // Plugging in a USB mic or AirPods while the picker is open updates the list (and Automatic).
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshMicrophones() }
            }
        }
    }

    // MARK: Microphone choice

    /// What "Automatic" records with right now.
    var automaticMicrophone: MediaDevice? { microphones.bestMicrophone }

    /// The device a recording would lock to: the explicit choice, or the best one for Automatic (and
    /// when the chosen device isn't connected).
    var resolvedMicrophone: MediaDevice? { microphones.resolveMicrophone(prefs.microphoneID) }

    /// The chosen device is not connected (recording would use Automatic's pick instead).
    var chosenMicrophoneMissing: Bool {
        !microphones.isEmpty && MicPolicy.isMissing(prefs.microphoneID, in: microphones.map(\.micCandidate))
    }

    /// Set when the mic that would record is Bluetooth or call quality: what to say and what to offer.
    var callQualityAdvice: (device: MediaDevice, alternative: MediaDevice?)? {
        guard prefs.microphoneEnabled, let mic = resolvedMicrophone, mic.isCallQuality else { return nil }
        return (mic, microphones.alternative(to: mic))
    }

    /// One click from a Bluetooth mic to the best full-quality one. Goes back to Automatic when that
    /// is what Automatic picks, so a mic plugged in later is still preferred.
    func switchToFullQualityMicrophone() {
        guard let alt = callQualityAdvice?.alternative else { return }
        prefs.microphoneID = automaticMicrophone?.id == alt.id ? MicPolicy.automaticID : alt.id
    }

    /// The explicit device ID to record with, locked when recording starts.
    func lockedMicrophoneID() -> String {
        resolvedMicrophone?.id ?? MicPolicy.systemDefaultID
    }

    func refreshMicrophones() {
        microphones = services.capture.microphones()
        if metering, resolvedMicrophone?.id != meteredID { startMeters() }
    }

    /// The display under the rectangle's centre (global points, top-left origin), else the main display.
    static func display(containing rect: CGRect) -> UInt32 {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        let p = CGPoint(x: rect.midX, y: rect.midY)
        guard CGGetDisplaysWithPoint(p, 1, &id, &count) == .success, count > 0 else { return CGMainDisplayID() }
        return id
    }

    var displays: [AvailableSource] { sources.filter { $0.kind == .display } }
    var windows: [AvailableSource] {
        let all = sources.filter { $0.kind == .window }
        let q = windowQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(q) || ($0.appName ?? "").localizedCaseInsensitiveContains(q) }
    }

    /// Under this much free space the picker warns before you start (the control bar warns at 2 GB).
    static let lowDiskThreshold: Int64 = 5_000_000_000

    func refreshInputAccess() {
        let mic = services.permissions.status(.microphone)
        let changed = mic != microphoneAccess
        microphoneAccess = mic
        cameraAccess = services.permissions.status(.camera)
        if changed && mic == .granted && metering { startMeters() }
    }

    /// Asks for microphone or camera access the first time; afterwards macOS only allows it in
    /// System Settings, so open the right pane.
    func requestAccess(_ p: Permission) {
        let state = services.permissions.status(p)
        guard state != .granted else { return }
        if state == .notDetermined {
            Task {
                _ = await services.permissions.request(p)
                refreshInputAccess()
                if p == .microphone && metering { startMeters() }
            }
        } else {
            services.permissions.openSettings(for: p)
        }
    }

    func load() {
        refreshInputAccess()
        let root = prefs.library.root
        let probe = FileManager.default.fileExists(atPath: root.path) ? root : root.deletingLastPathComponent()
        let free = (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        lowDiskBytes = free.flatMap { $0 < Self.lowDiskThreshold ? $0 : nil }
        microphones = services.capture.microphones()
        cameras = services.capture.cameras()
        if prefs.cameraID == nil { prefs.cameraID = cameras.first(where: \.isDefault)?.id ?? cameras.first?.id }
        loadError = nil
        needsScreenPermission = services.permissions.status(.screen) != .granted
        guard !needsScreenPermission else { loading = false; return }
        loading = sources.isEmpty
        Task {
            do {
                let list = try await services.capture.list()
                apply(list)
                loadThumbnails()
            } catch CaptureError.permissionDenied {
                needsScreenPermission = true
            } catch {
                loadError = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            loading = false
        }
    }

    /// Asks for Screen Recording (the system prompt appears once) and opens System Settings when it
    /// was already refused. macOS applies the grant after Reelbird is reopened.
    func requestScreenPermission() {
        Task {
            if await services.permissions.request(.screen) == .granted {
                load()
            } else {
                services.permissions.openSettings(for: .screen)
            }
        }
    }

    /// Screen Recording usually takes effect only after the app restarts.
    func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// Fills in previews for sources listed without one, displays first.
    private func loadThumbnails() {
        thumbnailTask?.cancel()
        let pending = sources.filter { $0.thumbnail == nil }.sorted { $0.kind == .display && $1.kind != .display }
        guard !pending.isEmpty else { return }
        let capture = services.capture
        thumbnailTask = Task { [weak self] in
            for source in pending {
                guard !Task.isCancelled else { return }
                let width = source.kind == .display ? 480 : 320
                guard let img = await capture.thumbnail(for: source, maxPixelWidth: width) else { continue }
                guard let self, let i = self.sources.firstIndex(where: { $0.id == source.id }) else { continue }
                self.sources[i].thumbnail = img
            }
        }
    }

    func cancelThumbnails() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
    }

    /// Sets sources directly (snapshots).
    func apply(_ list: [AvailableSource]) {
        sources = list
        // Forget a choice that is gone (window closed, display unplugged) instead of failing at Start.
        if let id = selectedWindowID, !windows.contains(where: { $0.id == id }) { selectedWindowID = nil }
        if let id = selectedDisplayID, !displays.contains(where: { $0.id == id }) { selectedDisplayID = nil }
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
        metering = true
        guard prefs.microphoneEnabled else { micLevel = 0; return }
        let id = resolvedMicrophone?.id ?? prefs.microphoneID
        meteredID = id
        services.inputs.startMicrophoneMeter(deviceID: id) { [weak self] level in
            self?.micLevel = level
        }
    }

    func stopMeters() {
        metering = false
        meteredID = nil
        services.inputs.stopMicrophoneMeter()
        micLevel = 0
    }

    func setMicLevelForSnapshot(_ v: Double) { micLevel = v }
    func setAccessForSnapshot(microphone: PermissionState, camera: PermissionState, lowDisk: Int64? = nil) {
        microphoneAccess = microphone
        cameraAccess = camera
        lowDiskBytes = lowDisk
    }

    /// Re-lists sources and reports whether `source` still exists. A window can close while the picker
    /// is open; then the list refreshes and the picker says so instead of recording failing.
    func stillAvailable(_ source: CaptureSource) async -> Bool {
        guard case .window(let id, _, _) = source, let list = try? await services.capture.list() else { return true }
        apply(list)
        let found = list.contains { if case .window(let wid, _, _) = $0.source { return wid == id } else { return false } }
        if !found { notice = "That window has closed. Pick another one." }
        return found
    }

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
        if needsScreenPermission { return false }
        return switch prefs.sourceTab {
        case .display: selectedDisplayID != nil
        case .window: selectedWindowID != nil
        case .area: true // opens the area selector when no area yet
        }
    }
}
