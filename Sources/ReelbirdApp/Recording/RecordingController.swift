import AppKit
import Observation
import ReelbirdCore

/// Drives one recording from the source picker to the editor:
/// picker → (area selection) → countdown → recording ⇄ paused → finishing → editor.
@MainActor @Observable final class RecordingController {
    enum Phase: Equatable { case idle, picking, selectingArea, countdown, recording, paused, finishing }

    private(set) var phase: Phase = .idle
    private(set) var status = RecorderStatus()
    private(set) var countdownValue = 3
    /// The live camera layout, which the layout shortcut cycles while recording with the camera on.
    private(set) var liveLayout: LayoutSegment.Kind = .overlay
    /// Live microphone peak/RMS for the control bar meter's target zone.
    private(set) var micLevels = MicLevelReading()
    /// Warnings closed with ×, by episode (`HealthWarning.kind` + `since`): a condition that ends and
    /// comes back shows again.
    private(set) var dismissedWarnings: Set<String> = []
    let picker: SourcePickerModel

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var session: (any RecordingSessionHandle)?
    @ObservationIgnored private var lastOptions: RecordingOptions?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var pickerPanel: SourcePickerPanel?
    @ObservationIgnored private var areaSelection: AreaSelectionController?
    @ObservationIgnored private var countdown: CountdownOverlay?
    @ObservationIgnored private var controlBar: ControlBarPanel?
    @ObservationIgnored let cameraBubble: CameraBubbleController
    /// The app that was frontmost when the picker opened; it gets focus back when capture starts.
    @ObservationIgnored private var previousApp: NSRunningApplication?
    /// The app that owns the window being recorded, brought forward when capture starts.
    @ObservationIgnored private var recordedAppName: String?
    @ObservationIgnored private var pausedForSleep = false
    /// The post-stop quick actions card, while it shows.
    @ObservationIgnored private(set) var quickShare: QuickSharePanel?
    /// The marker just dropped, for the control bar's flash (cleared after a moment).
    private(set) var markerFlash: MarkerFlash?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init(app: AppModel) {
        self.app = app
        picker = SourcePickerModel(services: app.services, prefs: app.prefs)
        cameraBubble = CameraBubbleController(services: app.services, prefs: app.prefs)
        observeSleep()
    }

