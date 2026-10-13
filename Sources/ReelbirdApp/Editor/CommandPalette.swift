import AppKit
import ReelbirdCore
import SwiftUI

/// Commands run from the command menu, most recent first. Kept in user defaults; automated runs keep them in
/// memory so tests and snapshots never touch your settings.
@MainActor enum CommandHistory {
    private static let key = "editorRecentCommands"
    private static var memory: [String] = []
    private static var defaults: UserDefaults? { AutomatedRun.isSilent ? nil : .standard }
    static let limit = 6

    static var recent: [String] { defaults?.stringArray(forKey: key) ?? memory }

    static func record(_ id: String) {
        let r = Array(([id] + recent.filter { $0 != id }).prefix(limit))
        if let defaults { defaults.set(r, forKey: key) } else { memory = r }
    }

    static func setForSnapshot(_ ids: [String]) { memory = ids }
}

/// What the command menu lists: with no search, recent commands then every command by area; with a search,
/// the best matches first (recent ones lifted a little). Only commands that can run now are listed.
@MainActor enum CommandMenu {
    struct Section: Identifiable {
        var id: String { title ?? "results" }
        let title: String?
        let commands: [EditorCommand]
    }

    static func sections(model: EditorModel, app: AppModel?) -> [Section] {
        let all = EditorCommands.all(model: model, app: app).filter { $0.inPalette && $0.isEnabled }
        let recent = CommandHistory.recent
        let query = model.paletteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            let recents = recent.compactMap { id in all.first { $0.id == id } }
            let ids = Set(recents.map(\.id))
            var out: [Section] = recents.isEmpty ? [] : [Section(title: "Recent", commands: recents)]
            for area in EditorCommand.Area.allCases {
                let cs = all.filter { $0.area == area && !ids.contains($0.id) }
                if !cs.isEmpty { out.append(Section(title: area.title, commands: cs)) }
            }
            return out
        }
        let ranked = FuzzyMatch.rank(all, query: query, fields: { [$0.title] + $0.keywords + [$0.area.title] }, boost: { c in
            guard let i = recent.firstIndex(of: c.id) else { return 0 }
            return 0.6 * Double(recent.count - i) / Double(recent.count)
        })
        return ranked.isEmpty ? [] : [Section(title: nil, commands: ranked)]
    }

    static func flat(_ sections: [Section]) -> [EditorCommand] { sections.flatMap(\.commands) }

    /// Moves the highlight (arrow keys), staying on the list.
    static func move(_ delta: Int, model: EditorModel, app: AppModel?) {
        let n = flat(sections(model: model, app: app)).count
        guard n > 0 else { return }
        model.paletteHighlight = min(n - 1, max(0, model.paletteHighlight + delta))
    }

    /// Runs the highlighted command (Return).
    static func runHighlighted(model: EditorModel, app: AppModel?) {
        let list = flat(sections(model: model, app: app))
        guard list.indices.contains(model.paletteHighlight) else { return }
        run(list[model.paletteHighlight], model: model)
    }

    /// Closes the menu, remembers the command and runs it once the menu is gone (so sheets and popovers it opens
    /// present normally).
    static func run(_ c: EditorCommand, model: EditorModel) {
        close(model)
        CommandHistory.record(c.id)
        let action = c.action
        DispatchQueue.main.async { action() }
    }

    static func open(_ model: EditorModel) {
        model.paletteQuery = ""
        model.paletteHighlight = 0
        model.showShortcuts = false
        model.showCommandPalette = true
    }

    static func close(_ model: EditorModel) {
        model.showCommandPalette = false
    }
}

/// ⌘K: a floating search over every editor command and setting. Arrow keys move, Return runs, Esc closes
/// (the editor's key handler routes those keys here while it is open).
struct CommandPaletteView: View {
    @Bindable var model: EditorModel
    let app: AppModel?
    @FocusState private var searchFocused: Bool
    @Environment(\.isSnapshot) private var snapshot

