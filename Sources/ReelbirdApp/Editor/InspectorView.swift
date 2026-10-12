import AppKit
import ReelbirdCore
import SwiftUI

extension EditorModel {
    /// A binding into the edit document that records undo (coalesced per property).
    func binding<T: Equatable>(_ kp: WritableKeyPath<EditDocument, T>, _ name: String) -> Binding<T> {
        Binding(get: { self.edit[keyPath: kp] },
                set: { v in self.change(name, coalesce: "\(kp)") { $0[keyPath: kp] = v } })
    }
}

struct InspectorView: View {
    @Bindable var model: EditorModel
    let app: AppModel?

    var body: some View {
        VStack(spacing: 0) {
            rail
            Divider()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    Text(model.section.title)
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.bottom, -4)
                    switch model.section {
                    case .background: BackgroundSection(model: model)
                    case .cursor: CursorSection(model: model)
                    case .zoom: ZoomSection(model: model)
                    case .camera: CameraSection(model: model)
                    case .canvas: CanvasSection(model: model)
                    case .audio: AudioSection(model: model)
                    case .captions: CaptionsSection(model: model)
                    }
                }
                .padding(Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .background(Theme.panel)
    }

    private var rail: some View {
        HStack(spacing: 2) {
            ForEach(Array(InspectorSection.allCases.enumerated()), id: \.element) { i, s in
                Button {
                    withAnimation(Theme.snappy) { model.section = s }
                } label: {
                    Image(systemName: s.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .foregroundStyle(model.section == s ? Theme.ink : Color.secondary)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(model.section == s ? Theme.fieldFill : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(s.title) (⌘\(i + 1))")
                .accessibilityLabel(s.title)
                .accessibilityAddTraits(model.section == s ? .isSelected : [])
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

// MARK: Background

struct BackgroundPreset: Identifiable {
    let id: String
    let colors: [String]
    static let gradients: [BackgroundPreset] = [
        .init(id: "Apricot", colors: ["#F6C68B", "#E2795C"]),
        .init(id: "Ember", colors: ["#FF9A62", "#C9412A"]),
        .init(id: "Peach", colors: ["#FFE1C7", "#F4A582"]),
        .init(id: "Dune", colors: ["#EAD7BC", "#B98B62"]),
        .init(id: "Rosewood", colors: ["#D98C7A", "#6B2E2A"]),
        .init(id: "Sage", colors: ["#CFD8C0", "#7D8F6E"]),
        .init(id: "Harbor", colors: ["#AFC4CF", "#4F6878"]),
        .init(id: "Night", colors: ["#3A302B", "#120E0C"]),
    ]
    static let solids: [BackgroundPreset] = [
        .init(id: "Paper", colors: ["#FFF4E8"]), .init(id: "Linen", colors: ["#EFE6DA"]),
        .init(id: "Clay", colors: ["#C9775A"]), .init(id: "Coral", colors: ["#FF5A36"]),
        .init(id: "Moss", colors: ["#5E6B4E"]), .init(id: "Slate", colors: ["#4A5560"]),
        .init(id: "Ink", colors: ["#1A1512"]), .init(id: "White", colors: ["#FFFFFF"]),
    ]
    var rgba: [RGBA] { colors.compactMap { RGBA(hex: $0) } }
    var style: AnyShapeStyle {
        let cs = colors.compactMap { RGBA(hex: $0) }.map { Color(.sRGB, red: $0.r, green: $0.g, blue: $0.b) }
        return cs.count > 1 ? AnyShapeStyle(LinearGradient(colors: cs, startPoint: .topLeading, endPoint: .bottomTrailing))
            : AnyShapeStyle(cs.first ?? .gray)
    }
}

struct BackgroundSection: View {
    @Bindable var model: EditorModel

    var body: some View {
        let bg = model.edit.background
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            PillTabs(selection: model.binding(\.background.kind, "Background"), items: [
                .init(value: .gradient, title: "Gradient", symbol: nil),
                .init(value: .solid, title: "Solid", symbol: nil),
                .init(value: .image, title: "Image", symbol: nil),
                .init(value: .none, title: "None", symbol: nil),
            ], compact: true)

            switch bg.kind {
            case .gradient: swatches(BackgroundPreset.gradients)
            case .solid: swatches(BackgroundPreset.solids)
            case .image: imagePicker
            case .none:
                Text("The recording fills the frame with square corners.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }

            if bg.kind != .none {
                Divider().padding(.vertical, 2)
                FieldRow(label: "Padding") {
                    ValueSlider(value: model.binding(\.background.padding, "Padding"), range: 0...0.2) { "\(Int($0 * 500))" }
                }
                FieldRow(label: "Corners") {
                    ValueSlider(value: model.binding(\.background.cornerRadius, "Corner Radius"), range: 0...0.06) { "\(Int($0 * 1000 / 0.6))" }
                }
                FieldRow(label: "Shadow") {
                    ValueSlider(value: model.binding(\.background.shadow, "Shadow"), range: 0...1) { "\(Int($0 * 100))" }
                }
                Toggle("Motion blur", isOn: model.binding(\.background.motionBlur, "Motion Blur"))
                    .toggleStyle(.brand)
                    .font(.system(size: 12))
            }
        }
    }

    private func swatches(_ presets: [BackgroundPreset]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(56), spacing: 8), count: 4), alignment: .leading, spacing: 8) {
            ForEach(presets) { p in
                Button {
                    model.change("Background") { $0.background.colors = p.rgba }
                } label: {
                    Swatch(fill: p.style, selected: model.edit.background.colors == p.rgba, size: 50)
                }
                .buttonStyle(.plain)
                .help(p.id)
                .accessibilityLabel(p.id)
            }
        }
    }

    private var imagePicker: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let path = model.edit.background.imagePath {
                HStack(spacing: 8) {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                    Text((path as NSString).lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                }
            }
            Button(model.edit.background.imagePath == nil ? "Choose Image…" : "Replace…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.image]
                if panel.runModal() == .OK, let url = panel.url {
                    model.change("Background Image") { $0.background.imagePath = url.path }
                }
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }
}

// MARK: Cursor

struct CursorSection: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Toggle("Show cursor", isOn: model.binding(\.cursor.visible, "Show Cursor")).toggleStyle(.brand).font(.system(size: 12))
            if model.edit.cursor.visible {
                FieldRow(label: "Size") {
                    ValueSlider(value: model.binding(\.cursor.size, "Cursor Size"), range: 0.5...3) { String(format: "%.1f×", $0) }
                }
                FieldRow(label: "Smoothing") {
                    ValueSlider(value: model.binding(\.cursor.smoothing, "Smoothing"), range: 0...1) { "\(Int($0 * 100))" }
                }
                FieldRow(label: "Clicks") {
                    Picker("Clicks", selection: model.binding(\.cursor.clickEffect, "Click Effect")) {
                        Text("Ripple").tag(CursorSettings.ClickEffect.ripple)
                        Text("Ring").tag(CursorSettings.ClickEffect.ring)
                        Text("Press").tag(CursorSettings.ClickEffect.press)
                        Text("None").tag(CursorSettings.ClickEffect.none)
                    }
                    .labelsHidden().controlSize(.small).fixedSize()
                }
                FieldRow(label: "Hide when idle") {
                    Picker("Hide when idle", selection: model.binding(\.cursor.hideWhenIdleAfter, "Hide Cursor")) {
                        Text("Never").tag(0.0)
                        Text("After 1 s").tag(1.0)
                        Text("After 2 s").tag(2.0)
                        Text("After 3 s").tag(3.0)
                        Text("After 5 s").tag(5.0)
                    }
                    .labelsHidden().controlSize(.small).fixedSize()
                }
            }
            Divider().padding(.vertical, 2)
            Toggle("Show keystrokes", isOn: model.binding(\.cursor.showKeystrokes, "Keystrokes")).toggleStyle(.brand).font(.system(size: 12))
            if model.edit.cursor.showKeystrokes && !model.events.contains(where: { $0.type == .key }) {
                StatusLine(tone: .info, text: "No keys were recorded. Turn on keystrokes in Settings → Recording before your next take.")
            }
        }
    }
}

// MARK: Zoom

struct ZoomSection: View {
    @Bindable var model: EditorModel

    var body: some View {
        let zoom = model.edit.zoom
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            PillTabs(selection: Binding(get: { zoom.mode }, set: { model.setZoomMode($0) }), items: [
                .init(value: .auto, title: "Auto", symbol: nil),
                .init(value: .manual, title: "Manual", symbol: nil),
                .init(value: .off, title: "Off", symbol: nil),
            ], compact: true)

            Text(modeHelp(zoom.mode)).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if zoom.mode == .auto {
                VStack(alignment: .leading, spacing: 4) {
                    Slider(value: Binding(get: { zoom.intensity }, set: { model.setZoomIntensity($0) }), in: 0...1)
                        .controlSize(.small).tint(Theme.accent)
                        .accessibilityLabel("Zoom intensity")
                    HStack {
                        Text("Subtle"); Spacer(); Text("Punchy")
                    }
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }

            if zoom.mode != .off {
                HStack(spacing: Theme.Space.s) {
                    Button { model.addZoomAtPlayhead() } label: { Label("Add at Playhead", systemImage: "plus") }
                        .buttonStyle(SecondaryButtonStyle())
                    if zoom.mode == .auto {
                        Button("Reset") { model.resetAutoZooms() }
                            .buttonStyle(SecondaryButtonStyle())
                            .help("Throw away edits and regenerate zooms from your clicks")
                    }
                }
                Text(summary(zoom)).font(.system(size: 11)).foregroundStyle(.tertiary)
            }

            if let r = model.selectedZoom {
                Divider().padding(.vertical, 2)
                SectionLabel(text: "Selected zoom")
                FieldRow(label: "Depth") {
                    ValueSlider(value: Binding(get: { r.scale }, set: { v in model.updateZoom(r.id, coalesce: "scale") { $0.scale = v } }),
                                range: 1.1...3.5) { String(format: "%.1f×", $0) }
                }
                FieldRow(label: "Focus") {
                    Picker("Focus", selection: Binding(get: { r.focus == nil }, set: { follow in
                        model.updateZoom(r.id, coalesce: "focus") { $0.focus = follow ? nil : .center }
                    })) {
                        Text("Follow cursor").tag(true)
                        Text("Fixed point").tag(false)
                    }
                    .labelsHidden().controlSize(.small).fixedSize()
                }
                FieldRow(label: "Time") {
                    Text("\(TimeFormat.clock(r.range.start, tenths: true)) – \(TimeFormat.clock(r.range.end, tenths: true))")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                }
                Button("Delete Zoom", role: .destructive) { model.deleteSelection() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private func modeHelp(_ m: ZoomSettings.Mode) -> String {
        switch m {
        case .auto: "Zooms in where you click and type, then eases back out."
        case .manual: "Only the zooms you add. Press Z to add one at the playhead."
        case .off: "No zooming. The whole recording stays in view."
        }
    }

    private func summary(_ z: ZoomSettings) -> String {
        let auto = z.regions.filter { $0.source == .auto }.count
        let user = z.regions.count - auto
        switch (auto, user) {
        case (0, 0): return "No zooms yet"
        case (_, 0): return "\(auto) automatic zoom\(auto == 1 ? "" : "s")"
        case (0, _): return "\(user) zoom\(user == 1 ? "" : "s") you added"
        default: return "\(auto) automatic, \(user) adjusted by you"
        }
    }
}

// MARK: Camera

struct CameraSection: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if !model.hasCamera {
                StatusLine(tone: .info, text: "This recording has no camera. Turn on the camera in the recording panel to add your face next time.")
            } else {
                Toggle("Show camera", isOn: model.binding(\.camera.visible, "Show Camera")).toggleStyle(.brand).font(.system(size: 12))
                if model.edit.camera.visible {
                    FieldRow(label: "Shape") {
                        PillTabs(selection: model.binding(\.camera.shape, "Camera Shape"), items: [
                            .init(value: .circle, title: "Circle", symbol: "circle"),
                            .init(value: .roundedRect, title: "Rounded", symbol: "app"),
                        ], compact: true)
                    }
                    FieldRow(label: "Size") {
                        ValueSlider(value: model.binding(\.camera.size, "Camera Size"), range: 0.1...0.45) { "\(Int($0 * 100))%" }
                    }
                    FieldRow(label: "Corner") { cornerPicker }
                    Toggle("Mirror", isOn: model.binding(\.camera.mirror, "Mirror Camera")).toggleStyle(.brand).font(.system(size: 12))
                    Toggle("Blur background", isOn: model.binding(\.camera.blurBackground, "Blur Background")).toggleStyle(.brand).font(.system(size: 12))
                }
            }
        }
    }

    private var cornerPicker: some View {
        let corners: [[CameraLayout.Corner]] = [[.topLeft, .topRight], [.bottomLeft, .bottomRight]]
        return ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.fieldFill)
            VStack(spacing: 0) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(corners[row], id: \.self) { c in
                            let selected = model.edit.camera.corner == c
                            Button { model.change("Camera Corner") { $0.camera.corner = c } } label: {
                                Circle()
                                    .fill(selected ? Theme.ink : Color.primary.opacity(0.18))
                                    .frame(width: 12, height: 12)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(c))
                                    .padding(7)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(c)")
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                }
            }
        }
        .frame(width: 84, height: 54)
    }

    private func alignment(_ c: CameraLayout.Corner) -> Alignment {
        switch c { case .topLeft: .topLeading; case .topRight: .topTrailing; case .bottomLeft: .bottomLeading; case .bottomRight: .bottomTrailing }
    }
}

// MARK: Canvas

struct CanvasSection: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(CanvasSettings.Aspect.allCases, id: \.self) { a in
                    let selected = model.edit.canvas.aspect == a
                    Button { model.change("Aspect Ratio") { $0.canvas.aspect = a } } label: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(selected ? Theme.ink : Color.primary.opacity(0.35), lineWidth: 1.5)
                                .frame(width: shape(a).width, height: shape(a).height)
                                .frame(height: 30)
                            Text(name(a)).font(.system(size: 11, weight: selected ? .semibold : .regular))
                            Text(use(a)).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.fieldFill : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(selected ? 0.12 : 0.06), lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name(a))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Divider().padding(.vertical, 2)
            FieldRow(label: "Size") {
                Picker("Size", selection: model.binding(\.canvas.outputHeight, "Output Size")) {
                    Text("Match recording").tag(Int?.none)
                    Text("4K (2160p)").tag(Int?.some(2160))
                    Text("1440p").tag(Int?.some(1440))
                    Text("1080p").tag(Int?.some(1080))
                    Text("720p").tag(Int?.some(720))
                }
                .labelsHidden().controlSize(.small).fixedSize()
            }
            FieldRow(label: "Frame rate") {
                Picker("Frame rate", selection: model.binding(\.canvas.frameRate, "Frame Rate")) {
                    Text("Match recording (\(model.manifest.capture.frameRate))").tag(Int?.none)
                    Text("60 fps").tag(Int?.some(60))
                    Text("30 fps").tag(Int?.some(30))
                }
                .labelsHidden().controlSize(.small).fixedSize()
            }
        }
    }

    private func name(_ a: CanvasSettings.Aspect) -> String { a == .source ? "Original" : a.rawValue }
    private func use(_ a: CanvasSettings.Aspect) -> String {
        switch a { case .source: "As recorded"; case .wide: "YouTube"; case .vertical: "Reels, Shorts"; case .square: "Feeds"; case .classic: "Slides" }
    }
    private func shape(_ a: CanvasSettings.Aspect) -> CGSize {
        let r = model.manifest.capture.pixelSize.aspect
        switch a {
        case .source: return r >= 1 ? CGSize(width: 34, height: 34 / r) : CGSize(width: 28 * r, height: 28)
        case .wide: return CGSize(width: 34, height: 19)
        case .vertical: return CGSize(width: 16, height: 28)
        case .square: return CGSize(width: 24, height: 24)
        case .classic: return CGSize(width: 30, height: 22.5)
        }
    }
}

