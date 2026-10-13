import ReelbirdCore
import SwiftUI

/// ⌘/: every editor shortcut, grouped by area, generated from the command registry.
struct ShortcutSheetView: View {
    @Bindable var model: EditorModel
    let app: AppModel?

    var body: some View {
        let sections = EditorCommands.sheet(EditorCommands.all(model: model, app: app))
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Keyboard Shortcuts").font(.system(size: 17, weight: .semibold))
                    HStack(spacing: 4) {
                        Text("Press").foregroundStyle(.secondary)
                        KeycapRow(keycaps: EditorKeys.commandMenu.keycaps, small: true)
                        Text("to search every command and setting.").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                }
                Spacer()
                Button { model.showShortcuts = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 26))
                    .help("Close (Esc)")
                    .accessibilityLabel("Close")
            }
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                ForEach(Array(Self.columns(sections, count: 3).enumerated()), id: \.offset) { _, column in
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        ForEach(column) { section in group(section) }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 860)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 28, y: 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard shortcuts")
    }

    private func group(_ section: EditorCommands.SheetSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: section.area.title).padding(.bottom, 6)
            ForEach(section.rows, id: \.id) { row in
                HStack(spacing: Theme.Space.s) {
                    Text(row.title)
                        .font(.system(size: 12.5))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Theme.Space.s)
                    KeycapRow(keycaps: row.keycaps)
                }
                .frame(minHeight: 26)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Splits sections into columns, each next section going to the shortest column (headers count as a row).
    static func columns(_ sections: [EditorCommands.SheetSection], count: Int) -> [[EditorCommands.SheetSection]] {
        var cols = [[EditorCommands.SheetSection]](repeating: [], count: max(1, count))
        var heights = [Int](repeating: 0, count: cols.count)
        for s in sections {
            let i = heights.indices.min { heights[$0] < heights[$1] || (heights[$0] == heights[$1] && $0 < $1) } ?? 0
            cols[i].append(s)
            heights[i] += s.rows.count + 2
        }
        return cols
    }
}
