import ReelbirdCore
import SwiftUI

/// Over the preview while overlays are being edited: drag to draw with the armed tool, click an overlay to
/// select it, drag it to move, drag its handles to resize (an arrow's ends move on their own), and see Find
/// Sensitive Info's findings outlined. Everything converts through the player's `ScreenMapping`, so handles sit
/// exactly on what the renderer draws at the playhead, through zoom, crop, padding and aspect.
struct OverlayCanvas: View {
    let model: EditorModel
    @ViewState private var drawStart: CGPoint?
    @ViewState private var drawEnd: CGPoint?
    @ViewState private var dragOrigin: Annotation?
    @ViewState private var hovered: String?

    var body: some View {
        GeometryReader { geo in
            let canvas = CropOverlay.fit(aspect: model.canvasPixelSize.aspect, in: geo.size)
            if let m = model.player?.screenMapping(atSource: model.playhead, width: canvas.width, height: canvas.height)?
                .offsetBy(dx: canvas.minX, dy: canvas.minY) {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.selection = nil }
                    suggestionOutlines(m)
                    ForEach(visible.filter { $0.id != model.selectedAnnotation?.id }) { a in
                        hitArea(a, m)
                    }
                    if let a = model.selectedAnnotation, a.range.contains(model.playhead) {
                        selectionFrame(a, m)
                    }
                    if model.overlays.tool != nil {
                        drawLayer(m, canvas: canvas)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Overlays")
    }

    private var visible: [Annotation] { model.edit.annotations.filter { $0.range.contains(model.playhead) } }

    // MARK: Drawing a new overlay

    private func drawLayer(_ m: ScreenMapping, canvas: CGRect) -> some View {
        let tool = model.overlays.tool ?? .blur
        return ZStack(alignment: .topLeading) {
            Color.white.opacity(0.001)
                .contentShape(Rectangle())
                .pointerStyle(.rectSelection)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in
                        if drawStart == nil { drawStart = v.startLocation }
                        drawEnd = v.location
                    }
                    .onEnded { v in
                        finishDrawing(tool, from: v.startLocation, to: v.location, m)
                        drawStart = nil; drawEnd = nil
                    })
            if let s = drawStart, let e = drawEnd {
                if tool == .arrow {
                    Path { p in p.move(to: s); p.addLine(to: e) }
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .shadow(color: .black.opacity(0.4), radius: 1.5)
                        .allowsHitTesting(false)
                } else {
                    let r = CGRect(x: min(s.x, e.x), y: min(s.y, e.y), width: abs(e.x - s.x), height: abs(e.y - s.y))
                    Rectangle().fill(Color.white.opacity(0.1))
                        .overlay(Rectangle().strokeBorder(Color.white, lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.35), radius: 1.5)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityLabel("Draw \(tool.title.lowercased())")
        .accessibilityHint("Drag on the preview to place it. Escape cancels.")
    }

    private func finishDrawing(_ tool: Annotation.Kind, from a: CGPoint, to b: CGPoint, _ m: ScreenMapping) {
        let p0 = m.screenPoint(a), p1 = m.screenPoint(b)
        let dragged = hypot(b.x - a.x, b.y - a.y) > 6
        if tool == .arrow {
            // A click places a short arrow pointing at it from the lower right.
            let tail = dragged ? p0 : NormPoint(x: min(1, p0.x + 0.12), y: min(1, p0.y + 0.1))
            let head = dragged ? p1 : p0
            model.addAnnotation(.arrow, rect: .spanning(tail, head), tail: clamp(tail), head: clamp(head))
            return
        }
        var r = NormRect.spanning(p0, p1)
        if !dragged || r.width < 0.004 || r.height < 0.004 {
            // A click: a default area centred on it.
            let size = tool == .text ? (0.0, 0.0) : (0.2, 0.08)
            r = NormRect(x: p0.x - size.0 / 2, y: p0.y - size.1 / 2, width: size.0, height: size.1)
        }
        model.addAnnotation(tool, rect: tool == .text ? NormRect(x: r.x, y: r.y, width: max(0.01, r.width), height: r.height) : r.clampedToUnit())
    }

    private func clamp(_ p: NormPoint) -> NormPoint { NormPoint(x: min(1, max(0, p.x)), y: min(1, max(0, p.y))) }

    // MARK: Existing overlays

    private func hitArea(_ a: Annotation, _ m: ScreenMapping) -> some View {
        let r = m.rect(a.rect(at: model.playhead)).insetBy(dx: -4, dy: -4)
        let isHovered = hovered == a.id
        return RoundedRectangle(cornerRadius: 3)
            .strokeBorder(Color.white.opacity(isHovered ? 0.85 : 0), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .shadow(color: .black.opacity(isHovered ? 0.35 : 0), radius: 1)
            .contentShape(Rectangle())
            .frame(width: max(12, r.width), height: max(12, r.height))
            .offset(x: r.minX, y: r.minY)
            .onHover { h in hovered = h ? a.id : (hovered == a.id ? nil : hovered) }
            .onTapGesture { model.selection = .annotation(a.id); model.section = .overlays }
            .help(a.title)
            .accessibilityElement()
            .accessibilityLabel(a.title)
            .accessibilityAddTraits(.isButton)
    }

    private func selectionFrame(_ a: Annotation, _ m: ScreenMapping) -> some View {
        let r = m.rect(a.rect(at: model.playhead))
        return ZStack(alignment: .topLeading) {
            // An arrow shows its two ends instead of a box.
            Rectangle()
                .strokeBorder(Color.white.opacity(a.kind == .arrow ? 0 : 1), lineWidth: 1.5)
                .shadow(color: .black.opacity(a.kind == .arrow ? 0 : 0.4), radius: 1.5)
                .frame(width: max(2, r.width), height: max(2, r.height))
                .offset(x: r.minX, y: r.minY)
                .allowsHitTesting(false)
            // The inside moves it.
            Color.white.opacity(0.001)
                .frame(width: max(10, r.width), height: max(10, r.height))
                .offset(x: r.minX, y: r.minY)
                .pointerStyle(dragOrigin == nil ? .grabIdle : .grabActive)
                .gesture(moveGesture(a, m))
                .accessibilityLabel("Selected \(a.title)")
                .accessibilityHint("Drag to move it")
            if a.kind == .arrow {
                let e = a.arrowEnds
                endHandle(m.point(e.tail), a, m, head: false)
                endHandle(m.point(e.head), a, m, head: true)
            } else if a.kind != .text {
                ForEach(CropOverlay.handles, id: \.self) { edges in
                    resizeHandle(edges, r)
                        .gesture(resizeGesture(edges, a, m))
                }
            }
        }
    }

    private func moveGesture(_ a: Annotation, _ m: ScreenMapping) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { v in
                let o = dragOrigin ?? a
                if dragOrigin == nil { dragOrigin = a; if model.isPlaying { model.pause() } }
                let dx = v.translation.width / m.scaleX, dy = v.translation.height / m.scaleY
                let start = o.rect
                let x = min(max(-start.width * 0.5, start.x + dx), 1 - start.width * 0.5)
                let y = min(max(-start.height * 0.5, start.y + dy), 1 - start.height * 0.5)
                model.updateAnnotation(a.id, "Move Overlay", coalesce: "move") { ann in
                    ann = o
                    ann.setRect(NormRect(x: x, y: y, width: start.width, height: start.height))
                }
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private func resizeGesture(_ edges: CropOverlay.Edges, _ a: Annotation, _ m: ScreenMapping) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { v in
                let o = dragOrigin ?? a
                if dragOrigin == nil { dragOrigin = a }
                let r = Self.resized(o.rect, edges: edges, dx: v.translation.width / m.scaleX, dy: v.translation.height / m.scaleY)
                model.updateAnnotation(a.id, "Resize Overlay", coalesce: "resize") { ann in
                    ann = o
                    ann.setRect(r)
                }
            }
            .onEnded { _ in dragOrigin = nil }
    }

    /// `r` with `edges` moved by (dx, dy), at least 0.4% of the screen on each side.
    static func resized(_ r: NormRect, edges: CropOverlay.Edges, dx: Double, dy: Double) -> NormRect {
        let m = 0.004
        var x0 = r.x, y0 = r.y, x1 = r.x + r.width, y1 = r.y + r.height
        if edges.contains(.left) { x0 = min(max(0, x0 + dx), x1 - m) }
        if edges.contains(.right) { x1 = max(min(1, x1 + dx), x0 + m) }
        if edges.contains(.top) { y0 = min(max(0, y0 + dy), y1 - m) }
        if edges.contains(.bottom) { y1 = max(min(1, y1 + dy), y0 + m) }
        return NormRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private func resizeHandle(_ edges: CropOverlay.Edges, _ r: CGRect) -> some View {
        let isCorner = (edges.contains(.left) || edges.contains(.right)) && (edges.contains(.top) || edges.contains(.bottom))
        let x = edges.contains(.left) ? r.minX : edges.contains(.right) ? r.maxX : r.midX
        let y = edges.contains(.top) ? r.minY : edges.contains(.bottom) ? r.maxY : r.midY
        let side: CGFloat = isCorner ? 10 : 8
        return RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous).strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
            .frame(width: side, height: side)
            .frame(width: side + 12, height: side + 12)
            .contentShape(Rectangle())
            .offset(x: x - (side + 12) / 2, y: y - (side + 12) / 2)
            .pointerStyle(.frameResize(position: Self.position(edges)))
            .accessibilityLabel("Resize")
    }

    private func endHandle(_ p: CGPoint, _ a: Annotation, _ m: ScreenMapping, head: Bool) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
            .frame(width: 11, height: 11)
            .frame(width: 24, height: 24)
            .contentShape(Circle())
            .offset(x: p.x - 12, y: p.y - 12)
            .pointerStyle(.grabIdle)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .local)
                .onChanged { v in
                    let o = dragOrigin ?? a
                    if dragOrigin == nil { dragOrigin = a }
                    let e = o.arrowEnds
                    let moved = clamp(m.screenPoint(CGPoint(x: m.point(head ? e.head : e.tail).x + v.translation.width,
                                                            y: m.point(head ? e.head : e.tail).y + v.translation.height)))
                    model.updateAnnotation(a.id, "Move Arrow", coalesce: head ? "head" : "tail") { ann in
                        ann = o
                        ann.setArrow(tail: head ? e.tail : moved, head: head ? moved : e.head)
                    }
                }
                .onEnded { _ in dragOrigin = nil })
            .accessibilityLabel(head ? "Arrow head" : "Arrow tail")
    }

    private static func position(_ e: CropOverlay.Edges) -> FrameResizePosition {
        switch e {
        case [.top, .left]: .topLeading
        case [.top, .right]: .topTrailing
        case [.bottom, .left]: .bottomLeading
        case [.bottom, .right]: .bottomTrailing
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        default: .trailing
        }
    }

    // MARK: Findings

    /// Find Sensitive Info's findings on screen now: a dashed coral outline with what it is.
    private func suggestionOutlines(_ m: ScreenMapping) -> some View {
        ForEach(model.suggestionsAtPlayhead) { s in
            let r = m.rect(s.detection.annotation().rect(at: model.playhead))
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.accent.opacity(0.12)))
                    .frame(width: r.width, height: r.height)
                Text(s.detection.kind.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(Capsule().fill(Theme.accent))
                    .fixedSize()
                    .offset(y: -19)
            }
            .offset(x: r.minX, y: r.minY)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("Found \(s.detection.kind.title)")
        }
    }
}
