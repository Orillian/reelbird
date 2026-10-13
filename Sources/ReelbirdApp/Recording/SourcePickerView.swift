import AppKit
import ReelbirdCapture
import ReelbirdCore
import SwiftUI

/// The compact "what do you want to record?" panel.
struct SourcePickerView: View {
    let model: SourcePickerModel
    let controller: RecordingController?
    @Bindable var prefs: Preferences
    var onSetUpSharing: () -> Void = {}
    var onOpenLibrary: () -> Void = {}
    var onClose: () -> Void = {}
    @Environment(\.isSnapshot) private var snapshot

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Theme.Space.l)
                .padding(.top, Theme.Space.m)
                .padding(.bottom, Theme.Space.m)
            if let notice = model.notice {
                StatusLine(tone: .warning, text: notice)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.bottom, Theme.Space.s)
            }
            sourceArea
                .frame(height: 214)
                .padding(.horizontal, Theme.Space.l)
            Divider().padding(.top, Theme.Space.m)
            inputs
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.s)
            Divider()
            if model.lowDiskBytes != nil {
                diskWarning
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.top, Theme.Space.m)
            }
            footer
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.m)
        }
        .frame(width: 452)
        .floatingSurface(cornerRadius: 16, snapshot: snapshot, glass: false)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.Space.m) {
            PillTabs(selection: $prefs.sourceTab, items: [
                .init(value: .display, title: "Display", symbol: "display"),
                .init(value: .window, title: "Window", symbol: "macwindow"),
                .init(value: .area, title: "Area", symbol: "rectangle.dashed"),
            ])
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle(size: 26))
            .help("Close (Esc)")
            .accessibilityLabel("Close")
        }
    }

    // MARK: Sources

    @ViewBuilder private var sourceArea: some View {
        if model.needsScreenPermission {
            screenPermission
        } else if let error = model.loadError {
            VStack(spacing: Theme.Space.s) {
                Image(systemName: "eye.slash").font(.system(size: 22)).foregroundStyle(.secondary)
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.loading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch prefs.sourceTab {
            case .display: displays
            case .window: windows
            case .area: areaTab
            }
        }
    }

    /// Shown instead of the sources until Screen Recording is allowed.
    private var screenPermission: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.accentText)
                .padding(.bottom, 2)
            Text("Allow screen recording")
                .font(.system(size: 14, weight: .semibold))
            Text("macOS asks before any app can record your screen. Turn on Reelbird in System Settings, then reopen Reelbird.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 330)
            HStack(spacing: Theme.Space.m) {
                Button("Open System Settings") { model.requestScreenPermission() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Quit & Reopen") { model.relaunch() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accentText)
            }
            .padding(.top, Theme.Space.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var displays: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            ForEach(model.displays) { d in
                SourceTile(source: d, selected: model.selectedDisplayID == d.id, large: true)
                    .frame(maxWidth: model.displays.count == 1 ? 280 : .infinity)
                    .onTapGesture { model.selectedDisplayID = d.id }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { controller?.startFromPicker() })
                    .accessibilityAction { model.selectedDisplayID = d.id }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 2)
    }

    private var windows: some View {
        VStack(spacing: Theme.Space.s) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
                TextField("Find a window", text: Bindable(model).windowQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.fieldFill))
            ScrollView(.vertical) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.s), count: 3), spacing: Theme.Space.s) {
                    ForEach(model.windows) { w in
                        SourceTile(source: w, selected: model.selectedWindowID == w.id, large: false)
                            .onTapGesture { model.selectedWindowID = w.id }
                            .simultaneousGesture(TapGesture(count: 2).onEnded { controller?.startFromPicker() })
                            .accessibilityAction { model.selectedWindowID = w.id }
                    }
                }
                .padding(2)
            }
            .scrollIndicators(.never)
        }
    }

    private var areaTab: some View {
        VStack(spacing: Theme.Space.m) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.fieldFill)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color.primary.opacity(0.18))
                if let a = model.area {
                    let aspect = a.rect.width / max(1, a.rect.height)
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Theme.ink.opacity(0.7), lineWidth: 1.5)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.ink.opacity(0.06)))
                            .aspectRatio(aspect, contentMode: .fit)
                            .frame(maxWidth: 170, maxHeight: 92)
                        let scale = NSScreen.screens.first { $0.displayID == a.displayID }?.backingScaleFactor ?? 2
                        Text(verbatim: "\(Int(a.rect.width * scale)) × \(Int(a.rect.height * scale))")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        Text(verbatim: "Last area · \(Int(a.rect.width)) × \(Int(a.rect.height)) pt")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "rectangle.dashed").font(.system(size: 24, weight: .light)).foregroundStyle(.secondary)
                        Text("Drag across your screen to pick an area").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 158)
            HStack {
                Button(model.area == nil ? "Select Area…" : "Change Area…") { controller?.beginAreaSelection() }
                    .buttonStyle(SecondaryButtonStyle())
                Spacer()
                Text("Return to record · Esc to cancel").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Inputs

    private var inputs: some View {
        VStack(spacing: 2) {
            InputRow(symbol: prefs.microphoneEnabled ? "mic.fill" : "mic.slash", title: "Microphone", isOn: $prefs.microphoneEnabled) {
                if prefs.microphoneEnabled {
                    if model.microphoneAccess != .granted {
                        allowButton("Allow Microphone…", .microphone)
                    } else {
                        LevelMeter(level: model.micLevel, segments: 10, height: 5).frame(width: 52)
                        MicrophoneMenu(devices: model.microphones, selection: $prefs.microphoneID)
                    }
                }
            }
            .onChange(of: prefs.microphoneEnabled) { _, on in on ? model.startMeters() : model.stopMeters() }
            .onChange(of: prefs.microphoneID) { _, _ in model.startMeters() }
            if prefs.microphoneEnabled, model.microphoneAccess == .granted {
                microphoneNotes
            }

            InputRow(symbol: prefs.cameraEnabled ? "video.fill" : "video.slash", title: "Camera", isOn: $prefs.cameraEnabled) {
                if prefs.cameraEnabled {
                    if model.cameraAccess != .granted {
                        allowButton("Allow Camera…", .camera)
                    } else {
                        DeviceMenu(devices: model.cameras, selection: Binding(get: { prefs.cameraID ?? "" }, set: { prefs.cameraID = $0 }))
                    }
                }
            }
            .onChange(of: prefs.cameraEnabled) { _, _ in controller?.syncCameraBubble() }
            .onChange(of: model.cameraAccess) { _, _ in controller?.syncCameraBubble() }
            .onChange(of: prefs.cameraID) { _, _ in controller?.syncCameraBubble() }

            InputRow(symbol: prefs.systemAudio ? "speaker.wave.2.fill" : "speaker.slash", title: "System audio", isOn: $prefs.systemAudio) {
                EmptyView()
            }

            InputRow(symbol: "link", title: "Share while recording",
                     isOn: Binding(get: { prefs.shareWhileRecording && model.shareAvailable }, set: { prefs.shareWhileRecording = $0 }),
                     enabled: model.shareAvailable) {
                if !model.shareAvailable {
                    Button("Set Up…", action: onSetUpSharing)
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        .help("Links upload to your own storage bucket. Set it up once in Settings.")
                } else if prefs.shareWhileRecording {
                    Text("Link copied when you stop").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Inline advice under the microphone row: a Bluetooth (call-quality) mic, or a chosen mic that
    /// isn't connected.
    @ViewBuilder private var microphoneNotes: some View {
        if let advice = model.callQualityAdvice {
            HStack(alignment: .center, spacing: Theme.Space.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                    .frame(width: 18)
                Text(Self.callQualityText(advice.device, alternative: advice.alternative))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if advice.alternative != nil {
                    Button("Switch") { model.switchToFullQualityMicrophone() }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        .help("Record with \(advice.alternative?.name ?? "") instead")
                }
            }
            .padding(.bottom, Theme.Space.xs)
            .accessibilityElement(children: .contain)
        } else if model.chosenMicrophoneMissing, let fallback = model.resolvedMicrophone {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Image(systemName: "info.circle.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("Your chosen mic isn't connected. This take will use \(fallback.name).")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, Theme.Space.xs)
        }
    }

    static func callQualityText(_ device: MediaDevice, alternative: MediaDevice?) -> String {
        let what: String
        if device.transport == .bluetooth {
            what = device.name.localizedCaseInsensitiveContains("AirPods") ? "AirPods mics" : "Bluetooth mics"
        } else {
            what = "\(device.name) records at \(MicStyle.rate(device.sampleRate) ?? "a low rate") and"
        }
        let problem = device.transport == .bluetooth
            ? "\(what) record in call quality and make what you hear worse."
            : "\(what) sounds like a phone call."
        guard let alternative else { return "\(problem) A built-in or wired mic sounds much better." }
        return "\(problem) Use \(alternative.name) instead?"
    }

    private func allowButton(_ title: String, _ p: Permission) -> some View {
        // Neutral, not coral: the record button is the one coral thing on this panel.
        Button(title) { model.requestAccess(p) }
            .buttonStyle(SecondaryButtonStyle(small: true))
            .help(p == .microphone
                  ? "Reelbird can't hear your mic yet, so the take would be silent."
                  : "Reelbird can't see your camera yet.")
    }

    // MARK: Footer

    @ViewBuilder private var diskWarning: some View {
        if let free = model.lowDiskBytes {
            StatusLine(tone: .warning,
                       text: "Only \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free. A long take may not fit.")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.s) {
            Menu {
                Picker("Quality", selection: $prefs.quality) {
                    Text("High (HEVC)").tag(RecordingOptions.Quality.high)
                    Text("Max, for sharp text on 5K").tag(RecordingOptions.Quality.max)
                    Text("Compact (H.264)").tag(RecordingOptions.Quality.compact)
                }
                .pickerStyle(.inline)
                Picker("Frame rate", selection: $prefs.frameRate) {
                    Text("60 fps").tag(60)
                    Text("30 fps").tag(30)
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 11))
                    Text("\(qualityName) · \(prefs.frameRate) fps").font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(.secondary)
            .fixedSize()

            Button(action: onOpenLibrary) {
                HStack(spacing: 4) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 11))
                    Text("Library").font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, Theme.Space.m)
            .help("Your recordings (⇧⌘L)")

            Spacer()

            Button {
                controller?.startFromPicker()
            } label: {
                HStack(spacing: 7) {
                    Circle().fill(Theme.onAccent).frame(width: 9, height: 9)
                    Text(prefs.sourceTab == .area && model.area == nil ? "Select Area" : "Start Recording")
                    Text(prefs.recordHotKey.display)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .opacity(0.72)
                }
            }
            .buttonStyle(PrimaryButtonStyle(tint: Theme.recording, large: true))
            .disabled(!model.canRecord)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var qualityName: String {
        switch prefs.quality { case .high: "High"; case .max: "Max"; case .compact: "Compact" }
    }
}

/// A display or window thumbnail with a selection ring.
struct SourceTile: View {
    let source: AvailableSource
    let selected: Bool
    let large: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 7 : 5) {
            ZStack {
                RoundedRectangle(cornerRadius: large ? 9 : 7, style: .continuous).fill(Theme.fieldFill)
                if let img = source.thumbnail {
                    Image(decorative: img, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: large ? 5 : 4, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                        .padding(large ? 8 : 6)
                } else {
                    Image(systemName: source.kind == .display ? "display" : "macwindow")
                        .font(.system(size: 20, weight: .light)).foregroundStyle(.tertiary)
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: large ? 9 : 7, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Color.primary.opacity(0.06), lineWidth: selected ? 2 : 0.5)
            )
            HStack(spacing: 5) {
                if source.kind == .window { AppIconView(appName: source.appName).frame(width: 14, height: 14) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.kind == .window ? (source.appName ?? source.title) : source.title)
                        .font(.system(size: large ? 12 : 11, weight: .medium))
                        .lineLimit(1)
                    Text(source.kind == .window ? source.title : "\(source.pixelSize.width) × \(source.pixelSize.height)")
                        .font(.system(size: large ? 11 : 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(source.kind == .window ? "\(source.appName ?? "") window, \(source.title)" : source.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The running app's icon, or a neutral glyph.
struct AppIconView: View {
    let appName: String?
    var body: some View {
        if let icon = Self.icon(for: appName) {
            Image(nsImage: icon).resizable()
        } else {
            Image(systemName: "app.dashed").resizable().foregroundStyle(.tertiary)
        }
    }

    @MainActor static func icon(for name: String?) -> NSImage? {
        guard let name else { return nil }
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name })?.icon { return running }
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    "/System/Volumes/Preboot/Cryptexes/App/System/Applications"]
        for d in dirs where FileManager.default.fileExists(atPath: "\(d)/\(name).app") {
            return NSWorkspace.shared.icon(forFile: "\(d)/\(name).app")
        }
        return nil
    }
}

/// One input toggle row in the picker.
struct InputRow<Accessory: View>: View {
    let symbol: String
    let title: String
    @Binding var isOn: Bool
    var enabled = true
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn ? Theme.ink : Color.secondary)
                .frame(width: 18)
            Text(title).font(.system(size: 12.5)).foregroundStyle(enabled ? .primary : .secondary)
            Spacer(minLength: Theme.Space.s)
            accessory
            BrandSwitch(isOn: $isOn).disabled(!enabled)
                .accessibilityElement()
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isToggle)
                .accessibilityValue(isOn ? "On" : "Off")
                .accessibilityAction { if enabled { isOn.toggle() } }
        }
        .frame(height: 32)
    }
}

/// Borderless device picker showing the selected device's name.
struct DeviceMenu: View {
    let devices: [MediaDevice]
    @Binding var selection: String

    var body: some View {
        Menu {
            ForEach(devices) { d in
                Button {
                    selection = d.id
                } label: {
                    if d.id == selection { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
                }
            }
        } label: {
            Text(devices.first(where: { $0.id == selection })?.name ?? devices.first(where: \.isDefault)?.name ?? devices.first?.name ?? "None")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .tint(.secondary)
        .fixedSize()
        .frame(maxWidth: 170, alignment: .trailing)
    }
}

/// Icons and subtitles for microphones in the picker.
enum MicStyle {
    static func symbol(_ d: MediaDevice) -> String {
        switch d.transport {
        case .builtIn: "laptopcomputer"
        case .interface: d.isCameraMic ? "web.camera" : "cable.connector"
        case .bluetooth: d.name.localizedCaseInsensitiveContains("AirPods") ? "airpods" : "headphones"
        case .continuity: "iphone"
        case .display: "display"
        case .virtual: "waveform"
        case .unknown: "mic"
        }
    }

    static func rate(_ hz: Double?) -> String? {
        guard let hz, hz > 0 else { return nil }
        let k = hz / 1000
        return k == k.rounded() ? "\(Int(k)) kHz" : String(format: "%.1f kHz", k)
    }

    /// "Built-in · 48 kHz", "Bluetooth · 24 kHz, call quality", "Virtual, not picked automatically".
    static func subtitle(_ d: MediaDevice) -> String {
        let kind: String = switch d.transport {
        case .builtIn: "Built-in"
        case .interface: d.isCameraMic ? "Webcam" : "Wired"
        case .bluetooth: "Bluetooth"
        case .continuity: "iPhone"
        case .display: "Display"
        case .virtual: "Virtual"
        case .unknown: "Microphone"
        }
        if MicPolicy.isVirtual(d.micCandidate) { return "\(kind == "Microphone" ? "Virtual" : kind), not picked automatically" }
        var parts = [kind]
        if let r = rate(d.sampleRate) { parts.append(r) }
        var text = parts.joined(separator: " · ")
        if d.isCallQuality { text += ", call quality" }
        return text
    }
}

/// The microphone picker: "Automatic (best mic)" first, then every input with its connection icon and
/// sample rate. A native menu (titles with subtitles) anchored to a compact label.
struct MicrophoneMenu: View {
    let devices: [MediaDevice]
    @Binding var selection: String
    @ViewState private var anchor = MenuAnchor()

    var body: some View {
        let resolved = devices.resolveMicrophone(selection)
        let automatic = selection == MicPolicy.automaticID
        Button {
            anchor.popUp(makeMenu())
        } label: {
            HStack(spacing: 5) {
                if let resolved {
                    Image(systemName: MicStyle.symbol(resolved))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                Text(resolved?.name ?? "None")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150)
                // Same indicator as the native borderless menus beside it.
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MenuAnchorView(anchor: anchor))
        .fixedSize()
        .help(automatic ? "Automatic: the best connected mic, kept for the whole take" : "Microphone")
        .accessibilityLabel("Microphone")
        .accessibilityValue(automatic ? "Automatic, \(resolved?.name ?? "none")" : resolved?.name ?? "None")
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let target = MenuTarget { id in selection = id }
        anchor.target = target
        func item(_ title: String, subtitle: String?, symbol: String?, id: String) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: #selector(MenuTarget.pick(_:)), keyEquivalent: "")
            i.target = target
            i.representedObject = id
            if let subtitle { i.subtitle = subtitle }
            if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            i.state = selection == id ? .on : .off
            return i
        }
        let best = devices.bestMicrophone
        menu.addItem(item(best.map { "Automatic (\($0.name))" } ?? "Automatic", subtitle: "Best connected mic, kept for the whole take",
                          symbol: best.map(MicStyle.symbol), id: MicPolicy.automaticID))
        menu.addItem(.separator())
        for d in devices {
            menu.addItem(item(d.name, subtitle: MicStyle.subtitle(d), symbol: MicStyle.symbol(d), id: d.id))
        }
        return menu
    }
}

@MainActor final class MenuTarget: NSObject {
    let onPick: (String) -> Void
    init(onPick: @escaping (String) -> Void) { self.onPick = onPick }
    @objc func pick(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { onPick(id) }
    }
}

/// Remembers the NSView under a SwiftUI control so a native menu can pop up from it.
@MainActor final class MenuAnchor {
    weak var view: NSView?
    var target: MenuTarget?

    func popUp(_ menu: NSMenu) {
        guard let view else { return }
        let selected = menu.items.first { $0.state == .on }
        menu.popUp(positioning: selected, at: NSPoint(x: -8, y: view.isFlipped ? view.bounds.maxY - 2 : 2), in: view)
    }
}

struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        anchor.view = v
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
}