// MARK: Audio

struct AudioSection: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if model.hasMicrophone {
                track(title: "Microphone", symbol: "mic.fill", gain: \.audio.microphoneGainDB, muted: \.audio.microphoneMuted)
                Toggle("Remove background noise", isOn: model.binding(\.audio.denoise, "Noise Removal"))
                    .toggleStyle(.brand).font(.system(size: 12))
            }
            if model.hasSystemAudio {
                if model.hasMicrophone { Divider().padding(.vertical, 2) }
                track(title: "System audio", symbol: "speaker.wave.2.fill", gain: \.audio.systemGainDB, muted: \.audio.systemMuted)
            }
            if !model.hasMicrophone && !model.hasSystemAudio {
                StatusLine(tone: .info, text: "This recording has no audio.")
            }
            if model.hasMicrophone {
                Divider().padding(.vertical, 2)
                SectionLabel(text: "Tidy up")
                Button { model.removeSilences() } label: { Label("Cut Long Silences", systemImage: "waveform.path.badge.minus") }
                    .buttonStyle(SecondaryButtonStyle())
                Text("Adds a cut wherever you were quiet for more than a second. Undo brings them back.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func track(title: String, symbol: String, gain: WritableKeyPath<EditDocument, Double>, muted: WritableKeyPath<EditDocument, Bool>) -> some View {
        let isMuted = model.edit[keyPath: muted]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium))
                Spacer()
                Button { model.change(isMuted ? "Unmute" : "Mute") { $0[keyPath: muted].toggle() } } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2")
                }
                .buttonStyle(IconButtonStyle(size: 24, active: isMuted))
                .help(isMuted ? "Unmute" : "Mute")
                .accessibilityLabel(isMuted ? "Unmute \(title)" : "Mute \(title)")
            }
            ValueSlider(value: model.binding(gain, "\(title) Volume"), range: -24...12) { v in
                v == 0 ? "0 dB" : String(format: "%+.0f dB", v)
            }
            .disabled(isMuted)
            .opacity(isMuted ? 0.5 : 1)
        }
    }
}

