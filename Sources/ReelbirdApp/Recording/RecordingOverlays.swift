import AVFoundation
import AppKit
import ReelbirdCapture
import ReelbirdCore
import SwiftUI

// MARK: Countdown

@MainActor final class CountdownOverlay {
    private let window: FloatingPanel
    private unowned let controller: RecordingController

    init(controller: RecordingController) {
        self.controller = controller
        let screen = NSScreen.withMouse
        window = FloatingPanel(size: screen.frame.size, level: .screenSaver)
        window.isMovableByWindowBackground = false
        window.setFrame(screen.frame, display: false)
        let hosting = NSHostingView(rootView: CountdownView(controller: controller))
        window.contentView = hosting
        window.onEscape = { [weak controller] in controller?.cancelCountdown() }
        window.onReturn = { [weak controller] in controller?.skipCountdown() }
    }

    func present() {
        window.fadeIn()
        window.makeKey()
    }

    func dismiss() { window.fadeOut() }
}

final class CountdownKeyView: NSView {
    var onSpace: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { onSpace?() } else { super.keyDown(with: event) }
    }
}

struct CountdownView: View {
    let controller: RecordingController
    @Environment(\.isSnapshot) private var snapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var value: Int? = nil
    /// Fraction of the current second already elapsed (snapshots).
    var sweep: Double? = nil
    @ViewState private var progress: Double = 0

    var body: some View {
        let n = value ?? controller.countdownValue
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.6))
                    .frame(width: 168, height: 168)
                Circle()
                    .stroke(Color.white.opacity(0.14), lineWidth: 4)
                    .frame(width: 148, height: 148)
                // One sweep per second, so the ring says "about to start" without pulsing.
                Circle()
                    .trim(from: 0, to: reduceMotion ? 1 : (sweep ?? progress))
                    .stroke(Theme.recording, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 148, height: 148)
                Text("\(n)")
                    .font(.system(size: 84, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
                    .animation(reduceMotion ? nil : Theme.gentle, value: n)
            }
            .accessibilityElement()
            .accessibilityLabel("Recording starts in \(n)")
            .onChange(of: n, initial: true) { _, _ in
                guard !reduceMotion, sweep == nil else { return }
                progress = 0
                withAnimation(.linear(duration: 0.95)) { progress = 1 }
            }
            HStack(spacing: 14) {
                hint("Space", "start now")
                hint("Esc", "cancel")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.black.opacity(0.5)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KeyCatcher { controller.skipCountdown() })
        .onTapGesture { controller.skipCountdown() }
        .environment(\.colorScheme, .dark)
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.16)))
            Text(text).font(.system(size: 12))
        }
        .foregroundStyle(.white.opacity(0.85))
    }
}

/// Catches the space bar in overlays.
struct KeyCatcher: NSViewRepresentable {
    let onSpace: () -> Void
    func makeNSView(context: Context) -> CountdownKeyView {
        let v = CountdownKeyView()
        v.onSpace = onSpace
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }
    func updateNSView(_ v: CountdownKeyView, context: Context) { v.onSpace = onSpace }
}

// MARK: Control bar

@MainActor final class ControlBarPanel {
    private let panel: FloatingPanel
    /// Room for the bar plus up to three warnings above it (transparent where empty).
    static let size = NSSize(width: 560, height: 230)

    init(controller: RecordingController, app: AppModel) {
        panel = FloatingPanel(size: Self.size, level: .statusBar, allowsKey: false)
        let view = ControlBarView(controller: controller, prefs: app.prefs, permissions: app.services.permissions)
            .frame(width: Self.size.width, height: Self.size.height, alignment: .bottom)
        let hosting = FirstMouseHostingView(rootView: view)
        panel.contentView = hosting
        panel.setContentSize(Self.size)
    }

    func present() {
        let screen = NSScreen.withMouse.visibleFrame
        if panel.frame.origin == .zero || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
            panel.setFrameOrigin(NSPoint(x: screen.midX - Self.size.width / 2, y: screen.minY + 16))
        }
        panel.fadeIn()
    }

    func dismiss() { panel.fadeOut() }
}

struct ControlBarView: View {
    let controller: RecordingController?
    @Bindable var prefs: Preferences
    var permissions: (any PermissionsService)? = nil
    var status: RecorderStatus? = nil
    var phase: RecordingController.Phase? = nil
    /// Snapshot override for the meter's dBFS reading.
    var levels: MicLevelReading? = nil
    @Environment(\.isSnapshot) private var snapshot
    /// Start over and discard both delete the take, so each asks once, inline, above the bar.
    private enum Confirmation { case discard, startOver }
    @ViewState private var confirming: Confirmation?