    /// A sleeping Mac stops delivering frames and audio. Pause the take before sleep so the
    /// recording has no frozen gap, and tell the user on wake instead of resuming behind their back.
    private func observeSleep() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillSleep() }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        })
    }

    func systemWillSleep() {
        switch phase {
        case .countdown: cancelCountdown(); closePicker()
        case .recording: togglePause(); pausedForSleep = true
        default: break
        }
    }

    func systemDidWake() {
        guard pausedForSleep, phase == .paused else { pausedForSleep = false; return }
        pausedForSleep = false
        Toast.show(title: "Recording paused while your Mac slept",
                   detail: "Press \(app.prefs.pauseHotKey.display) or Resume on the control bar to carry on.",
                   symbol: "pause.circle.fill", duration: 8)
    }

    var isActive: Bool { phase == .recording || phase == .paused || phase == .countdown }
    /// The bundle the current session writes into, from start until it is finished or discarded.
    private(set) var activeBundle: URL?
    var isSharing: Bool { status.shareURL != nil }

    // MARK: Picker

    func showPicker() {
        guard phase == .idle || phase == .picking else { return }
        quickShare?.close()
        if phase == .idle, let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        phase = .picking
        picker.shareAvailable = app.shareConfigured
        picker.load()
        let panel = pickerPanel ?? SourcePickerPanel(controller: self, app: app)
        pickerPanel = panel
        panel.present()
        picker.startMeters()
        syncCameraBubble()
    }

    func closePicker() {
        pickerPanel?.dismiss()
        picker.stopMeters()
        picker.cancelThumbnails()
        if phase == .picking { phase = .idle; cameraBubble.hide() }
    }

    /// Shows the floating camera bubble while picking or recording with the camera on.
    func syncCameraBubble() {
        if app.prefs.cameraEnabled && (phase == .picking || isActive) {
            cameraBubble.show(deviceID: app.prefs.cameraID ?? picker.cameras.first?.id ?? "default")
        } else {
            cameraBubble.hide()
        }
    }

    func startFromPicker() {
        guard phase == .picking, picker.canRecord else { return }
        if app.prefs.sourceTab == .area && picker.area == nil {
            beginAreaSelection()
            return
        }
        guard let source = picker.captureSource() else { Beep.play(); return }
        Task {
            guard await picker.stillAvailable(source), phase == .picking else { Beep.play(); return }
            guard await picker.bringOnScreenIfNeeded(source), phase == .picking else { Beep.play(); return }
            if case .window(_, let appName, _) = source { recordedAppName = appName } else { recordedAppName = nil }
            pickerPanel?.dismiss()
            picker.stopMeters()
            start(options: makeOptions(source: source))
        }
    }

    func beginAreaSelection() {
        pickerPanel?.dismiss()
        phase = .selectingArea
        let sel = AreaSelectionController(initial: app.prefs.lastArea) { [weak self] result in
            guard let self else { return }
            self.areaSelection = nil
            switch result {
            case .cancelled:
                self.phase = .picking
                self.pickerPanel?.present()
            case .selected(let rect, let displayID, let record):
                self.app.prefs.lastArea = rect
                self.picker.area = AreaSelection(rect: rect, displayID: displayID)
                self.phase = .picking
                if record { self.startFromPicker() } else { self.pickerPanel?.present() }
            }
        }
        areaSelection = sel
        sel.present()
    }

    private func makeOptions(source: CaptureSource) -> RecordingOptions {
        let p = app.prefs
        var o = RecordingOptions(source: source)
        o.frameRate = p.frameRate
        o.quality = p.quality
        o.captureSystemAudio = p.systemAudio
        if p.microphoneEnabled {
            // Lock the take to one explicit device, so macOS switching to AirPods mid-take changes nothing.
            picker.refreshMicrophones()
            o.microphoneID = picker.lockedMicrophoneID()
        } else {
            o.microphoneID = nil
        }
        o.cameraID = p.cameraEnabled ? (p.cameraID ?? picker.cameras.first?.id) : nil
        o.captureKeystrokes = p.captureKeystrokes
        o.shareWhileRecording = p.shareWhileRecording && app.shareConfigured
        o.countdown = p.countdown
        return o
    }

    // MARK: Recording

    func start(options: RecordingOptions) {
        lastOptions = options
        let library = app.prefs.library
        do {
            try FileManager.default.createDirectory(at: library.root, withIntermediateDirectories: true)
            var sink: (any ShareSegmentSink)?
            if options.shareWhileRecording, let d = app.services.share.loadDestination(), let secret = app.services.share.secret() {
                sink = app.services.share.makeLiveUploader(destination: d, secret: secret)
            }
            let bundleURL = library.newBundleURL()
            let s = try app.services.recorder.makeSession(options: options, bundleURL: bundleURL, shareSink: sink)
            session = s
            // Where the bubble sits (and every drag from here on) goes into the take's event log.
            cameraBubble.onPlace = { [weak s] frame, shape, host in s?.updateCameraBubble(frame: frame, shape: shape, atHostTime: host) }
            activeBundle = bundleURL
            app.library.activeRecording = bundleURL
            status = RecorderStatus()
            observe(s)
        } catch {
            phase = .idle
            app.present(error, title: "Recording couldn't start")
            return
        }
        syncCameraBubble()
        liveLayout = .overlay
        cameraBubble.setLiveLayout(.overlay)
        cameraBubble.reportPlace()
        if options.countdown > 0 {
            runCountdown(from: options.countdown)
        } else {
            beginCapture()
        }
        updateLayoutHotKey()
    }

    // MARK: Camera layout

    /// The layouts the shortcut cycles through while recording, in order.
    static let liveLayouts: [LayoutSegment.Kind] = [.overlay, .fullCamera, .screenOnly]

    /// Whether the layout shortcut applies now: a take with the camera on, counting down or recording.
    var canSwitchLayout: Bool { session != nil && isActive && lastOptions?.cameraID != nil }

    /// Registers the layout shortcut only while it applies, so it never takes the keys from other apps.
    func updateLayoutHotKey() {
        if canSwitchLayout {
            HotKeyCenter.shared.register(.layout, app.prefs.layoutHotKey) { [weak self] in self?.cycleCameraLayout() }
        } else {
            HotKeyCenter.shared.unregister(.layout)
        }
    }

    /// Bubble → camera only → screen only → bubble.
    func cycleCameraLayout() {
        guard canSwitchLayout else { return }
        let i = Self.liveLayouts.firstIndex(of: liveLayout) ?? 0
        setCameraLayout(Self.liveLayouts[(i + 1) % Self.liveLayouts.count])
    }

    /// Switches the live layout: logged with the take (the editor starts with matching layout segments), shown
    /// on the live bubble, and confirmed with a short toast.
    func setCameraLayout(_ layout: LayoutSegment.Kind) {
        guard canSwitchLayout, layout != liveLayout else { return }
        liveLayout = layout
        session?.updateCameraLayout(layout, atHostTime: nil)
        cameraBubble.setLiveLayout(layout)
        let next = Self.liveLayouts[((Self.liveLayouts.firstIndex(of: layout) ?? 0) + 1) % Self.liveLayouts.count]
        let hint = "\(app.prefs.layoutHotKey.display) switches to \(Self.layoutName(next).lowercased())."
        switch layout {
        case .fullCamera: Toast.show(title: "Camera only", detail: "The video shows your camera full frame. \(hint)", symbol: "person.crop.rectangle", duration: 2.5)
        case .screenOnly: Toast.show(title: "Screen only", detail: "The camera is hidden in the video. \(hint)", symbol: "macwindow", duration: 2.5)
        case .overlay, .split: Toast.show(title: "Camera bubble", detail: "Your camera is back in its bubble. \(hint)", symbol: "person.crop.circle", duration: 2.5)
        }
    }

    static func layoutName(_ k: LayoutSegment.Kind) -> String {
        switch k {
        case .overlay: "Camera bubble"
        case .fullCamera: "Camera only"
        case .screenOnly: "Screen only"
        case .split: "Split"
        }
    }

    private func runCountdown(from n: Int) {
        phase = .countdown
        countdownValue = n
        let overlay = CountdownOverlay(controller: self)
        countdown = overlay
        overlay.present()
        countdownTask = Task { [weak self] in
            for v in stride(from: n, through: 1, by: -1) {
                self?.countdownValue = v
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            self?.beginCapture()
        }
    }

    func skipCountdown() {
        guard phase == .countdown else { return }
        countdownTask?.cancel()
        beginCapture()
    }

    func cancelCountdown() {
        guard phase == .countdown else { return }
        countdownTask?.cancel()
        countdown?.dismiss(); countdown = nil
        Task { await session?.discard(); session = nil }
        phase = .picking
        HotKeyCenter.shared.unregister(.layout)
        pickerPanel?.present()
        picker.startMeters()
    }

    private func beginCapture() {
        countdown?.dismiss(); countdown = nil
        guard let session else { return }
        phase = .recording
        showControlBar()
        syncMarkerHotKey()
        handFocusBack()
        Task {
            do {
                try await session.start()
            } catch {
                self.teardown()
                self.app.present(error, title: "Recording couldn't start")
            }
        }
    }

    /// Recording a window brings its app forward; otherwise the app you were in gets focus back
    /// (Reelbird may have activated for the area selector or the Library window).
    private func handFocusBack() {
        let me = ProcessInfo.processInfo.processIdentifier
        if let name = recordedAppName,
           let target = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name && $0.processIdentifier != me }) {
            target.activate()
        } else if NSApp.isActive, let previousApp, !previousApp.isTerminated {
            previousApp.activate()
        }
    }

    private func observe(_ s: any RecordingSessionHandle) {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            for await st in s.status {
                guard let self else { return }
                self.announceNewWarnings(st.warnings)
                self.status = st
                self.micLevels = s.microphoneLevels
                if st.phase == .failed {
                    self.teardown()
                    self.app.present(RecordingFailure(warnings: st.warnings), title: "Recording stopped")
                    self.app.library.reload()
                }
            }
        }
    }

    // MARK: Warnings

    static func episodeKey(_ w: HealthWarning) -> String { "\(w.kind.rawValue)@\(w.since)" }

    /// Warnings to show on the control bar (dismissed episodes left out).
    var visibleWarnings: [HealthWarning] {
        status.warnings.filter { !dismissedWarnings.contains(Self.episodeKey($0)) }
    }

    func dismiss(_ w: HealthWarning) { dismissedWarnings.insert(Self.episodeKey(w)) }

    /// VoiceOver hears each new warning once (the control bar never takes focus).
    private func announceNewWarnings(_ warnings: [HealthWarning]) {
        let old = Set(status.warnings.map(Self.episodeKey))
        for w in warnings where !old.contains(Self.episodeKey(w)) {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: w.message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    func togglePause() {
        guard let session else { return }
        switch phase {
        case .recording:
            phase = .paused
            Task { await session.pause() }
        case .paused:
            phase = .recording
            Task { await session.resume() }
        default: break
        }
    }

    func stop(openEditor: Bool = true, completion: (() -> Void)? = nil) {
        guard let session, phase == .recording || phase == .paused || phase == .countdown else { completion?(); return }
        countdownTask?.cancel()
        countdown?.dismiss(); countdown = nil
        phase = .finishing
        updateLayoutHotKey()
        let shareURL = status.shareURL
        // Quitting saves the take and shows nothing; otherwise the person's choice in Settings.
        let after: AfterRecording = openEditor ? app.prefs.afterRecording : .nothing
        if let shareURL {
            // The link is ready before the last segments land: copy it the instant we stop.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(shareURL, forType: .string)
            if after != .quickActions {
                let backlog = max(status.uploadBacklog, 1)
                Toast.show(title: "Link copied", detail: "Still uploading \(backlog) segment\(backlog == 1 ? "" : "s")…", symbol: "link")
            }
        }
        // The card comes up at once (saving…) with the link already copied; the rest fills in when the take is saved.
        let card = after == .quickActions ? showQuickShare(shareURL: shareURL) : nil
        Task {
            do {
                let bundle = try await session.stop()
                let silentTake = session.microphoneTakeSummary?.isEssentiallySilent == true
                let issues = await session.trackIssues
                self.teardown()
                self.app.library.reload()
                if after == .openEditor { self.app.open(bundle: bundle) }
                await card?.takeFinished(bundle)
                if silentTake && openEditor { self.promptSilentTake(bundle) }
                if !issues.isEmpty { Self.reportTrackIssues(issues) }
            } catch {
                self.teardown()
                card?.takeFailed()
                self.quickShare?.close()
                self.app.present(error, title: "The recording couldn't be finished. Its segments are kept and will be recovered next launch.")
            }
            completion?()
        }
    }

    // MARK: Quick actions

    /// Shows the post-stop card in the bottom-left corner and returns its model.
    private func showQuickShare(shareURL: String?) -> QuickShareModel {
        quickShare?.close()
        var cursor = CursorSettings()
        cursor.visible = app.prefs.showCursorDefault
        cursor.clickEffect = app.prefs.clickEffectDefault
        let model = QuickShareModel(services: app.services, shareURL: shareURL, shareConfigured: app.shareConfigured, cursorDefaults: cursor)
        let panel = QuickSharePanel(model: model)
        model.onEdit = { [weak self, weak panel] bundle in
            panel?.close()
            self?.app.open(bundle: bundle)
        }
        model.onShare = { [weak self, weak panel] bundle in
            panel?.close()
            self?.openShare(bundle)
        }
        model.onSetUpSharing = { [weak self, weak panel] in
            panel?.close()
            self?.app.openSettings(.sharing)
        }
        panel.onClosed = { [weak self, weak panel] in
            if let self, self.quickShare === panel { self.quickShare = nil }
        }
        quickShare = panel
        panel.present()
        return model
    }

    /// Opens the editor with its Share popover.
    private func openShare(_ bundle: ProjectBundle) {
        app.open(bundle: bundle)
        let key = bundle.url.standardizedFileURL
        let editor = NSApp.windows.lazy.compactMap { $0.windowController as? EditorWindowController }
            .first { $0.model.bundle.url.standardizedFileURL == key }
        editor?.model.showShare = true
    }

    // MARK: Markers

    struct MarkerFlash: Equatable {
        var number: Int
        var title: String
        /// When it was dropped, on the take's clock (pauses left out), for the flash.
        var elapsed: Double
        var id = UUID()
    }

    /// The marker shortcut and the control bar's flag: drop a marker now and flash "Marker N" on the bar.
    func addMarker() {
        guard let session, phase == .recording || phase == .paused else { Beep.play(); return }
        let elapsed = status.elapsed
        Task {
            guard let m = await session.addMarker(label: nil) else { Beep.play(); return }
            let flash = MarkerFlash(number: m.number, title: m.label, elapsed: elapsed)
            markerFlash = flash
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: "\(m.label) added", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            try? await Task.sleep(for: .seconds(1.6))
            if markerFlash?.id == flash.id { markerFlash = nil }
        }
    }

    /// The marker shortcut is held only while a take runs, so the rest of the time it types in other apps.
    func syncMarkerHotKey() {
        if phase == .recording || phase == .paused {
            HotKeyCenter.shared.register(.marker, app.prefs.markerHotKey) { [weak self] in self?.addMarker() }
        } else {
            HotKeyCenter.shared.unregister(.marker)
        }
    }

    /// A track that stopped early or was left out (a camera that never started, an encoder that failed)
    /// is never dropped silently: say which and why once the take is saved.
    static func reportTrackIssues(_ issues: [TrackKind: String]) {
        let names: [TrackKind: String] = [.camera: "camera", .microphone: "microphone", .systemAudio: "system audio", .share: "share stream"]
        let sorted = issues.filter { $0.key != .screen }.sorted { $0.key.rawValue < $1.key.rawValue }
        guard let first = sorted.first else { return }
        let title = sorted.count == 1
            ? "The \(names[first.key] ?? first.key.rawValue) track is incomplete"
            : "\(sorted.count) tracks are incomplete"
        let detail = sorted.map { "\((names[$0.key] ?? $0.key.rawValue).prefix(1).uppercased() + (names[$0.key] ?? $0.key.rawValue).dropFirst()): \($0.value)." }
            .joined(separator: " ") + " The rest of the recording is saved."
        Toast.show(title: title, detail: detail, symbol: "exclamationmark.triangle.fill", duration: 9)
    }

    // MARK: Silent take

    /// "Your mic didn't pick anything up": offered right after stop, on the editor window when it opened.
    private func promptSilentTake(_ bundle: ProjectBundle) {
        let alert = NSAlert()
        alert.messageText = "Your mic didn't pick anything up in this take."
        let mic = lastOptions?.microphoneID.flatMap { id in picker.microphones.first { $0.id == id }?.name }
        alert.informativeText = mic.map { "Check that \($0) is the right microphone and isn't muted, then record again." }
            ?? "Check that the right microphone is selected and isn't muted, then record again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Record Again")
        alert.addButton(withTitle: "Keep Anyway")
        let handle: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertFirstButtonReturn { self?.recordAgain(discarding: bundle) }
        }
        // Wait a beat so the editor window is on screen and key.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            let key = bundle.url.standardizedFileURL
            let editor = NSApp.windows.first { w in
                (w.windowController as? EditorWindowController)?.model.bundle.url.standardizedFileURL == key && w.isVisible
            }
            if let editor, editor.attachedSheet == nil {
                alert.beginSheetModal(for: editor) { r in MainActor.assumeIsolated { handle(r) } }
            } else {
                alert.present(handle)
            }
        }
    }

    /// Moves the silent take to the Trash (restorable) and reopens the picker with the same settings.
    func recordAgain(discarding bundle: ProjectBundle) {
        if (try? bundle.readManifest())?.share != nil {
            // It has a share link: the usual Trash flow asks whether to delete the link too.
            app.moveToTrash(bundle)
            showPicker()
            return
        }
        app.windows.closeEditor(for: bundle)
        do {
            try FileManager.default.trashItem(at: bundle.url, resultingItemURL: nil)
        } catch {
            app.present(error, title: "Couldn't move the silent take to the Trash")
        }
        app.library.reload()
        showPicker()
    }

    func restart() {
        guard let options = lastOptions, isActive else { return }
        let s = session
        teardown()
        Task {
            await s?.discard()
            var o = options
            o.countdown = max(1, o.countdown)
            self.start(options: o)
        }
    }

    /// Start Over from the menu bar menu: it deletes the take, so it asks first, like Discard.
    func confirmRestart() {
        guard isActive else { return }
        let alert = NSAlert()
        alert.messageText = "Start over?"
        alert.informativeText = "This take will be deleted\(isSharing ? " and its link will stop working" : "") and a new recording starts. This can't be undone."
        alert.addButton(withTitle: "Start Over")
        alert.addButton(withTitle: "Keep Recording")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { restart() }
    }

    func confirmDiscard() {
        guard isActive else { return }
        let alert = NSAlert()
        alert.messageText = "Discard this recording?"
        alert.informativeText = "It will be deleted\(isSharing ? " and its link will stop working" : ""). This can't be undone."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Keep Recording")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { discard() }
    }

    func discard(completion: (() -> Void)? = nil) {
        let s = session
        teardown()
        Task {
            await s?.discard()
            completion?()
        }
    }

    private func showControlBar() {
        let bar = controlBar ?? ControlBarPanel(controller: self, app: app)
        controlBar = bar
        bar.present()
    }

    private func teardown() {
        statusTask?.cancel(); statusTask = nil
        countdownTask?.cancel(); countdownTask = nil
        countdown?.dismiss(); countdown = nil
        controlBar?.dismiss()
        session = nil
        activeBundle = nil
        app.library.activeRecording = nil
        phase = .idle
        status = RecorderStatus()
        micLevels = MicLevelReading()
        dismissedWarnings = []
        pausedForSleep = false
        recordedAppName = nil
        previousApp = nil
        cameraBubble.onPlace = nil
        liveLayout = .overlay
        cameraBubble.setLiveLayout(.overlay)
        cameraBubble.hide()
        markerFlash = nil
        syncMarkerHotKey()
        updateLayoutHotKey()
    }
}

struct RecordingFailure: LocalizedError {
    /// The recorder's last warnings, which usually say why it stopped (disk full, capture ended).
    var warnings: [HealthWarning] = []
    var errorDescription: String? {
        let reason = warnings.first { $0.kind == .lowDisk || $0.kind == .captureStalled }?.message
            ?? warnings.first?.message
        let saved = "Everything captured so far was saved and is in your Library."
        return reason.map { "\($0) \(saved)" } ?? "The recording stopped unexpectedly. \(saved)"
    }
}
