import Foundation
import ReelbirdCore

/// Markers in the editor: the flags on the timeline ruler. The first change (rename, delete, add) saves the
/// whole list into `edit.json → markers`; until then they come from the recording's `marker` events.
extension EditorModel {
    var markers: [Marker] { Markers.resolve(edit: edit, events: events) }

    func renameMarker(_ id: String, to title: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var list = markers
        guard let i = list.firstIndex(where: { $0.id == id }), list[i].title != name else { return }
        list[i].title = String(name.prefix(120))
        change("Rename Marker") { $0.markers = list }
    }

    func deleteMarker(_ id: String) {
        var list = markers
        list.removeAll { $0.id == id }
        change("Delete Marker") { $0.markers = list }
    }

    /// M: a marker at the playhead, named "Marker N" after the highest number so far.
    func addMarkerAtPlayhead() {
        var list = markers
        guard !list.contains(where: { abs($0.t - playhead) < 0.05 }) else { return }
        let used = list.compactMap { m -> Int? in
            guard m.title.hasPrefix("Marker ") else { return nil }
            return Int(m.title.dropFirst("Marker ".count))
        }
        list.append(Marker(t: playhead, title: Markers.defaultTitle(max(list.count, used.max() ?? 0) + 1)))
        list.sort { $0.t < $1.t }
        change("Add Marker") { $0.markers = list }
    }

    /// "Use Markers as Chapters": replaces the chapters (Undo brings them back). The share viewer lists them.
    func useMarkersAsChapters() {
        let chapters = Markers.chapters(from: markers, timeline: timeline)
        guard !chapters.isEmpty else { return }
        change("Use Markers as Chapters") { $0.chapters = chapters }
    }
}