    private var st: RecorderStatus { status ?? controller?.status ?? RecorderStatus() }
    private var ph: RecordingController.Phase { phase ?? controller?.phase ?? .recording }
    private var warnings: [HealthWarning] { status == nil ? (controller?.visibleWarnings ?? []) : st.warnings }
    private var meterLevels: MicLevelReading {
        levels ?? controller?.micLevels
            ?? MicLevelReading(peakDB: MicLevelReading.floorDB + st.microphoneLevel * 60 + 10, rmsDB: MicLevelReading.floorDB + st.microphoneLevel * 60)
    }

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            ForEach(warnings) { w in
                warning(w)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let confirming { confirmation(confirming).transition(.opacity) }
            bar
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .animation(Theme.gentle, value: warnings)
        .animation(Theme.snappy, value: confirming)
    }

    private var bar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(ph == .paused ? Color.secondary : Theme.recording)
                    .frame(width: 8, height: 8)
                Text(TimeFormat.clock(st.elapsed))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 44, alignment: .leading)
            }
            .padding(.leading, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(ph == .paused ? "Paused at \(TimeFormat.clock(st.elapsed))" : "Recording, \(TimeFormat.clock(st.elapsed))")

            if prefs.microphoneEnabled {
                if let permissions, permissions.status(.microphone) != .granted {
                    // A flat meter would look like a quiet room; say why there's no sound instead.
                    Button { permissions.openSettings(for: .microphone) } label: {
                        Label("No mic access", systemImage: "mic.slash.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.warning)
                    }
                    .buttonStyle(.plain)
                    .help("Microphone access is off, so this take has no voice. Click to open System Settings.")
                } else {
                    Image(systemName: "mic.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    MicMeter(reading: meterLevels, active: ph == .recording)
                        .frame(width: 56)
                }
            }
            if let _ = st.shareURL {
                HStack(spacing: 4) {
                    Image(systemName: "link").font(.system(size: 10, weight: .semibold))
                    Text(st.uploadBacklog > 0 ? "\(st.uploadBacklog) queued" : "Live")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                }
                .foregroundStyle(st.uploadBacklog > 3 ? Theme.warning : Color.secondary)
                .padding(.leading, 4)
                .help("Your link is uploading while you record")
                .accessibilityElement(children: .combine)
                .accessibilityLabel(st.uploadBacklog > 0 ? "Link uploading, \(st.uploadBacklog) segments queued" : "Link is live")
            }

            Divider().frame(height: 18).padding(.horizontal, 4)

            Button { controller?.togglePause() } label: {
                Image(systemName: ph == .paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(IconButtonStyle(size: 30, active: ph == .paused))
            .help(ph == .paused ? "Resume (\(prefs.pauseHotKey.display))" : "Pause (\(prefs.pauseHotKey.display))")
            .accessibilityLabel(ph == .paused ? "Resume" : "Pause")

            Button { confirming = .startOver } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(IconButtonStyle(size: 30))
                .help("Start over (discards this take)")
                .accessibilityLabel("Start over")

            Button { confirming = .discard } label: { Image(systemName: "trash") }
                .buttonStyle(IconButtonStyle(size: 30))
                .help("Discard this take")
                .accessibilityLabel("Discard")

            Button { controller?.stop() } label: {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2.5).fill(Theme.onAccent).frame(width: 10, height: 10)
                    Text("Stop")
                }
            }
            .buttonStyle(PrimaryButtonStyle(tint: Theme.recording))
            .help("Stop and save (\(prefs.recordHotKey.display))")
            .accessibilityLabel("Stop recording")
            .padding(.leading, 2)
        }
        .padding(6)
        .floatingSurface(cornerRadius: 14, snapshot: snapshot)
        .fixedSize()
    }

    /// One line when it fits the bar's width, otherwise wrapped.
    private func warning(_ w: HealthWarning) -> some View {
        ViewThatFits(in: .horizontal) {
            warningRow(w, wrapWidth: nil)
            warningRow(w, wrapWidth: action(for: w) == nil ? 430 : 330)
        }
    }

    private func warningRow(_ w: HealthWarning, wrapWidth: CGFloat?) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: symbol(for: w.kind))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(w.kind == .microphoneChanged ? Color.secondary : Theme.warning)
                .frame(width: 16)
            Group {
                if let wrapWidth {
                    Text(w.message).fixedSize(horizontal: false, vertical: true).frame(width: wrapWidth, alignment: .leading)
                } else {
                    Text(w.message).fixedSize()
                }
            }
            .font(.system(size: 12, weight: .medium))
            if let action = action(for: w) {
                Button(action.title, action: action.run)
                    .buttonStyle(.link)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accentText)
                    .fixedSize()
            }
            Button { controller?.dismiss(w) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(IconButtonStyle(size: 18))
            .help("Dismiss")
            .accessibilityLabel("Dismiss warning")
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
        .frame(minHeight: 32)
        .floatingSurface(cornerRadius: 10, snapshot: snapshot)
        .fixedSize()
        .accessibilityElement(children: .contain)
    }

    private struct WarningAction {
        let title: String
        let run: () -> Void
    }

    private func action(for w: HealthWarning) -> WarningAction? {
        let soundSettings = {
            if let u = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input") { NSWorkspace.shared.open(u) }
        }
        switch w.kind {
        case .talkingWhilePaused: return WarningAction(title: "Resume") { controller?.togglePause() }
        case .microphoneSilent: return WarningAction(title: "Check Sound Settings", run: soundSettings)
        case .microphoneClipping, .microphoneTooQuiet: return WarningAction(title: "Input Level…", run: soundSettings)
        default: return nil
        }
    }

    private func confirmation(_ kind: Confirmation) -> some View {
        HStack(spacing: 10) {
            Text(kind == .discard ? "Discard this take? It can't be undone." : "Start over? This take will be deleted.")
                .font(.system(size: 12, weight: .medium))
            Button("Keep") { confirming = nil }.buttonStyle(SecondaryButtonStyle())
            Button(kind == .discard ? "Discard" : "Start Over") {
                confirming = nil
                if kind == .discard { controller?.discard() } else { controller?.restart() }
            }
            .buttonStyle(PrimaryButtonStyle(tint: Theme.recording))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .floatingSurface(cornerRadius: 12, snapshot: snapshot)
        .fixedSize()
    }

    private func symbol(for kind: HealthWarning.Kind) -> String {
        switch kind {
        case .microphoneSilent: "mic.slash.fill"
        case .captureStalled: "pause.rectangle.fill"
        case .avDrift: "waveform.badge.exclamationmark"
        case .lowDisk: "internaldrive.fill"
        case .uploadBacklog: "icloud.and.arrow.up.fill"
        case .shareFailed: "icloud.slash.fill"
        case .permissionMissing: "lock.fill"
        case .microphoneDisconnected: "mic.badge.xmark"
        case .microphoneChanged: "arrow.triangle.swap"
        case .microphoneClipping: "waveform.path.badge.minus"
        case .microphoneTooQuiet: "speaker.wave.1.fill"
        case .talkingWhilePaused: "waveform"
        }
    }
}

