import AppKit
import Observation
import ReelbirdCore

struct LibraryItem: Identifiable, Equatable {
    var id: URL { bundle.url }
    let bundle: ProjectBundle
    var title: String
    var duration: Double
    var createdAt: Date
    var shareURL: String?
    var sharePolished: Bool
    var recovered: Bool
    var cameraIncluded: Bool
}

/// Recordings in the library folder, newest first, with posters loaded lazily.
@MainActor @Observable final class LibraryStore {
    private(set) var items: [LibraryItem] = []
    private(set) var posters: [URL: CGImage] = [:]
    var query = ""
    var gridLayout = true
    /// The selected recordings (click, ⌘-click, ⇧-click, ⌘A, rubber band; Return opens, ⌘⌫ trashes).
    var selection: Set<URL> = []
    /// Where ⇧-click and ⇧-arrow ranges start: the last item clicked without ⇧.
    private(set) var anchor: URL?
    /// The end of the current ⇧ range, moved by the arrow keys.
    @ObservationIgnored private var lead: URL?
    /// The rubber-band rectangle while dragging, in the library's content coordinates.
    var marquee: CGRect?
    /// Snapshots only: draws this tile as if the pointer were over it.
    @ObservationIgnored var snapshotHover: URL?

    @ObservationIgnored private let services: Services
    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private var loadedAt = Date.distantPast
    /// The bundle the app is recording into right now (set by RecordingController). It stays out of the
    /// library until it is finished, and so do takes the CLI is still recording.
    @ObservationIgnored var activeRecording: URL?

    init(services: Services, prefs: Preferences) {
        self.services = services
        self.prefs = prefs
    }

    var filtered: [LibraryItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    func reload() {
        let active = activeRecording?.standardizedFileURL
        let bundles = prefs.library.list().filter { $0.url.standardizedFileURL != active }
        items = bundles.compactMap(Self.item(for:))
        loadedAt = Date()
        let ids = Set(items.map(\.id))
        if !selection.isSubset(of: ids) { selection.formIntersection(ids) }
        if let a = anchor, !ids.contains(a) { anchor = nil; lead = nil }
        loadPosters()
    }

    func reloadIfStale() { if Date().timeIntervalSince(loadedAt) > 5 { reload() } }

    /// Sets items directly (snapshots).
    func setForSnapshot(_ items: [LibraryItem], posters: [URL: CGImage]) {
        self.items = items
        self.posters = posters
    }

    static func item(for b: ProjectBundle) -> LibraryItem? {
        guard let m = try? b.readManifest(), !b.isBeingRecorded(m) else { return nil }
        let edit = try? b.readEdit()
        let duration = edit.map { EditTimeline(manifest: m, edit: $0).duration } ?? m.duration
        return LibraryItem(bundle: b, title: edit?.title ?? m.title, duration: duration, createdAt: m.createdAt,
                           shareURL: m.share?.url, sharePolished: m.share?.polished ?? false,
                           recovered: m.status == .recovered || m.status == .recording,
                           cameraIncluded: m.track(.camera) != nil)
    }

    private func loadPosters() {
        let missing = items.filter { posters[$0.id] == nil }
        guard !missing.isEmpty else { return }
        Task {
            for item in missing {
                if let img = try? await services.render.poster(bundle: item.bundle, at: min(2, item.duration / 3), maxWidth: 480) {
                    posters[item.id] = img
                }
            }
        }
    }

    /// Rebuilds recordings the app was writing when it last quit or crashed (consolidating segments
    /// can take a moment for long takes, so it runs off the main thread), then resumes their uploads.
    func recoverInterruptedRecordings() {
        let recorder = services.recorder
        let share = services.share
        let bundles = prefs.library.list()
        Task {
            let recovered = await Task.detached(priority: .userInitiated) { () -> Int in
                var count = 0
                for b in bundles {
                    // Skips takes another recorder (the CLI) is still writing, or another process is
                    // already recovering (the lock is taken without waiting). A damaged project.json counts.
                    guard recorder.needsRecovery(b) else { continue }
                    if let m = try? b.readManifest(), b.isBeingRecorded(m) { continue }
                    if (try? recorder.recoverIfNeeded(b, waitForLock: false)) == true { count += 1 }
                }
                return count
            }.value
            if recovered > 0 {
                reload()
                Toast.show(title: recovered == 1 ? "Recording recovered" : "\(recovered) recordings recovered",
                           detail: "Reelbird rebuilt what was cut short when it last quit. It's in your Library.",
                           symbol: "arrow.clockwise.circle.fill", duration: 6)
            }
            // Finish live share uploads that were cut short, so their links play to the end.
            let recent = Date().addingTimeInterval(-7 * 86_400)
            for b in bundles {
                guard let m = try? b.readManifest(), m.share != nil, m.track(.share) != nil, m.createdAt > recent else { continue }
                _ = try? await share.resumeIfNeeded(bundle: b) // same link; the manifest already has it
            }
        }
    }

    func noteRecent(_ b: ProjectBundle) {
        if !items.contains(where: { $0.id == b.url }) { reload() }
    }

    func duplicate(_ item: LibraryItem) {
        let base = item.bundle.url.deletingPathExtension().lastPathComponent
        var dest = item.bundle.url.deletingLastPathComponent().appendingPathComponent("\(base) copy.\(ProjectBundle.pathExtension)")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = item.bundle.url.deletingLastPathComponent().appendingPathComponent("\(base) copy \(n).\(ProjectBundle.pathExtension)")
            n += 1
        }
        do {
            try FileManager.default.copyItem(at: item.bundle.url, to: dest)
            let copy = ProjectBundle(url: dest)
            if var m = try? copy.readManifest() {
                m.share = nil // a copy is a new recording; it doesn't own the original's link
                m.id = ShortID.make()
                try? copy.writeManifest(m)
            }
            if var e = try? copy.readEdit() {
                e.title = "\(item.title) copy"
                _ = try? copy.writeEdit(e)
            }
            reload()
        } catch {
            Beep.play()
        }
    }