    var body: some View {
        let sections = CommandMenu.sections(model: model, app: app)
        let flat = CommandMenu.flat(sections)
        let searching = !model.paletteQuery.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search commands and settings", text: $model.paletteQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($searchFocused)
                    .accessibilityLabel("Search commands")
                Keycap(text: "Esc")
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            Divider()
            if flat.isEmpty {
                VStack(spacing: 6) {
                    Text("No matching commands").font(.system(size: 13, weight: .medium))
                    Text("Try another word, such as zoom, export or captions.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 120)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(sections) { section in
                                if let title = section.title {
                                    Text(title)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 12)
                                        .padding(.top, 10)
                                        .padding(.bottom, 4)
                                }
                                ForEach(section.commands) { c in
                                    let index = flat.firstIndex { $0.id == c.id } ?? 0
                                    row(c, highlighted: index == model.paletteHighlight, showArea: searching)
                                        .id(c.id)
                                        .onHover { if $0 { model.paletteHighlight = index } }
                                        .onTapGesture { CommandMenu.run(c, model: model) }
                                }
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: min(392, listHeight(sections)))
                    .scrollIndicators(.automatic)
                    .onChange(of: model.paletteHighlight) { _, i in
                        if flat.indices.contains(i) { proxy.scrollTo(flat[i].id) }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 600)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 28, y: 14)
        .onAppear { if !snapshot { searchFocused = true } }
        .onChange(of: model.paletteQuery) { _, _ in model.paletteHighlight = 0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command menu")
    }

    private func listHeight(_ sections: [CommandMenu.Section]) -> CGFloat {
        let rows = CommandMenu.flat(sections).count
        let headers = sections.filter { $0.title != nil }.count
        return CGFloat(rows) * 34 + CGFloat(headers) * 31 + 12
    }

    private func row(_ c: EditorCommand, highlighted: Bool, showArea: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: c.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(highlighted ? Color.primary : Color.secondary)
                .frame(width: 20)
            Text(title(c))
                .font(.system(size: 13))
                .lineLimit(1)
            if c.isCurrent {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .accessibilityLabel("Current")
            }
            Spacer(minLength: 8)
            if let on = c.isOn {
                Text(on ? "On" : "Off")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(on ? Color.primary.opacity(0.75) : Color.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Capsule().fill(Color.primary.opacity(on ? 0.1 : 0.05)))
            }
            if showArea {
                Text(c.area.title).font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
            if let s = c.shortcut {
                KeycapRow(keycaps: s.keycaps)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(highlighted ? Color.primary.opacity(0.075) : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : .isButton)
    }

    /// The title with the letters the search matched in semibold.
    private func title(_ c: EditorCommand) -> AttributedString {
        var a = AttributedString(c.title)
        guard let m = FuzzyMatch.match(model.paletteQuery, in: c.title), !m.positions.isEmpty else { return a }
        let indices = Array(a.characters.indices)
        for p in m.positions where indices.indices.contains(p) {
            let i = indices[p]
            a[i..<a.characters.index(after: i)].font = .system(size: 13, weight: .semibold)
        }
        return a
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint(["↑", "↓"], "Move")
            hint(["↩"], "Run")
            Spacer()
            hint(EditorKeys.shortcuts.keycaps, "All shortcuts")
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private func hint(_ keys: [String], _ text: String) -> some View {
        HStack(spacing: 5) {
            KeycapRow(keycaps: keys, small: true)
            Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
}

/// Keycaps side by side; a dash between caps ("0 – 9") is drawn as text.
struct KeycapRow: View {
    let keycaps: [String]
    var small = false
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keycaps.enumerated()), id: \.offset) { _, k in
                if k == "–" {
                    Text(k).font(.system(size: 11)).foregroundStyle(.tertiary)
                } else {
                    Keycap(text: k).scaleEffect(small ? 0.92 : 1)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keycaps.joined())
    }
}

/// The dimmed layer over the editor that holds the command menu or the shortcut sheet; a click outside closes it.
struct EditorOverlayHost: View {
    @Bindable var model: EditorModel
    let app: AppModel?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            if model.showCommandPalette || model.showShortcuts {
                Color.black.opacity(0.16)
                    .contentShape(Rectangle())
                    .onTapGesture { model.showCommandPalette = false; model.showShortcuts = false }
                    .transition(.opacity)
            }
            if model.showCommandPalette {
                CommandPaletteView(model: model, app: app)
                    .padding(.top, 96)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            } else if model.showShortcuts {
                ShortcutSheetView(model: model, app: app)
                    .frame(maxHeight: .infinity)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : Theme.snappy, value: model.showCommandPalette)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : Theme.snappy, value: model.showShortcuts)
    }
}