/// The control bar's microphone meter: the recent peak on a −60…0 dBFS scale, with the speech target
/// zone (−18…−6 dBFS) marked. Green inside the zone, amber above it, coral when clipping.
struct MicMeter: View {
    var reading: MicLevelReading
    var active = true
    var height: CGFloat = 6

    private static let band = (lo: MicLevelReading.meterPosition(MicLevelReading.targetPeakRange.lowerBound),
                               hi: MicLevelReading.meterPosition(MicLevelReading.targetPeakRange.upperBound))

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fill = active ? reading.peakPosition : 0
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.12))
                Rectangle().fill(Theme.success.opacity(0.2))
                    .frame(width: (Self.band.hi - Self.band.lo) * w)
                    .offset(x: Self.band.lo * w)
                Rectangle().fill(color)
                    .frame(width: fill * w)
                // Zone edges stay visible over the fill.
                ForEach([Self.band.lo, Self.band.hi], id: \.self) { x in
                    Rectangle().fill(Color.primary.opacity(0.35)).frame(width: 1).offset(x: x * w - 0.5)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .animation(.linear(duration: 0.08), value: reading.peakDB)
        .help("Aim for speech peaks in the green zone")
        .accessibilityElement()
        .accessibilityLabel("Microphone level")
        .accessibilityValue(accessibilityValue)
    }

    private var color: Color {
        let db = reading.peakDB
        if db >= -1 { return Theme.recording }
        if db > MicLevelReading.targetPeakRange.upperBound { return Theme.warning }
        if db >= MicLevelReading.targetPeakRange.lowerBound { return Theme.success }
        return Color.primary.opacity(0.45)
    }

    private var accessibilityValue: String {
        guard active, reading.peakDB > MicLevelReading.floorDB else { return "Silent" }
        let db = Int(reading.peakDB.rounded())
        let zone = reading.peakDB > MicLevelReading.targetPeakRange.upperBound ? "too loud"
            : reading.peakDB >= MicLevelReading.targetPeakRange.lowerBound ? "in the target range" : "quiet"
        return "\(db) decibels, \(zone)"
    }
}

