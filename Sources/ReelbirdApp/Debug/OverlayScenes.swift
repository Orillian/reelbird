import AppKit
import ReelbirdCore

/// Snapshot scenes for overlays: the Overlays panel, each tool's selection on the preview, the lane with
/// stacked bars, and Find Sensitive Info scanning and suggesting.
@MainActor enum OverlayScenes {
    typealias Scene = SnapshotRunner.Scene
    typealias Editor = (InspectorSection, String?, @escaping (EditorModel) -> Void) -> Scene

    static func blur(_ r: NormRect, _ range: TimeRange, style: Annotation.BlurStyle = .blur) -> Annotation {
        var a = Annotation(kind: .blur, range: range, rect: r)
        a.style = style
        a.strength = 0.5
        return a
    }

    /// A blur, an arrow and a label on the demo recording (its settings screen sits at 2–19 s).
    static func sample(_ m: EditorModel) -> [String] {
        var arrow = Annotation(kind: .arrow, range: TimeRange(start: 3, end: 9), rect: .full)
        arrow.setArrow(tail: NormPoint(x: 0.78, y: 0.66), head: NormPoint(x: 0.62, y: 0.47))
        var text = Annotation(kind: .text, range: TimeRange(start: 3.5, end: 10), rect: NormRect(x: 0.6, y: 0.7, width: 0.2, height: 0.05), text: "New billing page")
        text.fontSize = 0.03
        m.fitTextRect(&text)
        let b = blur(NormRect(x: 0.32, y: 0.28, width: 0.3, height: 0.07), TimeRange(start: 2, end: 14))
        let box = Annotation(kind: .box, range: TimeRange(start: 11, end: 16), rect: NormRect(x: 0.1, y: 0.2, width: 0.25, height: 0.2))
        let pix = blur(NormRect(x: 0.66, y: 0.12, width: 0.2, height: 0.06), TimeRange(start: 6, end: 24), style: .pixelate)
        let hl = Annotation(kind: .highlight, range: TimeRange(start: 30, end: 36), rect: NormRect(x: 0.2, y: 0.3, width: 0.4, height: 0.3))
        // Zooms off, so every overlay is in view.
        m.change("x") { $0.annotations = [b, arrow, text, box, pix, hl]; $0.zoom.mode = .off }
        return [b.id, arrow.id, text.id, box.id, pix.id, hl.id]
    }

    static func scenes(_ editor: Editor) -> [Scene] {
        var out: [Scene] = []
        out.append(editor(.overlays, nil) { m in
            _ = sample(m)
            m.setPlayheadForSnapshot(5)
        })
        out.append(editor(.overlays, "blur-selected") { m in
            let ids = sample(m)
            m.setPlayheadForSnapshot(5)
            m.selection = .annotation(ids[0])
        })
        out.append(editor(.overlays, "pixelate-selected") { m in
            let ids = sample(m)
            m.setPlayheadForSnapshot(7)
            m.selection = .annotation(ids[4])
        })
        out.append(editor(.overlays, "arrow-selected") { m in
            let ids = sample(m)
            m.setPlayheadForSnapshot(5)
            m.selection = .annotation(ids[1])
        })
        out.append(editor(.overlays, "text-selected") { m in
            let ids = sample(m)
            m.setPlayheadForSnapshot(5)
            m.selection = .annotation(ids[2])
        })
        out.append(editor(.overlays, "highlight") { m in
            let ids = sample(m)
            m.setPlayheadForSnapshot(32)
            m.selection = .annotation(ids[5])
        })
        out.append(editor(.overlays, "tool") { m in
            m.change("x") { $0.zoom.mode = .off }
            m.setPlayheadForSnapshot(5)
            m.beginOverlayTool(.box)
        })
        out.append(editor(.overlays, "stacked") { m in
            _ = sample(m)
            var extra: [Annotation] = []
            for i in 0..<3 { extra.append(blur(NormRect(x: 0.1, y: 0.5 + Double(i) * 0.08, width: 0.2, height: 0.05), TimeRange(start: 4 + Double(i), end: 12))) }
            m.change("x") { $0.annotations += extra }
            m.setPlayheadForSnapshot(8)
        })
        out.append(editor(.overlays, "scanning") { m in
            m.change("x") { $0.zoom.mode = .off }
            m.setPlayheadForSnapshot(5)
            m.overlays.setSuggestionsForSnapshot([], scanning: 0.46)
        })
        out.append(editor(.overlays, "suggestions") { m in
            m.change("x") { $0.zoom.mode = .off }
            m.setPlayheadForSnapshot(6)
            m.overlays.setSuggestionsForSnapshot(MockData.sensitiveDetections.map {
                SensitiveSuggestion(detection: $0, thumbnail: MockArt.image(width: 216, height: 136, variant: .docs))
            })
        })
        out.append(editor(.overlays, "kept") { m in
            m.change("x") { $0.zoom.mode = .off }
            m.setPlayheadForSnapshot(6)
            m.overlays.setSuggestionsForSnapshot(MockData.sensitiveDetections.map { SensitiveSuggestion(detection: $0, thumbnail: nil) })
            m.keepAllSuggestions()
            if let first = m.edit.annotations.first { m.selection = .annotation(first.id) }
        })
        return out
    }
}
