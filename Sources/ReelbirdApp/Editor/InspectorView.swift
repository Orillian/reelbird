import AppKit
import ReelbirdAI
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
                        .frame(height: 28)
                        .foregroundStyle(model.section == s ? Theme.ink : Color.secondary)
                        .background {
                            if model.section == s {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Theme.raised)
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(s.title) (⌘\(i + 1))")
                .accessibilityLabel(s.title)
                .accessibilityAddTraits(model.section == s ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fieldFill))
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 10)
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
                        model.updateZoom(r.id, coalesce: "focus") { $0.focus = follow ? nil : (model.edit.crop?.center ?? .center) }
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
                    FieldRow(label: "Shape") { shapePicker }
                    FieldRow(label: "Size") {
                        ValueSlider(value: model.binding(\.camera.size, "Camera Size"), range: 0.1...0.45) { "\(Int($0 * 100))%" }
                    }
                    FieldRow(label: "Position") {
                        HStack(spacing: Theme.Space.m) {
                            cornerPicker
                            Text("Drag the bubble on the preview to place it anywhere.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !model.edit.camera.moves.isEmpty { moves }
                    Toggle("Mirror", isOn: model.binding(\.camera.mirror, "Mirror Camera")).toggleStyle(.brand).font(.system(size: 12))
                    Toggle("Blur background", isOn: model.binding(\.camera.blurBackground, "Blur Background")).toggleStyle(.brand).font(.system(size: 12))
                }
            }
        }
    }

    /// Circle, squircle square and portrait tile, each with its own outline as the icon.
    private var shapePicker: some View {
        let current = model.edit.camera.shape
        return HStack(spacing: 2) {
            ForEach(CameraLayout.Shape.allCases, id: \.self) { shape in
                let selected = shape == current
                Button { withAnimation(Theme.snappy) { model.change("Camera Shape") { $0.camera.shape = shape } } } label: {
                    HStack(spacing: 5) {
                        CameraShapeGlyph(shape: shape, filled: selected)
                            .frame(width: 12, height: 13)
                        Text(shape.title).font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                    }
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Theme.raised)
                                .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(shape.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fieldFill))
    }

    /// The recorded moves, each deletable, and "Keep in one place" to drop them all.
    private var moves: some View {
        let list = model.edit.camera.moves
        let timeline = model.timeline
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(list.count == 1 ? "1 move" : "\(list.count) moves")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button("Keep in One Place") { model.keepCameraInOnePlace() }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    .help("Drop the moves: the camera stays where it starts")
            }
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.offset) { i, move in
                    let out = timeline.outputTime(forSource: move.t)
                    HStack(spacing: 8) {
                        Button { model.seek(source: move.t) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)
                                Text(out.map { "Moved at \(TimeFormat.clock($0))" } ?? "Moved in a cut part")
                                    .font(.system(size: 12).monospacedDigit())
                                    .foregroundStyle(out == nil ? .secondary : .primary)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Go to this move")
                        Button { model.deleteCameraMove(at: i) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                            .buttonStyle(IconButtonStyle(size: 20))
                            .help("Delete this move")
                            .accessibilityLabel("Delete move at \(TimeFormat.clock(out ?? move.t))")
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    if i < list.count - 1 { Divider().padding(.leading, 30) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fieldFill))
        }
    }

    /// Four corner presets (each pins the bubble there for the whole video). A free place shows as a dot.
    private var cornerPicker: some View {
        let corners: [[CameraLayout.Corner]] = [[.topLeft, .topRight], [.bottomLeft, .bottomRight]]
        let pinned = model.cameraCorner
        let start = model.edit.camera.position
        return ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.fieldFill)
            if pinned == nil {
                GeometryReader { g in
                    let inset: CGFloat = 7 + 6
                    Circle()
                        .fill(Theme.ink)
                        .frame(width: 8, height: 8)
                        .position(x: inset + (g.size.width - 2 * inset) * start.x, y: inset + (g.size.height - 2 * inset) * start.y)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            VStack(spacing: 0) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(corners[row], id: \.self) { c in
                            let selected = pinned == c
                            Button { model.setCameraCorner(c) } label: {
                                Circle()
                                    .fill(selected ? Theme.ink : Color.primary.opacity(0.18))
                                    .frame(width: 12, height: 12)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(c))
                                    .padding(7)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(cornerName(c))
                            .accessibilityLabel(cornerName(c))
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                }
            }
        }
        .frame(width: 84, height: 54)
    }

    private func cornerName(_ c: CameraLayout.Corner) -> String {
        switch c { case .topLeft: "Top left"; case .topRight: "Top right"; case .bottomLeft: "Bottom left"; case .bottomRight: "Bottom right" }
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
            CropControls(model: model)
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
        let r = CropSpace(model.edit.crop).pixelSize(of: model.screenPixelSize).aspect
        switch a {
        case .source: return r >= 1 ? CGSize(width: 34, height: 34 / r) : CGSize(width: 28 * r, height: 28)
        case .wide: return CGSize(width: 34, height: 19)
        case .vertical: return CGSize(width: 16, height: 28)
        case .square: return CGSize(width: 24, height: 24)
        case .classic: return CGSize(width: 30, height: 22.5)
        }
    }
}

