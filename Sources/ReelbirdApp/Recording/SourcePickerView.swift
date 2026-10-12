import AppKit
import ReelbirdCore
import SwiftUI

/// The compact "what do you want to record?" panel.
struct SourcePickerView: View {
    let model: SourcePickerModel
    let controller: RecordingController?
    @Bindable var prefs: Preferences
    var onSetUpSharing: () -> Void = {}
    var onClose: () -> Void = {}
    @Environment(\.isSnapshot) private var snapshot

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Theme.Space.l)
                .padding(.top, Theme.Space.m)
                .padding(.bottom, Theme.Space.m)
            sourceArea
                .frame(height: 214)
                .padding(.horizontal, Theme.Space.l)
            Divider().padding(.top, Theme.Space.m)
            inputs
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.s)
            Divider()
            footer
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.m)
        }
        .frame(width: 452)
        .floatingSurface(cornerRadius: 16, snapshot: snapshot)
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
        if let error = model.loadError {
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

    private var displays: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            ForEach(model.displays) { d in
                SourceTile(source: d, selected: model.selectedDisplayID == d.id, large: true)
                    .onTapGesture { model.selectedDisplayID = d.id }
                    .onTapGesture(count: 2) { model.selectedDisplayID = d.id; controller?.startFromPicker() }
            }
            if model.displays.count == 1 { Spacer(minLength: 0) }
        }
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
                            .onTapGesture(count: 2) { model.selectedWindowID = w.id; controller?.startFromPicker() }
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
                            .strokeBorder(Theme.accent, lineWidth: 1.5)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.accentSoft))
                            .aspectRatio(aspect, contentMode: .fit)
                            .frame(maxWidth: 170, maxHeight: 92)
                        Text("\(Int(a.rect.width * 2)) × \(Int(a.rect.height * 2))")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        Text("Last area · \(Int(a.rect.width)) × \(Int(a.rect.height)) pt")
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
                    LevelMeter(level: model.micLevel, segments: 10, height: 5).frame(width: 52)
                    DeviceMenu(devices: model.microphones, selection: $prefs.microphoneID)
                }
            }
            .onChange(of: prefs.microphoneEnabled) { _, on in on ? model.startMeters() : model.stopMeters() }
            .onChange(of: prefs.microphoneID) { _, _ in model.startMeters() }

            InputRow(symbol: prefs.cameraEnabled ? "video.fill" : "video.slash", title: "Camera", isOn: $prefs.cameraEnabled) {
                if prefs.cameraEnabled {
                    DeviceMenu(devices: model.cameras, selection: Binding(get: { prefs.cameraID ?? "" }, set: { prefs.cameraID = $0 }))
                }
            }
            .onChange(of: prefs.cameraEnabled) { _, _ in controller?.syncCameraBubble() }
            .onChange(of: prefs.cameraID) { _, _ in controller?.syncCameraBubble() }

            InputRow(symbol: prefs.systemAudio ? "speaker.wave.2.fill" : "speaker.slash", title: "System audio", isOn: $prefs.systemAudio) {
                EmptyView()
            }

            InputRow(symbol: "link", title: "Share while recording",
                     isOn: Binding(get: { prefs.shareWhileRecording && model.shareAvailable }, set: { prefs.shareWhileRecording = $0 }),
                     enabled: model.shareAvailable) {
                if !model.shareAvailable {
                    Button("Set up…", action: onSetUpSharing)
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accentText)
                } else if prefs.shareWhileRecording {
                    Text("Link copied when you stop").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Footer

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
            .fixedSize()

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
        if let name = appName,
           let icon = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name })?.icon {
            Image(nsImage: icon).resizable()
        } else {
            Image(systemName: "app.dashed").resizable().foregroundStyle(.tertiary)
        }
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
            Toggle(title, isOn: $isOn).toggleStyle(.brand).labelsHidden().disabled(!enabled)
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
            Text(devices.first(where: { $0.id == selection })?.name ?? devices.first?.name ?? "None")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(maxWidth: 170, alignment: .trailing)
    }
}
