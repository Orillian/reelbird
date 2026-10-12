import AppKit
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
    var value: Int? = nil

    var body: some View {
        let n = value ?? controller.countdownValue
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: 168, height: 168)
                Circle()
                    .trim(from: 0, to: 1)
                    .stroke(Color.white.opacity(0.18), lineWidth: 3)
                    .frame(width: 150, height: 150)
                Text("\(n)")
                    .font(.system(size: 84, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(Theme.gentle, value: n)
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
    static let size = NSSize(width: 520, height: 140)

    init(controller: RecordingController, app: AppModel) {
        panel = FloatingPanel(size: Self.size, level: .statusBar)
        let view = ControlBarView(controller: controller, prefs: app.prefs)
            .frame(width: Self.size.width, height: Self.size.height, alignment: .bottom)
        let hosting = NSHostingView(rootView: view)
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
    var status: RecorderStatus? = nil
    var phase: RecordingController.Phase? = nil
    @Environment(\.isSnapshot) private var snapshot
    @ViewState private var confirmingDiscard = false

    private var st: RecorderStatus { status ?? controller?.status ?? RecorderStatus() }
    private var ph: RecordingController.Phase { phase ?? controller?.phase ?? .recording }

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            ForEach(st.warnings) { w in
                warning(w)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if confirmingDiscard { discardConfirm.transition(.opacity) }
            bar
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .animation(Theme.gentle, value: st.warnings)
        .animation(Theme.snappy, value: confirmingDiscard)
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
                Image(systemName: "mic.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                LevelMeter(level: st.microphoneLevel, segments: 8, height: 5, active: ph == .recording)
                    .frame(width: 40)
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
            }

            Divider().frame(height: 18).padding(.horizontal, 4)

            Button { controller?.togglePause() } label: {
                Image(systemName: ph == .paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(IconButtonStyle(size: 30, active: ph == .paused))
            .help(ph == .paused ? "Resume (\(prefs.pauseHotKey.display))" : "Pause (\(prefs.pauseHotKey.display))")
            .accessibilityLabel(ph == .paused ? "Resume" : "Pause")

            Button { controller?.restart() } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(IconButtonStyle(size: 30))
                .help("Restart")
                .accessibilityLabel("Restart")

            Button { confirmingDiscard = true } label: { Image(systemName: "trash") }
                .buttonStyle(IconButtonStyle(size: 30))
                .help("Discard")
                .accessibilityLabel("Discard")

            Button { controller?.stop() } label: {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2.5).fill(Theme.onAccent).frame(width: 10, height: 10)
                    Text("Stop")
                }
            }
            .buttonStyle(PrimaryButtonStyle(tint: Theme.recording))
            .help("Stop (\(prefs.recordHotKey.display))")
            .padding(.leading, 2)
        }
        .padding(6)
        .floatingSurface(cornerRadius: 14, snapshot: snapshot)
        .fixedSize()
    }

    private func warning(_ w: HealthWarning) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol(for: w.kind))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.warning)
            Text(w.message)
                .font(.system(size: 12, weight: .medium))
            if w.kind == .microphoneSilent {
                Button("Check Sound Settings") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input") { NSWorkspace.shared.open(u) }
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .foregroundStyle(Theme.accentText)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .floatingSurface(cornerRadius: 10, snapshot: snapshot)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var discardConfirm: some View {
        HStack(spacing: 10) {
            Text("Discard this take? It can't be undone.").font(.system(size: 12, weight: .medium))
            Button("Keep") { confirmingDiscard = false }.buttonStyle(SecondaryButtonStyle())
            Button("Discard") { confirmingDiscard = false; controller?.discard() }
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
        }
    }
}

// MARK: Camera bubble

@MainActor final class CameraBubbleController {
    private var panel: FloatingPanel?
    private var deviceID: String?
    private let services: Services
    private let prefs: Preferences

    init(services: Services, prefs: Preferences) {
        self.services = services
        self.prefs = prefs
    }

    func show(deviceID: String) {
        if panel != nil && self.deviceID == deviceID { return }
        hide()
        self.deviceID = deviceID
        let d = prefs.cameraBubbleSize.points
        let p = FloatingPanel(size: NSSize(width: d, height: d), level: .statusBar)
        // The bubble is part of the take when recording a display, so leave it capturable.
        p.sharingType = .readOnly
        let view = CameraBubbleView(camera: services.inputs.makeCameraView(deviceID: deviceID),
                                    size: prefs.cameraBubbleSize) { [weak self] size in self?.resize(size) }
        p.contentView = NSHostingView(rootView: view)
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
        p.setFrame(f, display: true, animate: true)
        if let id = deviceID, let hosting = p.contentView as? NSHostingView<CameraBubbleView> {
            hosting.rootView = CameraBubbleView(camera: hosting.rootView.camera, size: size) { [weak self] s in self?.resize(s) }
            _ = id
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
        let p = FloatingPanel(size: .zero, level: .statusBar)
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
