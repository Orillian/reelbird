import AppKit
import ReelbirdCore
import SwiftUI

struct LibraryView: View {
    @Bindable var store: LibraryStore
    let app: AppModel?
    @Environment(\.isSnapshot) private var snapshot
    @FocusState private var focused: Bool

    /// The content's coordinate space: item frames and the rubber band are measured in it, so both
    /// scroll together.
    fileprivate nonisolated static let space = "library-content"

    // Rubber band
    @ViewState private var frames = ItemFrames()
    @ViewState private var dragBase: Set<URL>?
    @ViewState private var dragStart: CGPoint = .zero
    @ViewState private var dragPoint: CGPoint = .zero
    // Scrolling, for auto-scroll while dragging near an edge
    @ViewState private var scroll = ScrollPosition(edge: .top)
    @ViewState private var metrics = ScrollMetrics()
    @ViewState private var autoscroll: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
                .background(WindowDragArea())
            Divider()
            if store.items.isEmpty {
                empty
            } else if store.filtered.isEmpty {
                Text("No recordings match “\(store.query)”")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
                    .focusable()
                    .focused($focused)
                    .focusEffectDisabled()
                    .onKeyPress(.return) { open(store.selectedItem); return .handled }
                    .onKeyPress(.escape) { store.clearSelection(); return .handled }
                    .onKeyPress(keys: [.delete]) { press in
                        guard press.modifiers.contains(.command), !store.selectedItems.isEmpty else { return .ignored }
                        trash(store.selectedItems); return .handled
                    }
                    .onKeyPress(characters: CharacterSet(charactersIn: "aA")) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        store.selectAll(); return .handled
                    }
                    .onKeyPress(keys: [.leftArrow, .upArrow]) { press in
                        store.moveSelection(-1, extend: press.modifiers.contains(.shift)); return .handled
                    }
                    .onKeyPress(keys: [.rightArrow, .downArrow]) { press in
                        store.moveSelection(1, extend: press.modifiers.contains(.shift)); return .handled
                    }
            }
        }
        .background(Theme.panel)
        .ignoresSafeArea()
        .tint(Theme.accent)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.m) {
            if snapshot { FakeTrafficLights() } else { Color.clear.frame(width: 66) }
            Text("Library").font(.system(size: 15, weight: .semibold))
            if !store.items.isEmpty {
                Text("\(store.items.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.tertiary)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
                TextField("Search", text: $store.query).textFieldStyle(.plain).font(.system(size: 12.5))
            }
            .padding(.horizontal, 9)
            .frame(width: 200, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.fieldFill))

            HStack(spacing: 0) {
                Button { store.gridLayout = true } label: { Image(systemName: "square.grid.2x2") }
                    .buttonStyle(IconButtonStyle(size: 28, active: store.gridLayout)).accessibilityLabel("Grid")
                Button { store.gridLayout = false } label: { Image(systemName: "list.bullet") }
                    .buttonStyle(IconButtonStyle(size: 28, active: !store.gridLayout)).accessibilityLabel("List")
            }
            Button { app?.newRecording() } label: {
                HStack(spacing: 6) {
                    Circle().fill(Theme.onAccent).frame(width: 8, height: 8)
                    Text("New Recording")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .help("New Recording (\(app?.prefs.recordHotKey.display ?? "⌥⇧R"))")
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(height: 54)
    }

    private var empty: some View {
        VStack(spacing: Theme.Space.m) {
            Mascot(pose: .sleeping, size: 132)
            Text("No recordings yet").font(.system(size: 17, weight: .semibold))
            HStack(spacing: 4) {
                Text("Press")
                Keycap(text: app?.prefs.recordHotKey.display ?? "⌥⇧R")
                Text("anywhere to start one.")
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            Button("New Recording") { app?.newRecording() }
                .buttonStyle(PrimaryButtonStyle(large: true))
                .padding(.top, Theme.Space.s)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }

    // MARK: Content

    private var content: some View {
        let selectedCount = store.selectedItems.count
        return ScrollView {
            Group { if store.gridLayout { grid } else { list } }
                .frame(maxWidth: .infinity, minHeight: metrics.viewport.height, alignment: .top)
                .background { marqueeSurface }
                .overlay(alignment: .topLeading) { marquee }
                .coordinateSpace(.named(Self.space))
        }
        .scrollPosition($scroll)
        .onScrollGeometryChange(for: ScrollMetrics.self) { g in
            ScrollMetrics(offset: g.contentOffset.y, viewport: g.containerSize, contentHeight: g.contentSize.height,
                          insets: g.contentInsets)
        } action: { _, new in metrics = new }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selectedCount >= 2 {
                SelectionBar(count: selectedCount, snapshot: snapshot,
                             reveal: { store.reveal(store.selectedItems) },
                             trash: { trash(store.selectedItems) },
                             deselect: { store.clearSelection() })
                    .padding(.bottom, Theme.Space.l)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Theme.snappy, value: selectedCount >= 2)
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 224, maximum: 320), spacing: 22, alignment: .top)], spacing: 26) {
            ForEach(store.filtered) { item in
                LibraryTile(item: item, poster: store.posters[item.id], selected: store.isSelected(item.id),
                            forceHover: store.snapshotHover == item.id, actions: actions(item)) { menu(item) }
                    .onTapGesture { click(item) }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { open(item) })
                    .modifier(ReportsFrame(id: item.id, frames: frames, dragging: dragBase != nil))
                    .contextMenu { menu(item) }
            }
        }
        .padding(Theme.Space.xl)
    }

    private var list: some View {
        let items = store.filtered
        return LazyVStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                let selected = store.isSelected(item.id)
                let above = i > 0 && store.isSelected(items[i - 1].id)
                let below = i + 1 < items.count && store.isSelected(items[i + 1].id)
                LibraryRow(item: item, poster: store.posters[item.id], selected: selected,
                           joinsAbove: selected && above, joinsBelow: selected && below, actions: actions(item)) { menu(item) }
                    .onTapGesture { click(item) }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { open(item) })
                    // In the list, a drag that starts on a row draws the rubber band too (as in Finder's list view).
                    .gesture(marqueeDrag(minimumDistance: 4))
                    .modifier(ReportsFrame(id: item.id, frames: frames, dragging: dragBase != nil))
                    .contextMenu { menu(item) }
                // Contiguous selected rows read as one block, as in Finder.
                Divider().padding(.leading, 120).opacity(selected || below ? 0 : 1)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
    }

    // MARK: Rubber band

    /// Empty space behind the items: a press clears the selection (unless ⌘ or ⇧ is held), a drag draws the band.
    private var marqueeSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(marqueeDrag(minimumDistance: 0))
    }

    @ViewBuilder private var marquee: some View {
        if let r = store.marquee {
            Rectangle()
                .fill(Theme.accent.opacity(0.1))
                .overlay(Rectangle().strokeBorder(Theme.accent.opacity(0.85), lineWidth: 1))
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func marqueeDrag(minimumDistance: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: minimumDistance, coordinateSpace: .named(Self.space))
            .onChanged { v in dragChanged(start: v.startLocation, to: v.location) }
            .onEnded { _ in dragEnded() }
    }

    private func dragChanged(start: CGPoint, to point: CGPoint) {
        if dragBase == nil {
            focused = true
            let mods = NSEvent.modifierFlags
            let keep = mods.contains(.command) || mods.contains(.shift)
            if !keep { store.clearSelection() }
            dragBase = keep ? store.selection : []
            dragStart = start
        }
        dragPoint = point
        updateMarquee()
        updateAutoscroll()
    }

    private func dragEnded() {
        store.marquee = nil
        dragBase = nil
        autoscroll?.cancel()
        autoscroll = nil
    }

    private func updateMarquee() {
        guard let base = dragBase else { return }
        let a = dragStart, b = dragPoint
        guard hypot(b.x - a.x, b.y - a.y) >= 3 || store.marquee != nil else { return }
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        let bounds = CGRect(x: 0, y: 0, width: metrics.viewport.width, height: max(metrics.contentHeight, metrics.viewport.height))
        store.marquee = bounds.width > 0 ? rect.intersection(bounds) : rect
        let visible = Set(store.filtered.map(\.id))
        let hits = Set(frames.frames.compactMap { id, f in visible.contains(id) && f.intersects(rect) ? id : nil })
        store.setMarqueeSelection(hits, base: base)
    }

    /// While the pointer is near (or past) the top or bottom edge, scrolls and keeps the band growing.
    private func updateAutoscroll() {
        guard speed() != 0 else { autoscroll?.cancel(); autoscroll = nil; return }
        guard autoscroll == nil else { return }
        autoscroll = Task { @MainActor in
            while !Task.isCancelled, dragBase != nil {
                let v = speed()
                let lo = -metrics.insets.top
                let hi = max(lo, metrics.contentHeight - metrics.viewport.height + metrics.insets.bottom)
                let next = min(max(lo, metrics.offset + v), hi)
                let delta = next - metrics.offset
                if v == 0 || abs(delta) < 0.5 { break }
                scroll.scrollTo(y: next)
                metrics.offset = next
                dragPoint.y += delta
                updateMarquee()
                try? await Task.sleep(for: .milliseconds(16))
            }
            autoscroll = nil
        }
    }

    /// Points per frame: faster the further into (or past) the edge zone the pointer is.
    private func speed() -> CGFloat {
        let zone: CGFloat = 36
        let y = dragPoint.y - metrics.offset
        let h = metrics.viewport.height
        guard store.marquee != nil, h > zone * 2 else { return 0 }
        if y < zone { return -min(28, 2 + (zone - y) * 0.35) }
        if y > h - zone { return min(28, 2 + (y - (h - zone)) * 0.35) }
        return 0
    }

    // MARK: Actions

    private func click(_ item: LibraryItem) {
        focused = true
        store.click(item.id, modifiers: NSEvent.modifierFlags)
    }

    /// What a menu on `item` acts on: the whole selection when the item is part of a multiple selection
    /// (as in Finder), otherwise just the item.
    private func targets(_ item: LibraryItem) -> [LibraryItem] {
        store.isSelected(item.id) && store.selection.count > 1 ? store.selectedItems : [item]
    }

    private func actions(_ item: LibraryItem) -> ItemActions {
        ItemActions(open: { open(item) }, reveal: { store.reveal(targets(item)) }, trash: { trash(targets(item)) })
    }

    private func trash(_ items: [LibraryItem]) {
        guard !items.isEmpty else { return }
        if let app { app.moveToTrash(items.map(\.bundle)) } else { store.moveToTrash(items) }
    }

    private func open(_ item: LibraryItem?) {
        guard let item else { return }
        app?.open(bundle: item.bundle)
    }

    @ViewBuilder private func menu(_ item: LibraryItem) -> some View {
        let targets = targets(item)
        if targets.count > 1 {
            Button("Show \(targets.count) in Finder") { store.reveal(targets) }
            Divider()
            Button("Move \(targets.count) to Trash…", role: .destructive) { trash(targets) }
        } else {
            Button("Open") { open(item) }
            if item.shareURL != nil { Button("Copy Link") { store.copyLink(item) } }
            if store.statsURL(item) != nil { Button("View Stats") { store.openStats(item) } }
            Button("Show in Finder") { store.reveal([item]) }
            Button("Duplicate") { store.duplicate(item) }
            Divider()
            Button("Move to Trash…", role: .destructive) { trash([item]) }
        }
    }
}

