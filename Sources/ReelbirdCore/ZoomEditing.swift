import Foundation

/// Editing operations on zoom regions shared by the editor, the CLI and MCP: depth keys, copy and paste,
/// selection by time, turning zooms off and on. Pure functions over `[ZoomRegion]`.
public enum ZoomEditing {
    /// Depths the 1–9 keys set: 1 = 1.25× in quarter steps up to 8 = 3×, and 9 = the deepest (3.5×).
    public static let digitDepths: [Double] = [1.25, 1.5, 1.75, 2, 2.25, 2.5, 2.75, 3, maxDepth]
    /// The deepest zoom the editor offers (the depth slider's top).
    public static let maxDepth = 3.5
    public static let minDepth = 1.1
    /// The shortest zoom the editor keeps.
    public static let minDuration = 0.3

    /// The depth for digit key `n` (1…9), or `nil` for 0 and anything else (0 turns zooms off instead).
    public static func depth(forDigit n: Int) -> Double? {
        (1...9).contains(n) ? digitDepths[n - 1] : nil
    }

    /// Regions whose time range overlaps `range` (a box drawn on the zoom lane), in timeline order.
    public static func ids(overlapping range: TimeRange, in regions: [ZoomRegion]) -> [String] {
        let lo = min(range.start, range.end), hi = max(range.start, range.end)
        return regions.filter { $0.range.start < hi && $0.range.end > lo }
            .sorted { ($0.range.start, $0.id) < ($1.range.start, $1.id) }
            .map(\.id)
    }

    /// Shift-click: adds `id` to the selection, or takes it out if it was in.
    public static func toggling(_ id: String, in selection: Set<String>) -> Set<String> {
        var s = selection
        if s.remove(id) == nil { s.insert(id) }
        return s
    }

    /// The zooms to copy, in timeline order.
    public static func copy(_ ids: Set<String>, from regions: [ZoomRegion]) -> [ZoomRegion] {
        regions.filter { ids.contains($0.id) }.sorted { ($0.range.start, $0.id) < ($1.range.start, $1.id) }
    }

    /// Pastes copied zooms so the first starts at `time`, keeping their spacing, depth, focus, transition and
    /// on/off state. Pasted zooms get new IDs and count as yours; automatic zooms they overlap are replaced (as
    /// when you add a zoom). Zooms that would start past the end are dropped and the rest are clamped to it.
    /// Returns the new regions (sorted) and the IDs of the pasted ones.
    public static func paste(_ clip: [ZoomRegion], at time: Double, into regions: [ZoomRegion], duration: Double,
                             makeID: () -> String = { ShortID.make(length: 6) }) -> (regions: [ZoomRegion], pasted: [String]) {
        guard let first = clip.map(\.range.start).min(), duration > minDuration else { return (regions, []) }
        let start = min(max(0, time), max(0, duration - minDuration))
        var pasted: [ZoomRegion] = []
        for r in clip.sorted(by: { $0.range.start < $1.range.start }) {
            let s = start + (r.range.start - first)
            guard s <= duration - minDuration else { continue }
            var p = r
            p.id = makeID()
            p.source = .user
            p.range = TimeRange(start: s, end: min(duration, max(s + minDuration, s + r.range.duration)))
            pasted.append(p)
        }
        var out = regions.filter { a in a.source == .user || !pasted.contains { $0.range.overlaps(a.range) } }
        out += pasted
        out.sort { ($0.range.start, $0.id) < ($1.range.start, $1.id) }
        return (out, pasted.map(\.id))
    }

    /// Applies `body` to every region in `ids`. Each touched region counts as yours from then on, so automatic
    /// zooms planned again (intensity, crop) never undo it.
    public static func updating(_ ids: Set<String>, in regions: [ZoomRegion], _ body: (inout ZoomRegion) -> Void) -> [ZoomRegion] {
        regions.map { r in
            guard ids.contains(r.id) else { return r }
            var n = r
            body(&n)
            if n != r { n.source = .user }
            return n
        }
    }

    /// Turns the given zooms off, or back on when every one of them is already off.
    public static func togglingEnabled(_ ids: Set<String>, in regions: [ZoomRegion]) -> [ZoomRegion] {
        let targets = regions.filter { ids.contains($0.id) }
        let turnOn = !targets.isEmpty && targets.allSatisfy { !$0.enabled }
        return updating(ids, in: regions) { $0.enabled = turnOn }
    }

    /// Makes the given zooms instant, or animated again when every one of them is already instant.
    public static func togglingInstant(_ ids: Set<String>, in regions: [ZoomRegion]) -> [ZoomRegion] {
        let targets = regions.filter { ids.contains($0.id) }
        let makeInstant = targets.isEmpty || !targets.allSatisfy(\.instant)
        return updating(ids, in: regions) { $0.instant = makeInstant }
    }

    /// Sets the depth of the given zooms (clamped to the editor's range) and turns them on.
    public static func settingDepth(_ depth: Double, for ids: Set<String>, in regions: [ZoomRegion]) -> [ZoomRegion] {
        let d = min(maxDepth, max(minDepth, depth.isFinite ? depth : 1.8))
        return updating(ids, in: regions) { $0.scale = d; $0.enabled = true }
    }

    /// Marks regions changed outside the editor (`reelbird edit --set zoom.regions.ID.…`, MCP `set_edit`) as yours,
    /// like the editor does, so a zoom turned off or made instant isn't replaced when automatic zooms are planned again.
    public static func markingEdited(_ regions: [ZoomRegion], before: [ZoomRegion]) -> [ZoomRegion] {
        let old = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return regions.map { r in
            guard r.source == .auto, var o = old[r.id] else { return r }
            o.source = r.source
            guard o != r else { return r }
            var n = r
            n.source = .user
            return n
        }
    }
}
