import AppKit
import ReelbirdCore
import SwiftUI

/// Inspector → Overlays: add a blur, arrow, box, text or highlight; edit the selected one; Find Sensitive Info.
struct OverlaysSection: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            tools
            if let a = model.selectedAnnotation {
                Divider().padding(.vertical, 2)
                SelectedOverlay(model: model, annotation: a)
            }
            if model.linkNeedsUpdateForBlurs {
                StatusLine(tone: .warning, text: "Your link still plays the take uploaded while recording. Update the link to apply the blurs.")
            }
            Divider().padding(.vertical, 2)
            SensitiveInfoPanel(model: model)
            if model.selectedAnnotation == nil, !model.edit.annotations.isEmpty {
                Divider().padding(.vertical, 2)
                OverlayList(model: model)
            }
        }
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: 4) {
                ForEach(Annotation.Kind.toolOrder, id: \.self) { kind in
                    OverlayToolButton(kind: kind, active: model.overlays.tool == kind) {
                        if model.overlays.tool == kind { model.cancelOverlayTool() } else { model.beginOverlayTool(kind) }
                    }
                }
            }
            Text(model.overlays.tool.map { "Drag on the preview to place the \($0.title.lowercased()). Esc cancels." }
                 ?? "Overlays stay on the content they mark through zoom, crop and aspect.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension Annotation.Kind {
    static let toolOrder: [Annotation.Kind] = [.blur, .arrow, .box, .text, .highlight]
    var symbol: String {
        switch self {
        case .blur: "eye.slash"
        case .arrow: "arrow.up.left"
        case .box: "rectangle"
        case .text: "textformat"
        case .highlight: "circle.lefthalf.filled"
        }
    }
}