// MARK: Crop

/// Canvas → Crop: hide the browser toolbar in one click, draw a crop on the preview, or reset.
struct CropControls: View {
    @Bindable var model: EditorModel

    var body: some View {
        let crop = model.edit.crop
        let screen = model.screenPixelSize
        let visible = CropSpace(crop).pixelSize(of: screen)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "Crop")
                if crop != nil {
                    Text(verbatim: "\(visible.width) × \(visible.height)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .help("Showing \(visible.width) × \(visible.height) of \(screen.width) × \(screen.height) pixels")
                }
            }
            // Browser windows always lead with the toolbar button; other recordings show it when a toolbar was found
            // (a full-screen browser on a display recording).
            if model.browserName != nil || model.toolbarCrop != nil {
                browserRow(model.browserName)
            }
            HStack(spacing: Theme.Space.s) {
                Button { model.beginCrop() } label: { Label("Crop…", systemImage: "crop") }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.isCropping)
                    .help("Drag the edges on the preview to choose what stays in view")
                Button("Reset") { model.resetCrop() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(crop == nil && !model.isCropping)
                    .help("Show the whole recording again")
            }
        }
    }

    /// A browser window: the one-click toolbar button leads, with what it will do or has done.
    @ViewBuilder private func browserRow(_ browser: String?) -> some View {
        if model.isToolbarHidden {
            StatusLine(tone: .success, text: browser.map { "\($0)'s toolbar is hidden." } ?? "The browser toolbar is hidden.")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button { model.hideBrowserToolbar() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "rectangle.topthird.inset.filled")
                            .foregroundStyle(model.toolbarCrop == nil ? Color.secondary : Theme.accentText)
                        Text("Hide Browser Toolbar")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.toolbarCrop == nil)
                Group {
                    if model.isDetectingToolbar {
                        Text("Finding the toolbar…")
                    } else if model.toolbarCrop == nil {
                        Text("No toolbar found in this recording. Use Crop… to choose the area.")
                    } else if let browser {
                        Text("Shows just the page: no tabs, address bar or bookmarks from \(browser).")
                    } else {
                        Text("Hides the browser's tabs, address bar and bookmarks at the top.")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: Audio

struct AudioSection: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if model.hasMicrophone { voice }
            if model.hasSystemAudio {
                if model.hasMicrophone { Divider().padding(.vertical, 2) }
                systemAudio
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

    private var voice: some View {
        let muted = model.edit.audio.microphoneMuted
        let enhance = model.edit.audio.enhance
        return VStack(alignment: .leading, spacing: 10) {
            header(title: "Voice", symbol: "mic.fill", muted: \.audio.microphoneMuted)
            Group {
                Toggle(isOn: model.binding(\.audio.enhance, "Enhance Voice")) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Enhance voice").font(.system(size: 12))
                        Text(enhanceStatus).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.brand)
                .help("Removes background noise and evens out your voice. The original recording is kept.")
                if enhance {
                    PillTabs(selection: model.binding(\.audio.enhanceStrength, "Enhance Strength"),
                             items: EnhanceStrength.allCases.map { .init(value: $0, title: $0.title, symbol: nil) }, compact: true)
                        .help("How much background noise to remove. Stronger settings can sound processed.")
                        .accessibilityLabel("Strength")
                    mixSlider
                    hearOriginalButton.padding(.bottom, 4)
                }
                if let error = model.voiceStemError { StatusLine(tone: .warning, text: error) }
                Toggle(isOn: model.binding(\.audio.autoLevel, "Auto Level")) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Auto level").font(.system(size: 12))
                        Text(autoLevelStatus).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.brand)
                .help("Brings your voice to a steady, podcast-like loudness (−16 LUFS) without clipping.")
                FieldRow(label: "Boost", labelWidth: 52) {
                    ValueSlider(value: model.binding(\.audio.microphoneGainDB, "Voice Boost"), range: -12...12, detent: 0, format: Self.db)
                }
            }
            .disabled(muted)
            .opacity(muted ? 0.5 : 1)
        }
    }

    /// Original ↔ Enhanced blend.
    private var mixSlider: some View {
        VStack(spacing: 2) {
            Slider(value: model.binding(\.audio.enhanceMix, "Enhance Mix"), in: 0...1)
                .controlSize(.small)
                .tint(Theme.accent)
                .accessibilityLabel("Original to enhanced")
                .accessibilityValue("\(Int((model.edit.audio.enhanceMix * 100).rounded())) percent enhanced")
            HStack {
                Text("Original")
                Spacer()
                Text("Enhanced")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
    }

    /// Plays the raw microphone for as long as it's pressed.
    private var hearOriginalButton: some View {
        let on = model.isHearingOriginal
        return Label(on ? "Playing original" : "Hold to hear original", systemImage: on ? "ear.fill" : "ear")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(on ? Theme.accent : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Theme.accent.opacity(0.14) : Theme.fieldFill))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in model.setHearOriginal(true) }
                .onEnded { _ in model.setHearOriginal(false) })
            .help("Press and hold to compare with the voice as recorded.")
            .accessibilityElement()
            .accessibilityLabel("Hear original")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.setHearOriginal(!model.isHearingOriginal) }
    }

    private var systemAudio: some View {
        let muted = model.edit.audio.systemMuted
        return VStack(alignment: .leading, spacing: 10) {
            header(title: "System audio", symbol: "speaker.wave.2.fill", muted: \.audio.systemMuted)
            Group {
                FieldRow(label: "Volume", labelWidth: 52) {
                    ValueSlider(value: model.binding(\.audio.systemGainDB, "System Audio Volume"), range: -24...12, detent: 0, format: Self.db)
                }
                if model.hasMicrophone {
                    Toggle(isOn: model.binding(\.audio.duckSystemAudio, "Lower Under Voice")) {
                        Text("Lower under voice").font(.system(size: 12))
                    }
                    .toggleStyle(.brand)
                    .help("Turns system audio down by about 12 dB while you speak.")
                }
            }
            .disabled(muted)
            .opacity(muted ? 0.5 : 1)
        }
    }

    private var enhanceStatus: String {
        guard model.edit.audio.enhance else { return "Plays as recorded" }
        if let p = model.voiceStemProgress { return "Enhancing voice… \(Int((p * 100).rounded()))%" }
        switch model.edit.audio.enhanceStrength {
        case .light: return "Removes a little background noise"
        case .medium: return "Removes background noise"
        case .strong: return "Removes most background noise"
        case .max: return "Removes all the noise it can"
        }
    }

    private var autoLevelStatus: String {
        guard model.edit.audio.autoLevel else { return "Plays as recorded" }
        if model.isMeasuringVoice { return "Measuring your voice…" }
        guard let analysis = model.audioAnalysis else { return "Not measured yet" }
        guard analysis.microphone?.integratedLUFS != nil else { return "No speech found" }
        let gain = model.autoLevelGainDB ?? 0
        if abs(gain) < 0.5 { return "Already at a good level" }
        return String(format: "%+.0f dB applied", gain)
    }

    private static func db(_ v: Double) -> String {
        abs(v) < 0.05 ? "0 dB" : String(format: "%+.0f dB", v)
    }

    private func header(title: String, symbol: String, muted: WritableKeyPath<EditDocument, Bool>) -> some View {
        let isMuted = model.edit[keyPath: muted]
        return HStack {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium))
            Spacer()
            Button { model.change(isMuted ? "Unmute" : "Mute") { $0[keyPath: muted].toggle() } } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2")
            }
            .buttonStyle(IconButtonStyle(size: 24, active: isMuted))
            .help(isMuted ? "Unmute" : "Mute")
            .accessibilityLabel(isMuted ? "Unmute \(title)" : "Mute \(title)")
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
                if let reason = model.captionsUnavailableReason ?? (model.transcriberAvailable ? nil : "On-device captions aren't available on this Mac.") {
                    StatusLine(tone: .info, text: reason)
                } else {
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
            }
            if model.storySupported { story }
            if model.edit.captions.file != nil, let t = model.transcript {
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
                        .accessibilityLabel("\(TimeFormat.clock(s.range.start)), \(s.text)")
                        .accessibilityHint("Moves the playhead here")
                    }
                }
            }
        }
        .onAppear { model.checkCaptionsAvailability() }
    }

    /// Title and chapters from Apple Intelligence (macOS 26+ only; hidden before that).
    @ViewBuilder private var story: some View {
        Divider().padding(.vertical, 2)
        SectionLabel(text: "Title & chapters")
        if let reason = model.storyUnavailableReason {
            StatusLine(tone: .info, text: reason)
        } else if model.transcript == nil {
            Text("Generate captions first. Reelbird suggests a title and chapters from what you said, on this Mac.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            switch model.storyState {
            case .working:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading your transcript…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            case .failed(let msg):
                StatusLine(tone: .error, text: msg)
                suggestButton
            case .idle:
                suggestButton
            }
            if !model.edit.chapters.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.edit.chapters.enumerated()), id: \.offset) { _, c in
                        Button { model.seek(source: c.time) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(TimeFormat.clock(c.time)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
                                    .frame(width: 30, alignment: .leading)
                                Text(c.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Chapter at \(TimeFormat.clock(c.time)), \(c.title)")
                    }
                }
                Button("Clear Chapters") { model.clearChapters() }
                    .buttonStyle(.link).font(.system(size: 12)).foregroundStyle(Theme.accentText)
            }
        }
    }

    private var suggestButton: some View {
        Button { model.suggestStory() } label: {
            Label(model.edit.chapters.isEmpty ? "Suggest Title & Chapters" : "Suggest Again", systemImage: "list.bullet.rectangle")
        }
        .buttonStyle(SecondaryButtonStyle())
        .help("Uses Apple Intelligence on this Mac. Replaces the title and chapters; Undo brings them back.")
    }

    private var generateButton: some View {
        Button { model.generateCaptions() } label: { Label("Generate Captions", systemImage: "captions.bubble") }
            .buttonStyle(SecondaryButtonStyle())
    }
}
