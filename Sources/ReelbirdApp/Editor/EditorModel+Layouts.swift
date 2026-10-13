import AppKit
import ReelbirdCore

/// Camera layouts over time (the Layouts lane) and the bubble during zooms.
extension EditorModel {
    /// How long a layout added at the playhead lasts, at most.
    static let newLayoutLength = 3.0
    /// The shortest layout segment the lane allows by dragging.
    static let minimumLayoutLength = 0.3

    /// The layouts over time, as the renderer plays them.
    var layoutTimeline: LayoutTimeline { edit.layoutTimeline(duration: duration) }

    /// The layout at the playhead (the overlay without a camera).
    var layoutAtPlayhead: LayoutTimeline.State {
        hasCamera && edit.camera.visible ? layoutTimeline.state(at: playhead) : .overlay
    }

    /// Whether the camera shows as the bubble at the playhead (not mid-change or in another layout).
    var isBubbleAtPlayhead: Bool {
        let s = layoutAtPlayhead
        return s.from == .overlay && s.to == .overlay
    }

    var selectedLayout: LayoutSegment? {
        guard case .layout(let id) = selection else { return nil }
        return edit.layouts.first { $0.id == id }
    }

    /// Adds a layout segment at the playhead (up to 3 s, ending before the next one), or selects the one the
    /// playhead is in.
    func addLayoutAtPlayhead(_ kind: LayoutSegment.Kind = .fullCamera) {
        guard hasCamera else {
            Toast.show(title: "No camera in this recording", detail: "Layouts arrange the screen and the camera.", symbol: "person.crop.rectangle")
            return
        }
        let t = playhead
        if let s = edit.layouts.first(where: { $0.range.contains(t) }) {
            selection = .layout(s.id)
            section = .camera
            return
        }
        let next = edit.layouts.first { $0.range.start > t }?.range.start ?? duration
        let end = min(t + Self.newLayoutLength, next, duration)
        guard end - t >= Self.minimumLayoutLength else {
            Toast.show(title: "No room for a layout here", detail: "Move the playhead away from the end or the next layout.",
                       symbol: "person.crop.rectangle")
            return
        }
        let segment = LayoutSegment(range: TimeRange(start: t, end: end), kind: kind)
        change("Add Layout") { e in
            e.layouts = LayoutSegment.normalized(e.layouts + [segment])
            e.camera.visible = true
        }
        selection = .layout(segment.id)
        section = .camera
    }

    /// Changes a segment, keeping it between its neighbours and at least `minimumLayoutLength` long.
    func updateLayout(_ id: String, coalesce: String, _ body: (inout LayoutSegment) -> Void) {
        let duration = duration
        change("Edit Layout", coalesce: coalesce + id) { e in
            guard let i = e.layouts.firstIndex(where: { $0.id == id }) else { return }
            var s = e.layouts[i]
            body(&s)
            let lo = i > 0 ? e.layouts[i - 1].range.end : 0
            let hi = i + 1 < e.layouts.count ? e.layouts[i + 1].range.start : duration
            let start = min(max(lo, s.range.start), hi - Self.minimumLayoutLength)
            let end = max(min(hi, s.range.end), start + Self.minimumLayoutLength)
            s.range = TimeRange(start: max(lo, start), end: min(hi, end))
            e.layouts[i] = s
        }
    }

    /// Moves a segment to start at `start`, keeping its length, between its neighbours.
    func moveLayout(_ id: String, to start: Double) {
        guard let i = edit.layouts.firstIndex(where: { $0.id == id }) else { return }
        let d = edit.layouts[i].range.duration
        let lo = i > 0 ? edit.layouts[i - 1].range.end : 0
        let hi = i + 1 < edit.layouts.count ? edit.layouts[i + 1].range.start : duration
        let s = min(max(lo, start), max(lo, hi - d))
        updateLayout(id, coalesce: "move") { $0.range = TimeRange(start: s, end: s + d) }
    }

    func setLayoutKind(_ id: String, _ kind: LayoutSegment.Kind) {
        updateLayout(id, coalesce: "kind") { $0.kind = kind }
    }

    func deleteLayout(_ id: String) {
        change("Delete Layout") { $0.layouts.removeAll { $0.id == id } }
        if selection == .layout(id) { selection = nil }
    }

    /// The bubble's frame on a `width` × `height` canvas at the playhead, as the renderer draws it: at its place
    /// (or where it is being dragged), smaller and stepped aside during a zoom.
    func cameraOverlayFrame(width: Double, height: Double) -> (frame: CGRect, layout: CameraLayout) {
        var layout = edit.camera
        let shown = player?.cameraBubble(atSource: playhead)
        layout.size *= shown?.sizeScale ?? 1
        let place = cameraDraft ?? shown?.place ?? edit.camera.path.position(at: playhead)
        return (CameraPlacement.frame(at: place, layout: layout, width: width, height: height), layout)
    }
}

extension LayoutSegment.Kind {
    /// The symbol for the lane and the inspector. Split shows side by side, or stacked on a tall canvas.
    func symbol(tall: Bool = false) -> String {
        switch self {
        case .overlay: "person.crop.circle"
        case .fullCamera: "person.crop.rectangle"
        case .split: tall ? "rectangle.split.1x2" : "rectangle.split.2x1"
        case .screenOnly: "macwindow"
        }
    }

    /// What the inspector calls it.
    var label: String {
        switch self {
        case .overlay: "Bubble"
        case .fullCamera: "Camera"
        case .split: "Split"
        case .screenOnly: "Screen"
        }
    }
}
