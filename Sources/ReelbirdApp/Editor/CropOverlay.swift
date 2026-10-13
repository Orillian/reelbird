import ReelbirdCore
import SwiftUI

/// Crop mode, over the preview (which shows the whole uncropped screen): the area outside the crop is dimmed,
/// edges and corners drag, the inside moves, and the top edge snaps to the detected browser toolbar line.
struct CropOverlay: View {
    let model: EditorModel
    @ViewState private var dragStart: NormRect?
    @Environment(\.isSnapshot) private var snapshot

    /// What a drag moves: a set of edges, or the whole rectangle.
    struct Edges: OptionSet, Hashable {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), top = Edges(rawValue: 4), bottom = Edges(rawValue: 8)
        static let all: Edges = [.left, .right, .top, .bottom]
    }

    var body: some View {
        GeometryReader { geo in
            let frame = Self.fit(aspect: model.screenPixelSize.aspect, in: geo.size)
            let draft = model.cropDraft ?? .full
            let r = Self.rect(draft, in: frame)
            ZStack(alignment: .topLeading) {
                // Dimmed outside, clear inside.
                Path { p in p.addRect(frame); p.addRect(r) }
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                    .contentShape(Rectangle())
                if let line = toolbarLine(frame) {
                    toolbarGuide(y: line, frame: frame, active: abs(r.minY - line) < 0.5)
                }
                thirds(r)
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                    .shadow(color: .black.opacity(0.35), radius: 2)
                // The inside moves the crop.
                Color.white.opacity(0.001)
                    .frame(width: max(0, r.width - 36), height: max(0, r.height - 36))
                    .offset(x: r.minX + 18, y: r.minY + 18)
                    .gesture(drag(.all, frame: frame))
                    .pointerStyle(dragStart == nil ? .grabIdle : .grabActive)
                ForEach(Self.handles, id: \.self) { edges in
                    handle(edges, in: r)
                        .gesture(drag(edges, frame: frame))
                }
                sizeReadout(draft, r: r, frame: frame)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Crop")
    }

    // MARK: Geometry

    static let handles: [Edges] = [[.top, .left], [.top, .right], [.bottom, .left], [.bottom, .right], .top, .bottom, .left, .right]

    /// The screen's rectangle inside the preview (the preview letterboxes the frame the same way).
    static func fit(aspect: Double, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, aspect > 0 else { return .zero }
        var w = size.width, h = size.width / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    static func rect(_ n: NormRect, in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + n.x * frame.width, y: frame.minY + n.y * frame.height,
               width: n.width * frame.width, height: n.height * frame.height)
    }

    /// The draft after dragging `edges` by a translation (in points), with snapping to the screen's edges and
    /// the toolbar line (within 8 pt), never smaller than 5% of the screen.
    static func dragged(_ start: NormRect, edges: Edges, by t: CGSize, frame: CGRect, toolbar: Double?) -> NormRect {
        guard frame.width > 0, frame.height > 0 else { return start }
        let dx = t.width / frame.width, dy = t.height / frame.height
        let m = NormRect.minimumCropSide
        let snapX = 8 / frame.width, snapY = 8 / frame.height
        func snap(_ v: Double, _ targets: [Double], _ tol: Double) -> Double {
            targets.min(by: { abs($0 - v) < abs($1 - v) }).flatMap { abs($0 - v) <= tol ? $0 : nil } ?? v
        }
        var x0 = start.x, y0 = start.y, x1 = start.x + start.width, y1 = start.y + start.height
        if edges == .all {
            let w = x1 - x0, h = y1 - y0
            x0 = min(max(0, x0 + dx), 1 - w); y0 = min(max(0, y0 + dy), 1 - h)
            y0 = snap(y0, [0, 1 - h] + (toolbar.map { [$0] } ?? []), snapY)
            x0 = snap(x0, [0, 1 - w], snapX)
            return NormRect(x: x0, y: y0, width: w, height: h)
        }
        if edges.contains(.left) { x0 = snap(min(max(0, x0 + dx), x1 - m), [0], snapX) }
        if edges.contains(.right) { x1 = snap(max(min(1, x1 + dx), x0 + m), [1], snapX) }
        if edges.contains(.top) { y0 = snap(min(max(0, y0 + dy), y1 - m), [0] + (toolbar.map { [$0] } ?? []), snapY) }
        if edges.contains(.bottom) { y1 = snap(max(min(1, y1 + dy), y0 + m), [1], snapY) }
        return NormRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private func drag(_ edges: Edges, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { v in
                let start = dragStart ?? model.cropDraft ?? .full
                if dragStart == nil { dragStart = start }
                model.updateCropDraft(Self.dragged(start, edges: edges, by: v.translation, frame: frame,
                                                   toolbar: model.toolbarCrop?.y))
            }
            .onEnded { _ in dragStart = nil }
    }

    /// The detected toolbar line, in view points.
    private func toolbarLine(_ frame: CGRect) -> CGFloat? {
        guard let top = model.toolbarCrop?.y else { return nil }
        return frame.minY + top * frame.height
    }

    // MARK: Pieces

    private func handle(_ edges: Edges, in r: CGRect) -> some View {
        let corner = edges.contains(.left) || edges.contains(.right)
        let isCorner = corner && (edges.contains(.top) || edges.contains(.bottom))
        let x = edges.contains(.left) ? r.minX : edges.contains(.right) ? r.maxX : r.midX
        let y = edges.contains(.top) ? r.minY : edges.contains(.bottom) ? r.maxY : r.midY
        let horizontalBar = edges == .top || edges == .bottom
        let size = isCorner ? CGSize(width: 14, height: 14) : horizontalBar ? CGSize(width: 34, height: 6) : CGSize(width: 6, height: 34)
        return RoundedRectangle(cornerRadius: isCorner ? 3.5 : 3, style: .continuous)
            .fill(Color.white)
            .overlay(RoundedRectangle(cornerRadius: isCorner ? 3.5 : 3, style: .continuous).strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .frame(width: size.width, height: size.height)
            // A generous hit area around the visible knob.
            .frame(width: size.width + 16, height: size.height + 16)
            .contentShape(Rectangle())
            .offset(x: x - (size.width + 16) / 2, y: y - (size.height + 16) / 2)
            .pointerStyle(.frameResize(position: Self.position(edges)))
            .accessibilityLabel(Self.name(edges))
    }

    private static func position(_ e: Edges) -> FrameResizePosition {
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

    private static func name(_ e: Edges) -> String {
        var parts: [String] = []
        if e.contains(.top) { parts.append("Top") }
        if e.contains(.bottom) { parts.append("Bottom") }
        if e.contains(.left) { parts.append("left") }
        if e.contains(.right) { parts.append("right") }
        return parts.joined(separator: " ").capitalizedFirst + " edge"
    }

    /// Rule-of-thirds lines inside the crop, faint.
    private func thirds(_ r: CGRect) -> some View {
        Path { p in
            for i in 1...2 {
                let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
        .allowsHitTesting(false)
    }

    /// The detected toolbar's bottom edge: a dashed line with a label; solid accent when the crop sits on it.
    private func toolbarGuide(y: CGFloat, frame: CGRect, active: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            Path { p in p.move(to: CGPoint(x: frame.minX, y: y)); p.addLine(to: CGPoint(x: frame.maxX, y: y)) }
                .stroke(active ? Theme.accent : Color.white.opacity(0.8), style: StrokeStyle(lineWidth: active ? 1.5 : 1, dash: active ? [] : [5, 4]))
            Text("Toolbar")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(active ? Theme.onAccent : Theme.inkFixed)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(Capsule().fill(active ? Theme.accent : Color.white.opacity(0.9)))
                .fixedSize()
                .frame(width: 80, alignment: .trailing)
                // Above the line, clear of the corner handle.
                .offset(x: frame.maxX - 80 - 26, y: y - 26)
        }
        .allowsHitTesting(false)
    }

    private func sizeReadout(_ n: NormRect, r: CGRect, frame: CGRect) -> some View {
        let px = CropSpace(n).pixelSize(of: model.screenPixelSize)
        let below = r.maxY + 30 < frame.maxY
        return Text(verbatim: "\(px.width) × \(px.height)")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(Color.white)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .fixedSize()
            .frame(width: 140)
            .offset(x: r.midX - 70, y: below ? r.maxY + 8 : r.maxY - 30)
            .allowsHitTesting(false)
            .accessibilityLabel("\(px.width) by \(px.height) pixels")
    }
}

/// The bar under the preview in crop mode: what's happening, Cancel and Done (Esc / Return).
struct CropBar: View {
    let model: EditorModel
    @Environment(\.isSnapshot) private var snapshot

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "crop").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Text("Drag the edges to crop.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: Theme.Space.m)
            if model.toolbarCrop != nil {
                Button("Hide Toolbar") { if let c = model.toolbarCrop { model.updateCropDraft(c) } }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.cropDraft == model.toolbarCrop)
                    .help("Crop to just below the browser toolbar")
            }
            Button("Reset") { model.updateCropDraft(.full) }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.cropDraft == .full)
            Button("Cancel") { model.cancelCrop() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Done") { model.commitCrop() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 44)
        .frame(maxWidth: 620)
        .floatingSurface(cornerRadius: 12, snapshot: snapshot, movesWindow: false)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
