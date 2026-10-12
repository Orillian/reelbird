import AppKit
import ReelbirdCapture
import ReelbirdCore
import ServiceManagement
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, recording, sharing, permissions, about
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .recording: "record.circle"
        case .sharing: "link"
        case .permissions: "lock.shield"
        case .about: "info.circle"
        }
    }
}

/// Native toolbar-tab settings window; each tab is a SwiftUI form.
@MainActor final class SettingsWindowController: NSWindowController {
    private let tabs = NSTabViewController()

    init(app: AppModel) {
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        for tab in SettingsTab.allCases {
            let root = AnyView(SettingsPane(tab: tab, app: app).environment(app))
            let host = NSHostingController(rootView: root)
            host.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            item.identifier = tab.rawValue
            tabs.addTabViewItem(item)
        }
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.title = "Settings"
        super.init(window: w)
        w.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func select(_ tab: SettingsTab) {
        if let i = SettingsTab.allCases.firstIndex(of: tab) { tabs.selectedTabViewItemIndex = i }
        window?.title = tab.title
    }
}

struct SettingsPane: View {
    let tab: SettingsTab
    let app: AppModel
    var body: some View {
        Group {
            switch tab {
            case .general: GeneralSettings(app: app, prefs: app.prefs)
            case .recording: RecordingSettings(app: app, prefs: app.prefs)
            case .sharing: SharingSettingsPane(app: app)
            case .permissions: PermissionsSettingsPane(services: app.services)
            case .about: AboutSettings(app: app)
            }
        }
        .tint(Theme.accent)
    }
}

/// Consistent settings layout: grouped form, fixed width.
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 560)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: General

struct GeneralSettings: View {
    let app: AppModel?
    @Bindable var prefs: Preferences
    @ViewState private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @ViewState private var loginError: String?

    var body: some View {
        SettingsForm {
            Section {
                LabeledContent("Library") {
                    HStack(spacing: 8) {
                        Text(prefs.library.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Change…") { chooseLibrary() }
                        Button { NSWorkspace.shared.open(prefs.library.root) } label: { Image(systemName: "arrow.right.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Show in Finder")
                    }
                }
                Toggle("Open the editor when a recording stops", isOn: $prefs.openEditorAfterRecording).toggleStyle(.brand)
                Toggle("Open Reelbird at login", isOn: $launchAtLogin).toggleStyle(.brand)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError { StatusLine(tone: .warning, text: loginError) }
            }
            Section {
                LabeledContent("Start or stop recording") {
                    HotKeyField(key: $prefs.recordHotKey, defaultKey: .defaultRecord) { app?.registerHotKeys() }
                }
                LabeledContent("Pause or resume") {
                    HotKeyField(key: $prefs.pauseHotKey, defaultKey: .defaultPause) { app?.registerHotKeys() }
                }
            } header: {
                Text("Keyboard shortcuts")
            } footer: {
                Text("These work in every app. Click a shortcut, then press the new keys.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = prefs.library.root
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url {
            prefs.libraryPath = url.path
            app?.library.reload()
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "macOS didn't allow this: \(error.localizedDescription). Check System Settings → General → Login Items."
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// Click, then press a shortcut. Esc cancels, Delete restores the default.
struct HotKeyField: View {
    @Binding var key: HotKey
    let defaultKey: HotKey
    var onChange: () -> Void = {}
    @ViewState private var recording = false
    @ViewState private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Type shortcut…" : key.display)
                .font(.system(size: 12, weight: .medium, design: recording ? .default : .rounded))
                .foregroundStyle(recording ? Theme.accentText : .primary)
                .frame(minWidth: 96)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.fieldFill))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(recording ? Theme.accent : Color.primary.opacity(0.1), lineWidth: recording ? 1.5 : 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shortcut \(key.display)")
        .accessibilityHint("Click, then press new keys")
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        HotKeyCenter.shared.suspend(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = event.keyCode
            let hk = HotKey(event: event)
            MainActor.assumeIsolated {
                if code == 53 { stop(); return }
                if code == 51 { key = defaultKey; stop(); return }
                if let hk { key = hk; stop() } else { NSSound.beep() }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { recording = false; onChange() }
    }
}

// MARK: Recording

struct RecordingSettings: View {
    let app: AppModel?
    @Bindable var prefs: Preferences
    @ViewState private var keystrokeAccess: PermissionState = .notDetermined

    var body: some View {
        SettingsForm {
            Section {
                Picker("Frame rate", selection: $prefs.frameRate) {
                    Text("60 fps (smoothest)").tag(60)
                    Text("30 fps (smaller files)").tag(30)
                }
                Picker("Quality", selection: $prefs.quality) {
                    Text("High").tag(ReelbirdCoreQuality.high)
                    Text("Max, for sharp text on 5K screens").tag(ReelbirdCoreQuality.max)
                    Text("Compact, faster to share").tag(ReelbirdCoreQuality.compact)
                }
                Picker("Countdown", selection: $prefs.countdown) {
                    Text("Off").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                }
            }
            Section {
                Toggle("Show the cursor in new recordings", isOn: $prefs.showCursorDefault).toggleStyle(.brand)
                Picker("Click effect", selection: $prefs.clickEffectDefault) {
                    Text("Ripple").tag(ReelbirdClickEffect.ripple)
                    Text("Ring").tag(ReelbirdClickEffect.ring)
                    Text("Press").tag(ReelbirdClickEffect.press)
                    Text("None").tag(ReelbirdClickEffect.none)
                }
                Toggle("Record keystrokes for the keystroke overlay", isOn: $prefs.captureKeystrokes).toggleStyle(.brand)
                    .onChange(of: prefs.captureKeystrokes) { _, on in
                        guard on, let app, app.services.permissions.status(.inputMonitoring) == .notDetermined else { return }
                        Task { _ = await app.services.permissions.request(.inputMonitoring); keystrokeAccess = app.services.permissions.status(.inputMonitoring) }
                    }
                if prefs.captureKeystrokes, let app, keystrokeAccess != .granted {
                    HStack {
                        StatusLine(tone: .warning, text: "Needs Input Monitoring access, or no keys are recorded.")
                        Spacer()
                        Button("Open Settings") { app.services.permissions.openSettings(for: .inputMonitoring) }
                    }
                }
            } header: {
                Text("Cursor and keys")
            } footer: {
                Text("Reelbird records the cursor separately, so you can change all of this after recording. Keys are recorded only while you record.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .onAppear { keystrokeAccess = app?.services.permissions.status(.inputMonitoring) ?? .notDetermined }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            keystrokeAccess = app?.services.permissions.status(.inputMonitoring) ?? .notDetermined
        }
    }
}

typealias ReelbirdCoreQuality = RecordingOptions.Quality
typealias ReelbirdClickEffect = CursorSettings.ClickEffect

/// Holds the sharing form model for the life of the pane.
struct SharingSettingsPane: View {
    @ViewState private var model: SharingSettingsModel
    init(app: AppModel?) { _model = ViewState(initialValue: SharingSettingsModel(app: app)) }
    var body: some View { SharingSettings(model: model) }
}

struct PermissionsSettingsPane: View {
    @ViewState private var model: PermissionsModel
    init(services: Services) { _model = ViewState(initialValue: PermissionsModel(services: services)) }
    var body: some View { PermissionsSettings(model: model) }
}