/// Item frames in the content's coordinate space, for rubber-band hit testing. A plain class (not
/// observed): frames change on every layout and nothing needs to redraw when they do.
@MainActor final class ItemFrames {
    var frames: [URL: CGRect] = [:]
}

private struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var viewport: CGSize = .zero
    var contentHeight: CGFloat = 0
    var insets = EdgeInsets()
}

/// Reports an item's frame for rubber-band hit testing.
private struct ReportsFrame: ViewModifier {
    let id: URL
    let frames: ItemFrames
    let dragging: Bool

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(LibraryView.space)) } action: { frames.frames[id] = $0 }
            // Lazy stacks drop offscreen items; keep their last frame while a band is being drawn
            // (nothing moves mid-drag), so auto-scrolling past them doesn't deselect them.
            .onDisappear { if !dragging { frames.frames[id] = nil } }
    }
}

/// What VoiceOver can do with a tile or row (sighted users get the same from the ⋯ and context menus).
struct ItemActions {
    let open: () -> Void
    let reveal: () -> Void
    let trash: () -> Void
}

extension View {
    func itemAccessibility(selected: Bool, actions: ItemActions) -> some View {
        accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { actions.open() }
            .accessibilityAction(named: "Show in Finder") { actions.reveal() }
            .accessibilityAction(named: "Move to Trash") { actions.trash() }
    }
}