// MARK: Captions

struct CaptionsSection: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if model.edit.captions.file == nil {
                Text("Turn your narration into captions on this Mac. Nothing is uploaded.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                switch model.captionState {
                case .working:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Listening to your recording…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                case .failed(let msg):
                    StatusLine(tone: .error, text: msg)
                    generateButton
                case .idle:
                    generateButton
                }
                if !model.transcriberAvailable {
                    StatusLine(tone: .info, text: "On-device captions need macOS 26 or later.")
                }
            } else {
                HStack {
                    StatusLine(tone: .success, text: "Captions ready")
                    Spacer()
                    Button("Remove") { model.removeCaptions() }.buttonStyle(.link).font(.system(size: 12))
                        .foregroundStyle(Theme.accentText)
                }
                Toggle("Burn into exported video", isOn: model.binding(\.captions.burnIn, "Burn In Captions"))
                    .toggleStyle(.brand).font(.system(size: 12))
                Text("Shared links always offer captions as a track viewers can turn on.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                if let t = model.transcript {
                    Divider().padding(.vertical, 2)
                    SectionLabel(text: "Transcript")
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(t.segments.enumerated()), id: \.offset) { _, s in
                            Button { model.seek(source: s.range.start) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(TimeFormat.clock(s.range.start))
                                        .font(.system(size: 10.5).monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 30, alignment: .leading)
                                    Text(s.text).font(.system(size: 12))
                                        .foregroundStyle(s.range.contains(model.playhead) ? Theme.ink : .secondary)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var generateButton: some View {
        Button { model.generateCaptions() } label: { Label("Generate Captions", systemImage: "captions.bubble") }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(!model.transcriberAvailable)
    }
}
