import ReelbirdCore
import SwiftUI

/// The tool bar's Clean Up button (W). Shows what it's doing while it runs.
struct CleanUpButton: View {
    @Bindable var model: EditorModel

    var body: some View {
        switch model.cleanUpState {
        case .idle:
            ToolButton(symbol: "wand.and.stars", title: "Clean Up", key: EditorKeys.cleanUp.display) { model.cleanUp() }
                .disabled(!model.canCleanUp)
                .help(model.canCleanUp ? "Clean Up (W): shorten long pauses, cut ums and dead time, speed up typing and waiting"
                                       : "Clean Up needs a recording with sound")
        case .working(let what):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(what).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.045)))
        }
    }
}

/// Under the tool bar after Clean Up: what it did, Review and Undo.
struct CleanUpBar: View {
    @Bindable var model: EditorModel
    @ViewState private var reviewing = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "wand.and.stars").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accentText)
            Text(model.edit.cleanUp.applied.isEmpty && model.edit.cleanUp.suggestions.isEmpty
                 ? "Clean Up was undone" : "Cleaned up: \(model.cleanUpSummary)")
                .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if !model.edit.cleanUp.applied.isEmpty || !model.edit.cleanUp.suggestions.isEmpty {
                Button("Review") { reviewing = true }
                    .buttonStyle(SecondaryButtonStyle())
                    .popover(isPresented: $reviewing, arrowEdge: .bottom) { CleanUpReview(model: model) }
                Button("Undo") { model.undoCleanUp() }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Put back everything Clean Up changed")
            }
            Button { model.showCleanUpBar = false } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Hide")
                .accessibilityLabel("Hide Clean Up results")
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, 7)
        .background(Theme.accent.opacity(0.08))
    }
}

/// Every change and suggestion, in time order: play it, put it back, or apply a suggestion.
struct CleanUpReview: View {
    @Bindable var model: EditorModel

    private struct Row: Identifiable {
        let item: CleanUpItem
        let suggested: Bool
        var id: String { item.id }
    }

    private var rows: [Row] {
        (model.edit.cleanUp.applied.map { Row(item: $0, suggested: false) }
            + model.edit.cleanUp.suggestions.map { Row(item: $0, suggested: true) })
            .sorted { $0.item.editRange.start < $1.item.editRange.start }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Clean Up").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(model.cleanUpSummary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(12)
            Divider()
            if rows.isEmpty {
                Text("Nothing left to review.").font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            line(row)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 400)
    }

    private func sentence(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    private func line(_ row: Row) -> some View {
        let item = row.item
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { model.previewCleanUp(item) } label: {
                Image(systemName: "play.fill").font(.system(size: 9))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Play from a second before")
            Text(TimeFormat.clock(item.editRange.start)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(sentence(item.kind.label)).font(.system(size: 12, weight: .medium))
                    if row.suggested {
                        Text("Suggestion").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accentText)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().strokeBorder(Theme.accentText.opacity(0.5), lineWidth: 0.5))
                    }
                }
                Text(sentence(item.reason)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if row.suggested {
                Button("Apply") { model.acceptCleanUp(item) }.buttonStyle(.link).font(.system(size: 11.5)).foregroundStyle(Theme.accentText)
                Button("Dismiss") { model.dismissCleanUp(item) }.buttonStyle(.link).font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                Button("Put Back") { model.restoreCleanUp(item) }.buttonStyle(.link).font(.system(size: 11.5)).foregroundStyle(Theme.accentText)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}
