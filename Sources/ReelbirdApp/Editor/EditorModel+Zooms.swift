import AppKit
import ReelbirdCore

/// Zooms copied with ⌘C, shared by every editor window while the app runs (the system clipboard is left alone,
/// so copying zooms never replaces text you copied).
@MainActor enum ZoomClipboard {
    static var zooms: [ZoomRegion] = []
}

/// Zoom selection and the zoom commands: several at once, turned off, instant, depth keys, copy and paste.
/// Every change is one undo step.
extension EditorModel {
    /// The selected zooms' IDs (empty when the selection is something else).
    var selectedZoomIDs: Set<String> {
        switch selection {
        case .zoom(let id): [id]
        case .zooms(let ids): ids
        default: []
        }
    }

    /// The selected zooms in timeline order.
    var selectedZooms: [ZoomRegion] { ZoomEditing.copy(selectedZoomIDs, from: edit.zoom.regions) }

    /// Selects these zooms: one is `.zoom`, several `.zooms`, none clears a zoom selection.
    func selectZooms(_ ids: Set<String>) {
        switch ids.count {
        case 0: if selection?.isZoom == true { selection = nil }
        case 1: selection = .zoom(ids.first!)
        default: selection = .zooms(ids)
        }
    }

    /// A click on a zoom: selects it, or with shift adds it to (or takes it out of) the selection.
    func clickZoom(_ id: String, extend: Bool) {
        selectZooms(extend ? ZoomEditing.toggling(id, in: selectedZoomIDs) : [id])
        section = .zoom
    }

    /// Box selection on the zoom lane: the zooms the box touches, added to the selection with shift.
    func boxSelectZooms(_ range: TimeRange, adding base: Set<String>) {
        zoomMarquee = range
        selectZooms(base.union(ZoomEditing.ids(overlapping: range, in: edit.zoom.regions)))
    }

    func endZoomMarquee() {
        zoomMarquee = nil
        if !selectedZoomIDs.isEmpty { section = .zoom }
    }

    func selectAllZooms() {
        selectZooms(Set(edit.zoom.regions.map(\.id)))
        section = .zoom
    }

    /// What the zoom keys (0–9, I) act on: the zoom under the pointer when it isn't selected, else the selection.
    var zoomKeyTargets: Set<String> {
        if let h = hoveredZoomID, !selectedZoomIDs.contains(h), edit.zoom.regions.contains(where: { $0.id == h }) { return [h] }
        return selectedZoomIDs
    }

    var deleteZoomsTitle: String {
        let n = selectedZoomIDs.count
        return n > 1 ? "Delete \(n) Zooms" : "Delete Zoom"
    }

    private func changeZooms(_ name: String, coalesce: String? = nil, _ body: ([ZoomRegion]) -> [ZoomRegion]) {
        change(name, coalesce: coalesce) { e in e.zoom.regions = body(e.zoom.regions) }
    }

    /// 1–9 set the depth (and turn the zoom on); 0 turns it off, or back on.
    func zoomDigit(_ n: Int) {
        let ids = zoomKeyTargets
        guard !ids.isEmpty else { return }
        if let d = ZoomEditing.depth(forDigit: n) {
            changeZooms("Zoom Depth") { ZoomEditing.settingDepth(d, for: ids, in: $0) }
        } else if n == 0 {
            toggleZoomsEnabled(ids)
        }
    }

    func setZoomDepth(_ d: Double, for ids: Set<String>) {
        changeZooms("Zoom Depth", coalesce: "depth" + ids.sorted().joined()) { ZoomEditing.settingDepth(d, for: ids, in: $0) }
    }

    func toggleZoomsEnabled(_ ids: Set<String>) {
        let turnOn = zooms(ids).allSatisfy { !$0.enabled }
        changeZooms(turnOn ? "Turn Zoom On" : "Turn Zoom Off") { ZoomEditing.togglingEnabled(ids, in: $0) }
    }

    func setZoomsEnabled(_ on: Bool, for ids: Set<String>) {
        changeZooms(on ? "Turn Zoom On" : "Turn Zoom Off") { ZoomEditing.updating(ids, in: $0) { $0.enabled = on } }
    }

    func toggleZoomsInstant(_ ids: Set<String>) {
        changeZooms("Zoom Transition") { ZoomEditing.togglingInstant(ids, in: $0) }
    }

    func setZoomsInstant(_ instant: Bool, for ids: Set<String>) {
        changeZooms("Zoom Transition") { ZoomEditing.updating(ids, in: $0) { $0.instant = instant } }
    }

    /// Gives every zoom the depth of the selected one.
    func applyDepthToAllZooms() {
        guard let d = selectedZooms.first?.scale else { return }
        changeZooms("Apply Depth to All") { ZoomEditing.settingDepth(d, for: Set($0.map(\.id)), in: $0) }
    }

    func zooms(_ ids: Set<String>) -> [ZoomRegion] { edit.zoom.regions.filter { ids.contains($0.id) } }

    // Copy and paste

    var canCopyZooms: Bool { !selectedZoomIDs.isEmpty }
    var canPasteZooms: Bool { !ZoomClipboard.zooms.isEmpty }

    func copyZooms() {
        let clip = selectedZooms
        guard !clip.isEmpty else { return }
        ZoomClipboard.zooms = clip
        guard !AutomatedRun.isSilent else { return }
        Toast.show(title: clip.count == 1 ? "Zoom copied" : "\(clip.count) zooms copied",
                   detail: "Move the playhead and press ⌘V to paste.", symbol: "doc.on.doc")
    }

    /// Pastes the copied zooms with the first one at the playhead, and selects them.
    func pasteZooms() {
        let clip = ZoomClipboard.zooms
        guard !clip.isEmpty else { return }
        var pasted: [String] = []
        let t = playhead
        change(clip.count == 1 ? "Paste Zoom" : "Paste Zooms") { e in
            let r = ZoomEditing.paste(clip, at: t, into: e.zoom.regions, duration: duration)
            e.zoom.regions = r.regions
            pasted = r.pasted
            if e.zoom.mode == .off { e.zoom.mode = .manual }
        }
        selectZooms(Set(pasted))
        section = .zoom
    }
}