    /// Trashes without asking (snapshots and previews; the app goes through `AppModel.moveToTrash`).
    func moveToTrash(_ trashed: [LibraryItem]) {
        var gone: Set<URL> = []
        for item in trashed {
            do {
                try FileManager.default.trashItem(at: item.bundle.url, resultingItemURL: nil)
                gone.insert(item.id)
            } catch {
                Beep.play()
            }
        }
        selectNeighbour(afterRemoving: gone)
        items.removeAll { gone.contains($0.id) }
        for id in gone { posters[id] = nil }
    }

    /// Before `ids` leave the library: if they were the selection, selects the next item after them
    /// (or the one before), so the keyboard can carry on.
    func selectNeighbour(afterRemoving ids: Set<URL>) {
        guard !ids.isEmpty, !selection.isEmpty, selection.isSubset(of: ids) else { selection.subtract(ids); return }
        let list = filtered
        let last = list.lastIndex { ids.contains($0.id) } ?? -1
        let first = list.firstIndex { ids.contains($0.id) } ?? 0
        let next = list[(last + 1)...].first { !ids.contains($0.id) } ?? list[..<first].last
        if let next { select(next.id) } else { clearSelection() }
    }

    // MARK: Selection

    /// The selected recordings that are visible, in display order.
    var selectedItems: [LibraryItem] { filtered.filter { selection.contains($0.id) } }

    /// The first selected recording in display order (Return opens it).
    var selectedItem: LibraryItem? { filtered.first { selection.contains($0.id) } }

    func isSelected(_ id: URL) -> Bool { selection.contains(id) }

    /// Selects one recording and makes it the anchor.
    func select(_ id: URL) {
        selection = [id]
        anchor = id
        lead = id
    }

    /// A click on a recording: plain selects it alone, ⌘ toggles it, ⇧ selects the range from the anchor.
    func click(_ id: URL, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let a = anchor {
            let range = self.range(from: a, to: id)
            selection = modifiers.contains(.command) ? selection.union(range) : range
            lead = id
        } else if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
            lead = id
        } else {
            select(id)
        }
    }

    func selectAll() {
        let list = filtered
        selection = Set(list.map(\.id))
        anchor = list.first?.id
        lead = list.last?.id
    }

    func clearSelection() {
        if !selection.isEmpty { selection = [] }
        anchor = nil
        lead = nil
    }

    /// Sets the selection from a rubber band (`base` is what was selected before the drag, kept with ⌘).
    func setMarqueeSelection(_ hits: Set<URL>, base: Set<URL>) {
        let next = base.union(hits)
        if next != selection { selection = next }
        if let first = filtered.first(where: { hits.contains($0.id) }) {
            anchor = first.id
            lead = filtered.last { hits.contains($0.id) }?.id
        }
    }

    /// Moves the selection by `delta` places in the visible list; `extend` (⇧) grows the range from the anchor.
    func moveSelection(_ delta: Int, extend: Bool = false) {
        let list = filtered
        guard !list.isEmpty else { return }
        let from = lead.flatMap { l in list.firstIndex { $0.id == l } }
            ?? list.firstIndex { selection.contains($0.id) }
        let i = from ?? (delta > 0 ? -1 : list.count)
        let target = list[min(max(0, i + delta), list.count - 1)].id
        if extend, let a = anchor, from != nil {
            selection = range(from: a, to: target)
            lead = target
        } else {
            select(target)
        }
    }

    private func range(from a: URL, to b: URL) -> Set<URL> {
        let list = filtered
        guard let i = list.firstIndex(where: { $0.id == a }), let j = list.firstIndex(where: { $0.id == b }) else { return [b] }
        return Set(list[min(i, j)...max(i, j)].map(\.id))
    }

    func reveal(_ items: [LibraryItem]) {
        guard !items.isEmpty else { return }
        Finder.reveal(items.map(\.bundle.url))
    }

    func copyLink(_ item: LibraryItem) {
        guard let url = item.shareURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        Toast.show(title: "Link copied", symbol: "link")
    }
}
