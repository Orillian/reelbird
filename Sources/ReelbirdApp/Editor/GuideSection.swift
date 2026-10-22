import ReelbirdCore
import ReelbirdGuide
import SwiftUI

/// The Guide panel (⌘9): the steps of the take, what the link shares with them, and guide exports.
struct GuideSection: View {
    @Bindable var model: EditorModel

    var body: some View {
        let g = model.guidePanel
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Each click, typing and shortcut becomes a step with a picture of the screen. Your link shows them as a Guide and a Click-through next to the video.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Guide and Click-through on the link", isOn: model.binding(\.guide.share, "Share Guide"))
                Toggle("Viewers can copy text from the video", isOn: model.binding(\.guide.copyText, "Copy Text"))
                Toggle("Show what was typed", isOn: model.binding(\.guide.showTypedText, "Show Typed Text"))
            }
            .toggleStyle(.brand).font(.system(size: 12))
            if model.edit.guide.showTypedText {
                Text("Emails, keys, card and phone numbers stay hidden, and so does anything typed while a blur is on screen.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            Divider().padding(.vertical, 2)
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: g.loaded ? "\(g.steps.count) step\(g.steps.count == 1 ? "" : "s")" : "Steps")
                if g.load == .working { ProgressView().controlSize(.mini) }
            }
            switch g.load {
            case .failed(let msg): StatusLine(tone: .error, text: msg)
            case .working where !g.loaded:
                Text("Reading your clicks…").font(.system(size: 12)).foregroundStyle(.secondary)
            default:
                if g.loaded && g.steps.isEmpty {
                    Text("No steps yet. Steps come from clicks, and from typing and shortcuts when keystroke recording is on.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(g.steps.enumerated()), id: \.element.id) { i, step in
                    if let section = step.section {
                        Text(section).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
                    }
                    StepRow(model: model, number: i + 1, step: step, thumbnail: g.thumbnails[step.id])
                }
            }
            if model.hiddenStepCount > 0 {
                HStack(spacing: 6) {
                    Text("\(model.hiddenStepCount) hidden").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    Button("Show All") { model.showAllSteps() }.buttonStyle(.link).font(.system(size: 11.5)).foregroundStyle(Theme.accentText)
                }
            }
            HStack(spacing: 8) {
                Menu {
                    Button("Web Page (Guide and Click-through)…") { model.exportGuide(.html) }
                    Button("Markdown…") { model.exportGuide(.markdown) }
                    Button("Claude Skill…") { model.exportGuide(.skill) }
                } label: {
                    Label(g.isExporting ? "Exporting…" : "Export Guide", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.button).buttonStyle(SecondaryButtonStyle()).fixedSize()
                .disabled(g.steps.isEmpty || g.isExporting)
                Button { model.loadGuide(refresh: true) } label: { Label("Read Again", systemImage: "arrow.clockwise") }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(g.load == .working)
                    .help(model.services.guide.modelAvailable
                          ? "Reads the screen again and rewords the steps with Apple Intelligence on this Mac."
                          : "Reads the screen again on this Mac.")
            }
        }
        .task(id: model.guideKey) { model.loadGuide() }
    }
}

/// One step: its picture with the number, the instruction (editable), what was said, and its moment.
private struct StepRow: View {
    @Bindable var model: EditorModel
    let number: Int
    let step: GuideStep
    let thumbnail: NSImage?
    /// The text being typed: saved on Return or when the field loses focus, so clearing it to retype doesn't
    /// bring the automatic text straight back.
    @ViewState private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { model.seek(source: step.t) } label: {
                ZStack(alignment: .topLeading) {
                    Group {
                        if let thumbnail {
                            Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(Theme.fieldFill)
                        }
                    }
                    .frame(width: 84, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.black.opacity(0.08)))
                    Text("\(number)")
                        .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Circle().fill(Theme.accent))
                        .padding(4)
                }
            }
            .buttonStyle(.plain)
            .help("Go to this step in the video")
            .accessibilityLabel("Step \(number), go to \(TimeFormat.clock(step.t))")
            VStack(alignment: .leading, spacing: 3) {
                TextField("Step \(number)", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1...4)
                    .focused($editing)
                    .onSubmit(commit)
                    .onChange(of: editing) { _, now in if !now { commit() } }
                    .onChange(of: step.text) { _, text in if !editing { draft = text } }
                    .onAppear { draft = step.text }
                    .accessibilityLabel("Step \(number) instruction")
                if let note = step.narration {
                    Text(note).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(2)
                }
                HStack(spacing: 8) {
                    Text(TimeFormat.clock(step.t)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
                    Spacer()
                    Button { model.hideStep(step.id) } label: { Image(systemName: "eye.slash").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Leave this step out of the guide")
                        .accessibilityLabel("Hide step \(number)")
                }
            }
        }
    }

    private func commit() {
        guard draft != step.text else { return }
        model.setStepText(step.id, draft)
    }
}