/// Floating bar shown while two or more recordings are selected.
private struct SelectionBar: View {
    let count: Int
    let snapshot: Bool
    let reveal: () -> Void
    let trash: () -> Void
    let deselect: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Text("\(count) selected")
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .padding(.leading, 10).padding(.trailing, 6)
            separator
            Button(action: reveal) { Label("Show in Finder", systemImage: "folder") }
                .buttonStyle(BarButtonStyle())
                .help("Show in Finder (⇧⌘R)")
            Button(action: trash) { Label("Move to Trash…", systemImage: "trash") }
                .buttonStyle(BarButtonStyle())
                .help("Move to Trash (⌘⌫)")
            separator
            Button("Deselect", action: deselect)
                .buttonStyle(BarButtonStyle())
                .help("Deselect (Esc)")
        }
        .padding(.horizontal, 5)
        .frame(height: 38)
        .floatingSurface(cornerRadius: 11, snapshot: snapshot, movesWindow: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(count) recordings selected")
    }

    private var separator: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 16).padding(.horizontal, 3)
    }
}

/// Borderless text button with a hover wash, for the selection bar.
private struct BarButtonStyle: ButtonStyle {
    @ViewState private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .imageScale(.small)
            .foregroundStyle(Color.primary.opacity(0.85))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.07 : 0))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// The "⋯" button that opens an item's actions (the same as its context menu).
