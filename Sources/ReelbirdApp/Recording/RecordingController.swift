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

    init(app: AppModel) {
        self.app = app
        picker = SourcePickerModel(services: app.services, prefs: app.prefs)
        cameraBubble = CameraBubbleController(services: app.services, prefs: app.prefs)
    }

    var isActive: Bool { phase == .recording || phase == .paused || phase == .countdown }
    var isSharing: Bool { status.shareURL != nil }

    // MARK: Picker

    func showPicker() {
        guard phase == .idle || phase == .picking else { return }
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
        guard let source = picker.captureSource() else { NSSound.beep(); return }
        pickerPanel?.dismiss()
        picker.stopMeters()
        start(options: makeOptions(source: source))
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
        o.microphoneID = p.microphoneEnabled ? p.microphoneID : nil
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
            let s = try app.services.recorder.makeSession(options: options, bundleURL: library.newBundleURL(), shareSink: sink)
            session = s
            status = RecorderStatus()
            observe(s)
        } catch {
            phase = .idle
            app.present(error, title: "Recording couldn't start")
            return
        }
        syncCameraBubble()
        if options.countdown > 0 {
            runCountdown(from: options.countdown)
        } else {
            beginCapture()
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
        pickerPanel?.present()
        picker.startMeters()
    }

    private func beginCapture() {
        countdown?.dismiss(); countdown = nil
        guard let session else { return }
        phase = .recording
        showControlBar()
        Task {
            do {
                try await session.start()
            } catch {
                self.teardown()
                self.app.present(error, title: "Recording couldn't start")
            }
        }
    }

    private func observe(_ s: any RecordingSessionHandle) {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            for await st in s.status {
                guard let self else { return }
                self.status = st
                if st.phase == .failed {
                    self.teardown()
                    self.app.present(RecordingFailure(), title: "Recording stopped")
                }
            }
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
        let shareURL = status.shareURL
        if let shareURL {
            // The link is ready before the last segments land: copy it the instant we stop.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(shareURL, forType: .string)
            let backlog = max(status.uploadBacklog, 1)
            Toast.show(title: "Link copied", detail: "Still uploading \(backlog) segment\(backlog == 1 ? "" : "s")…", symbol: "link")
        }
        Task {
            do {
                let bundle = try await session.stop()
                self.teardown()
                self.app.library.reload()
                if openEditor && self.app.prefs.openEditorAfterRecording { self.app.open(bundle: bundle) }
            } catch {
                self.teardown()
                self.app.present(error, title: "The recording couldn't be finished. Its segments are kept and will be recovered next launch.")
            }
            completion?()
        }
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

    func discard() {
        let s = session
        teardown()
        Task { await s?.discard() }
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
        phase = .idle
        status = RecorderStatus()
        cameraBubble.hide()
    }
}

struct RecordingFailure: LocalizedError {
    var errorDescription: String? {
        "Something went wrong while recording. Everything captured so far was saved and is in your Library."
    }
}