/// A tool in the Overlays panel: icon over a short name.
struct OverlayToolButton: View {
    let kind: Annotation.Kind
    let active: Bool
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: kind.symbol).font(.system(size: 13, weight: .medium)).frame(height: 16)
                Text(kind.title).font(.system(size: 10.5, weight: active ? .semibold : .medium))
            }
            .foregroundStyle(active ? Theme.ink : Color.primary.opacity(0.75))
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(active ? Theme.raised : Color.primary.opacity(hovering ? 0.07 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(active ? Theme.accent : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(kind == .blur ? "Blur (B): hide an area" : "Add a \(kind.title.lowercased())")
        .accessibilityLabel("Add \(kind.title)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Settings of the selected overlay.
struct SelectedOverlay: View {
    @Bindable var model: EditorModel
    let annotation: Annotation
    @FocusState private var textFocused: Bool

    private var a: Annotation { annotation }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                SectionLabel(text: a.detected.flatMap { SensitiveKind(rawValue: $0) }.map { "Blur · \($0.title)" } ?? a.kind.title)
                Spacer()
            }
            switch a.kind {
            case .blur:
                PillTabs(selection: Binding(get: { a.blurStyle }, set: { v in
                    model.overlays.blurStyle = v
                    model.updateAnnotation(a.id, "Blur Style", coalesce: "style") { $0.style = v }
                }), items: [
                    .init(value: .blur, title: "Blur", symbol: nil),
                    .init(value: .pixelate, title: "Pixelate", symbol: nil),
                ], compact: true)
                FieldRow(label: "Strength") {
                    ValueSlider(value: Binding(get: { a.blurStrength }, set: { v in
                        model.overlays.blurStrength = v
                        model.updateAnnotation(a.id, "Blur Strength", coalesce: "strength") { $0.strength = v }
                    }), range: 0...1) { "\(Int(($0 * 100).rounded()))" }
                }
                Text("Every strength leaves text unreadable. Higher is coarser.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            case .text:
                TextField("Text", text: Binding(get: { a.text ?? "" }, set: { v in
                    model.updateAnnotation(a.id, "Edit Text", coalesce: "text") { $0.text = v }
                }))
                .textFieldStyle(.roundedBorder)
                .focused($textFocused)
                .accessibilityLabel("Text")
                FieldRow(label: "Size") {
                    ValueSlider(value: Binding(get: { a.textSize }, set: { v in
                        model.updateAnnotation(a.id, "Text Size", coalesce: "size") { $0.fontSize = v }
                    }), range: 0.012...0.08) { "\(Int(($0 * Double(model.screenPixelSize.height) / max(1, model.manifest.capture.scale)).rounded())) pt" }
                }
                colors
            case .arrow, .box:
                colors
            case .highlight:
                Text("Dims everything around the area.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            FieldRow(label: "Time") {
                HStack(spacing: 6) {
                    Text("\(TimeFormat.clock(a.range.start, tenths: true)) – \(TimeFormat.clock(a.range.end, tenths: true))")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button { model.updateAnnotation(a.id, "Trim Overlay", coalesce: "start") { $0.range.start = min(model.playhead, $0.range.end - 0.2) } } label: {
                        Image(systemName: "arrow.right.to.line")
                    }
                    .buttonStyle(IconButtonStyle(size: 22)).help("Start at the playhead")
                    .accessibilityLabel("Start at the playhead")
                    Button { model.updateAnnotation(a.id, "Trim Overlay", coalesce: "end") { $0.range.end = max(model.playhead, $0.range.start + 0.2) } } label: {
                        Image(systemName: "arrow.left.to.line")
                    }
                    .buttonStyle(IconButtonStyle(size: 22)).help("End at the playhead")
                    .accessibilityLabel("End at the playhead")
                }
            }
            HStack(spacing: Theme.Space.s) {
                Button("Delete", role: .destructive) { model.deleteAnnotation(a.id) }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Done") { model.selection = nil }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .onAppear { focusIfNew() }
        .onChange(of: a.id) { _, _ in focusIfNew() }
    }

    private func focusIfNew() {
        guard model.overlays.focusTextID == a.id else { return }
        model.overlays.focusTextID = nil
        textFocused = true
    }

    private var colors: some View {
        FieldRow(label: "Colour") {
            HStack(spacing: 6) {
                ForEach(Annotation.palette, id: \.name) { p in
                    Button {
                        model.overlays.color = p.color
                        model.updateAnnotation(a.id, "Overlay Colour", coalesce: "color") { $0.color = p.color }
                    } label: {
                        Circle()
                            .fill(Color(.sRGB, red: p.color.r, green: p.color.g, blue: p.color.b))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.28), lineWidth: 0.5))
                            .frame(width: 18, height: 18)
                            .padding(2.5)
                            .overlay(Circle().strokeBorder(a.color == p.color ? Theme.ink : .clear, lineWidth: 1.5))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(p.name)
                    .accessibilityLabel(p.name)
                    .accessibilityAddTraits(a.color == p.color ? .isSelected : [])
                }
            }
        }
    }
}

/// Find Sensitive Info: scan, then keep or dismiss each finding.
struct SensitiveInfoPanel: View {
    @Bindable var model: EditorModel
    @Bindable private var state: OverlayState

    init(model: EditorModel) {
        self.model = model
        _state = Bindable(model.overlays)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(text: "Find sensitive info")
            Text("Reads the text on screen on this Mac and suggests blurs for emails, API keys, card and phone numbers. Nothing is uploaded.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Also find these words (names, code names)", text: $state.customWords)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .accessibilityLabel("Custom words, separated by commas")
            if let p = state.scanProgress {
                HStack(spacing: Theme.Space.s) {
                    ProgressView(value: p).progressViewStyle(.linear).tint(Theme.accent)
                    Text("\(Int((p * 100).rounded()))%").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                    Button("Stop") { state.cancelScan() }.buttonStyle(SecondaryButtonStyle(small: true))
                }
                .padding(.top, 2)
            } else {
                Button { model.findSensitiveInfo() } label: {
                    Label(state.scanned ? "Scan Again" : "Find Sensitive Info", systemImage: "text.viewfinder")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            if let err = state.scanError { StatusLine(tone: .error, text: err) }
            if state.scanned, state.scanProgress == nil {
                if state.suggestions.isEmpty {
                    StatusLine(tone: .success, text: state.lastScan.map { $0.found == 0 ? "Nothing found." : "All findings handled." } ?? "Nothing found.")
                } else {
                    VStack(spacing: 6) {
                        ForEach(state.suggestions) { s in SuggestionRow(model: model, suggestion: s) }
                    }
                    HStack(spacing: Theme.Space.s) {
                        Button("Keep All") { model.keepAllSuggestions() }
                            .buttonStyle(PrimaryButtonStyle())
                            .help("Blur every finding")
                        Button("Dismiss All") { model.dismissAllSuggestions() }
                            .buttonStyle(SecondaryButtonStyle())
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 2)
                }
                Text("The scan reads the screen only, not narration, captions or overlays such as keystrokes.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One finding: what it looked like, what it is, when, Keep or Dismiss.
struct SuggestionRow: View {
    let model: EditorModel
    let suggestion: SensitiveSuggestion

    var body: some View {
        let d = suggestion.detection
        HStack(spacing: 8) {
            Group {
                if let img = suggestion.thumbnail {
                    Image(decorative: img, scale: 2).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color.primary.opacity(0.06)
                        Image(systemName: d.kind.symbol).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 54, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(d.kind.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text("\(TimeFormat.clock(d.range.start))–\(TimeFormat.clock(d.range.end))")
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
                }
                Text(d.preview)
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button { model.dismissSuggestion(d.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 24)).help("Dismiss").accessibilityLabel("Dismiss \(d.kind.title)")
            Button("Keep") { model.keepSuggestion(d.id) }
                .buttonStyle(SecondaryButtonStyle(small: true)).help("Blur it").accessibilityLabel("Keep \(d.kind.title) blur")
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.035)))
        .contentShape(Rectangle())
        .onTapGesture { model.seek(source: min(d.range.end - 0.01, max(d.range.start + 0.01, d.firstSeen))) }
        .accessibilityElement(children: .contain)
    }
}

extension SensitiveKind {
    var symbol: String {
        switch self {
        case .email: "at"
        case .apiKey: "key"
        case .card: "creditcard"
        case .phone: "phone"
        case .custom: "text.quote"
        }
    }
}

/// Every overlay, in time order. Click to select and go there.
struct OverlayList: View {
    let model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "\(model.edit.annotations.count) overlay\(model.edit.annotations.count == 1 ? "" : "s")")
            ForEach(model.edit.annotations.sorted { ($0.range.start, $0.id) < ($1.range.start, $1.id) }) { a in
                Button { model.selectAnnotation(a.id) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: a.kind.symbol).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
                        Text(a.title).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(TimeFormat.clock(a.range.start)) – \(TimeFormat.clock(a.range.end))")
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(a.title), \(TimeFormat.clock(a.range.start)) to \(TimeFormat.clock(a.range.end))")
            }
        }
    }
}
