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

    @ObservationIgnored private let services: Services
    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private var loadedAt = Date.distantPast

    init(services: Services, prefs: Preferences) {
        self.services = services
        self.prefs = prefs
    }

    var filtered: [LibraryItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    func reload() {
        let bundles = prefs.library.list()
        items = bundles.compactMap(Self.item(for:))
        loadedAt = Date()
        loadPosters()
    }

    func reloadIfStale() { if Date().timeIntervalSince(loadedAt) > 5 { reload() } }

    /// Sets items directly (snapshots).
    func setForSnapshot(_ items: [LibraryItem], posters: [URL: CGImage]) {
        self.items = items
        self.posters = posters
    }

    static func item(for b: ProjectBundle) -> LibraryItem? {
        guard let m = try? b.readManifest() else { return nil }
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

    /// Rebuilds recordings the app was writing when it last quit or crashed.
    func recoverInterruptedRecordings() {
        var any = false
        for b in prefs.library.list() {
            guard let m = try? b.readManifest(), m.status == .recording else { continue }
            if (try? services.recorder.recoverIfNeeded(b)) == true { any = true }
        }
        reload()
        if any {
            Toast.show(title: "Recording recovered", detail: "Reelbird rebuilt a recording that was cut short. It's in your Library.",
                       symbol: "arrow.clockwise.circle.fill", duration: 6)
        }
    }

    func noteRecent(_ b: ProjectBundle) {
        if !items.contains(where: { $0.id == b.url }) { reload() }
    }

    func reveal(_ item: LibraryItem) { NSWorkspace.shared.activateFileViewerSelecting([item.bundle.url]) }

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
                try? copy.writeEdit(e)
            }
            reload()
        } catch {
            NSSound.beep()
        }
    }

    func moveToTrash(_ item: LibraryItem) {
        do {
            try FileManager.default.trashItem(at: item.bundle.url, resultingItemURL: nil)
            items.removeAll { $0.id == item.id }
            posters[item.id] = nil
        } catch {
            NSSound.beep()
        }
    }

    func copyLink(_ item: LibraryItem) {
        guard let url = item.shareURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        Toast.show(title: "Link copied", symbol: "link")
    }
}
