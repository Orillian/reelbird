import AppKit
import ReelbirdCore
import SwiftUI

struct LibraryView: View {
    @Bindable var store: LibraryStore
    let app: AppModel?
    @Environment(\.isSnapshot) private var snapshot

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.items.isEmpty {
                empty
            } else if store.filtered.isEmpty {
                Text("No recordings match “\(store.query)”")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Group { if store.gridLayout { grid } else { list } }
                    .focusable()
                    .focusEffectDisabled()
                    .onKeyPress(.return) { open(store.selectedItem); return .handled }
                    .onKeyPress(keys: [.delete]) { press in
                        guard press.modifiers.contains(.command), let item = store.selectedItem else { return .ignored }
                        store.moveToTrash(item); return .handled
                    }
                    .onKeyPress(keys: [.leftArrow, .upArrow]) { _ in store.moveSelection(-1); return .handled }
                    .onKeyPress(keys: [.rightArrow, .downArrow]) { _ in store.moveSelection(1); return .handled }
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

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 224, maximum: 320), spacing: 22, alignment: .top)], spacing: 26) {
                ForEach(store.filtered) { item in
                    LibraryTile(item: item, poster: store.posters[item.id], selected: store.selection == item.id)
                        .onTapGesture { store.selection = item.id }
                        .simultaneousGesture(TapGesture(count: 2).onEnded { open(item) })
                        .accessibilityAction { open(item) }
                        .contextMenu { menu(item) }
                }
            }
            .padding(Theme.Space.xl)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.filtered) { item in
                    LibraryRow(item: item, poster: store.posters[item.id], selected: store.selection == item.id)
                        .onTapGesture { store.selection = item.id }
                        .simultaneousGesture(TapGesture(count: 2).onEnded { open(item) })
                        .accessibilityAction { open(item) }
                        .contextMenu { menu(item) }
                    Divider().padding(.leading, 120)
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.s)
        }
    }

    private func open(_ item: LibraryItem?) {
        guard let item else { return }
        app?.open(bundle: item.bundle)
    }

    @ViewBuilder private func menu(_ item: LibraryItem) -> some View {
        Button("Open") { app?.open(bundle: item.bundle) }
        if item.shareURL != nil { Button("Copy Link") { store.copyLink(item) } }
        Button("Show in Finder") { store.reveal(item) }
        Button("Duplicate") { store.duplicate(item) }
        Divider()
        Button("Move to Trash", role: .destructive) { store.moveToTrash(item) }
    }
}

struct LibraryTile: View {
    let item: LibraryItem
    let poster: CGImage?
    var selected = false
    @ViewState private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    .shadow(color: .black.opacity(hovering ? 0.16 : 0.07), radius: hovering ? 10 : 4, y: hovering ? 5 : 2)
                Text(TimeFormat.clock(item.duration))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.62)))
                    .padding(8)
            }
            .scaleEffect(hovering && !reduceMotion ? 1.01 : 1)
            .animation(Theme.snappy, value: hovering)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.createdAt.formatted(.relative(presentation: .named)))
                    if item.shareURL != nil {
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
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Double-click to open")
    }
}

struct LibraryRow: View {
    let item: LibraryItem
    let poster: CGImage?
    var selected = false
    var body: some View {
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
            if item.shareURL != nil { Image(systemName: "link").foregroundStyle(.secondary).help("Shared") }
            Text(TimeFormat.clock(item.duration)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.accentSoft : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
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