struct MoreMenu<Content: View>: View {
    let title: String
    /// On a poster: a small material chip so it reads over any frame.
    var chip = false
    @ViewBuilder let content: () -> Content
    @ViewState private var hovering = false

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis")
                .font(.system(size: chip ? 11.5 : 13, weight: .semibold))
                .foregroundStyle(chip ? Color.primary : Color.secondary)
                .frame(width: chip ? 24 : 26, height: chip ? 24 : 26)
                .background {
                    if chip {
                        Circle().fill(.regularMaterial)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    } else {
                        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                            .fill(Color.primary.opacity(hovering ? 0.07 : 0))
                    }
                }
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("More actions")
        .accessibilityLabel("More actions for \(title)")
    }
}

struct LibraryTile<MenuContent: View>: View {
    let item: LibraryItem
    let poster: CGImage?
    var selected = false
    var forceHover = false
    let actions: ItemActions
    @ViewBuilder let menu: () -> MenuContent
    @ViewState private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lifted: Bool { hovering || forceHover }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .bottomTrailing) {
                PosterView(poster: poster)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2.5)
                        .padding(-4))
                    .shadow(color: .black.opacity(lifted ? 0.16 : 0.07), radius: lifted ? 10 : 4, y: lifted ? 5 : 2)
                Text(TimeFormat.clock(item.duration))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.62)))
                    .padding(8)
            }
            .scaleEffect(lifted && !reduceMotion ? 1.01 : 1)
            .animation(Theme.snappy, value: lifted)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.createdAt.formatted(.relative(presentation: .named)))
                    if let views = item.views {
                        Text("·")
                        Label(views == 1 ? "1 view" : "\(views) views", systemImage: "eye").labelStyle(.titleAndIcon)
                    } else if item.shareURL != nil {
                        Text("·")
                        Label("Shared", systemImage: "link").labelStyle(.titleAndIcon)
                    }
                    if item.recovered {
                        Text("·")
                        Label("Recovered", systemImage: "arrow.clockwise").foregroundStyle(Theme.warning)
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .imageScale(.small)
            }
        }
        .contentShape(Rectangle())
        .itemAccessibility(selected: selected, actions: actions)
        .accessibilityHint("Double-click to open")
        .overlay(alignment: .topTrailing) {
            let show = lifted || selected
            MoreMenu(title: item.title, chip: true, content: menu)
                .padding(7)
                .opacity(show ? 1 : 0)
                .allowsHitTesting(show)
                .animation(.easeOut(duration: 0.12), value: show)
        }
        .onHover { hovering = $0 }
    }
}

struct LibraryRow<MenuContent: View>: View {
    let item: LibraryItem
    let poster: CGImage?
    var selected = false
    /// Selected neighbours: square off the shared edge so a run of selected rows is one block.
    var joinsAbove = false
    var joinsBelow = false
    let actions: ItemActions
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                PosterView(poster: poster)
                    .frame(width: 96, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                if item.recovered { Label("Recovered", systemImage: "arrow.clockwise").font(.system(size: 11.5)).foregroundStyle(Theme.warning) }
                if let views = item.views {
                    Label(views == 1 ? "1 view" : "\(views) views", systemImage: "eye")
                        .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                } else if item.shareURL != nil {
                    Image(systemName: "link").foregroundStyle(.secondary).help("Shared")
                }
                Text(TimeFormat.clock(item.duration)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)
            }
            .itemAccessibility(selected: selected, actions: actions)
            MoreMenu(title: item.title, content: menu)
        }
        .padding(.vertical, 8)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .background {
            let top: CGFloat = joinsAbove ? 0 : 8, bottom: CGFloat = joinsBelow ? 0 : 8
            UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom,
                                   topTrailingRadius: top, style: .continuous)
                .fill(selected ? Theme.accentSoft : .clear)
                // Cover the hidden divider's 1 pt so the block has no seam.
                .padding(.bottom, joinsBelow ? -1 : 0)
        }
        .contentShape(Rectangle())
    }
}

struct PosterView: View {
    let poster: CGImage?
    var body: some View {
        ZStack {
            Rectangle().fill(Theme.fieldFill)
            if let poster {
                Image(decorative: poster, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film").foregroundStyle(.tertiary)
            }
        }
    }
}
