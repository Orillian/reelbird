import Foundation

/// A point on the recording timeline someone flagged: dropped with the marker shortcut (or the control bar's
/// flag button, or MCP `add_marker`) while recording, or added in the editor. Shown as a flag on the editor
/// timeline; markers can become chapters.
public struct Marker: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// Seconds on the recording (source) timeline.
    public var t: Double
    public var title: String

    public init(id: String = ShortID.make(length: 6), t: Double, title: String) {
        self.id = id; self.t = t; self.title = title
    }
}

/// What `RecordingSession.addMarker` logged: the marker's number in this take (1, 2, …), its time on the
/// recording timeline and its label.
public struct RecordedMarker: Codable, Hashable, Sendable {
    public var number: Int
    public var t: Double
    public var label: String

    public init(number: Int, t: Double, label: String) { self.number = number; self.t = t; self.label = label }
}

public enum Markers {
    /// "Marker 3".
    public static func defaultTitle(_ number: Int) -> String { "Marker \(number)" }

    /// A label for a marker: the given one trimmed (at most 120 characters), else "Marker N".
    public static func label(_ label: String?, number: Int) -> String {
        let s = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? defaultTitle(number) : String(s.prefix(120))
    }

    /// The markers logged while recording (`marker` events), in time order, with stable IDs (`m1`, `m2`, …)
    /// so a marker keeps its ID once the editor saves the list into `edit.json`.
    public static func fromEvents(_ events: [InputEvent]) -> [Marker] {
        var out: [Marker] = []
        for e in events where e.type == .marker {
            let n = out.count + 1
            out.append(Marker(id: "m\(n)", t: max(0, e.t), title: label(e.label, number: n)))
        }
        return out
    }

    /// The project's markers: `edit.json → markers` when present (renamed, deleted or added in the editor),
    /// otherwise the ones logged while recording. Sorted by time.
    public static func resolve(edit: EditDocument?, events: [InputEvent]) -> [Marker] {
        (edit?.markers ?? fromEvents(events)).sorted { $0.t < $1.t }
    }

    /// Chapters from markers, on the recording timeline like `EditDocument.chapters`.
    ///
    /// A marker in a cut or pause moves to where the video carries on (the next kept moment); one past the
    /// end is dropped. Markers that land within a second of the previous one (in the edited video) are merged,
    /// keeping the first title. When the first marker comes more than a second after the start, a "Start"
    /// chapter opens the list, so the chapter list covers the whole video.
    public static func chapters(from markers: [Marker], timeline: EditTimeline) -> [Chapter] {
        guard let first = timeline.kept.first else { return [] }
        var out: [(output: Double, chapter: Chapter)] = []
        for m in markers.sorted(by: { $0.t < $1.t }) {
            guard let source = keptTime(m.t, timeline: timeline), let output = timeline.outputTime(forSource: source) else { continue }
            if let last = out.last, output - last.output < 1 { continue }
            out.append((output, Chapter(time: source, title: m.title)))
        }
        guard !out.isEmpty else { return [] }
        if out[0].output > 1 { out.insert((0, Chapter(time: first.start, title: "Start")), at: 0) } else { out[0].chapter.time = first.start }
        return out.map(\.chapter)
    }

    /// `t` if it is kept, else the start of the next kept range, else `nil`.
    static func keptTime(_ t: Double, timeline: EditTimeline) -> Double? {
        for r in timeline.kept {
            if r.contains(t) { return t }
            if r.start >= t { return r.start }
        }
        return nil
    }
}