// MARK: Camera bubble

@MainActor final class CameraBubbleController {
    private var panel: FloatingPanel?
    private var deviceID: String?
    private var builtWithAccess = false
    private let services: Services
    private let prefs: Preferences

    init(services: Services, prefs: Preferences) {
        self.services = services
        self.prefs = prefs
    }

    func show(deviceID: String) {
        // Rebuild when camera access changed too: a bubble made before access was granted only holds a placeholder.
        let access = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        if panel != nil && self.deviceID == deviceID && builtWithAccess == access { return }
        hide()
        self.deviceID = deviceID
        builtWithAccess = access
        let d = prefs.cameraBubbleSize.points
        // Never key: dragging the bubble mustn't take focus from the app being recorded. It stays
        // out of the screen capture too: the camera is its own track, composited in the editor.
        let p = FloatingPanel(size: NSSize(width: d, height: d), level: .statusBar, allowsKey: false)
        let view = CameraBubbleView(camera: services.inputs.makeCameraView(deviceID: deviceID),
                                    size: prefs.cameraBubbleSize) { [weak self] size in self?.resize(size) }
        p.contentView = FirstMouseHostingView(rootView: view)
        let screen = NSScreen.withMouse.visibleFrame
        p.setFrameOrigin(NSPoint(x: screen.minX + 32, y: screen.minY + 32))
        p.fadeIn()
        panel = p
    }

    func resize(_ size: CameraBubbleSize) {
        prefs.cameraBubbleSize = size
        guard let p = panel else { return }
        var f = p.frame
        let d = size.points
        f.origin.y += f.height - d
        f.size = NSSize(width: d, height: d)
        p.setFrame(f, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if let hosting = p.contentView as? FirstMouseHostingView<CameraBubbleView> {
            hosting.rootView = CameraBubbleView(camera: hosting.rootView.camera, size: size) { [weak self] s in self?.resize(s) }
        }
    }

    func hide() {
        panel?.fadeOut()
        panel = nil
        deviceID = nil
    }
}

struct CameraBubbleView: View {
    let camera: NSView
    let size: CameraBubbleSize
    let onResize: (CameraBubbleSize) -> Void
    @ViewState private var hovering = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ViewHost(view: camera)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 2.5))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            if hovering {
                HStack(spacing: 2) {
                    ForEach(CameraBubbleSize.allCases, id: \.self) { s in
                        Button { onResize(s) } label: {
                            Text(String(s.title.prefix(1)))
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 22, height: 20)
                                .foregroundStyle(s == size ? Color.black : .white)
                                .background(Capsule().fill(s == size ? Color.white : .clear))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(s.title) camera bubble")
                    }
                }
                .padding(3)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
        .padding(6)
        .onHover { h in withAnimation(Theme.snappy) { hovering = h } }
        .contextMenu {
            ForEach(CameraBubbleSize.allCases, id: \.self) { s in Button(s.title) { onResize(s) } }
        }
    }
}

/// Hosts an existing NSView in SwiftUI.
struct ViewHost: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: Toast

@MainActor enum Toast {
    private static var panel: FloatingPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(title: String, detail: String? = nil, symbol: String = "checkmark.circle.fill", duration: Double = 3.5) {
        panel?.orderOut(nil)
        let view = ToastView(title: title, detail: detail, symbol: symbol).padding(20)
        let p = FloatingPanel(size: .zero, level: .statusBar, allowsKey: false)
        p.ignoresMouseEvents = true
        let hosting = NSHostingView(rootView: view)
        p.contentView = hosting
        let size = hosting.fittingSize
        p.setContentSize(size)
        let screen = NSScreen.withMouse.visibleFrame
        p.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 8))
        p.fadeIn()
        panel = p
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            p.fadeOut()
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: [title, detail].compactMap { $0 }.joined(separator: ". "), .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Hides the toast now (a progress toast whose work finished).
    static func hide() {
        hideTask?.cancel()
        panel?.fadeOut()
        panel = nil
    }
}

struct ToastView: View {
    let title: String
    let detail: String?
    let symbol: String
    @Environment(\.isSnapshot) private var snapshot

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accentText)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.accentSoft))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        }
        .padding(.leading, 8).padding(.trailing, 16).padding(.vertical, 8)
        .floatingSurface(cornerRadius: 14, snapshot: snapshot)
    }
}
