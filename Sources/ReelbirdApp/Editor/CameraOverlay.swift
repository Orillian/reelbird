import ReelbirdCore
import SwiftUI

/// Over the preview: the camera bubble can be dragged anywhere on the canvas. It snaps to the edges and
/// centre lines (within 6 pt) and shows a thin guide for each line it snapped to. The drag sets the place in
/// effect at the playhead: the start place, or the recorded move the playhead is in.
struct CameraOverlay: View {
    let model: EditorModel
    @ViewState private var dragOrigin: CGPoint?
    @ViewState private var hovering = false

    static let snapTolerance: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let canvas = CropOverlay.fit(aspect: model.canvasPixelSize.aspect, in: geo.size)
            let layout = model.edit.camera
            let f = CameraPlacement.frame(at: model.cameraPosition, layout: layout, width: canvas.width, height: canvas.height)
                .offsetBy(dx: canvas.minX, dy: canvas.minY)
            let dragging = model.cameraDraft != nil
            ZStack(alignment: .topLeading) {
                Color.clear.allowsHitTesting(false)
                if dragging { guides(model.cameraGuides, bubble: f, canvas: canvas) }
                CameraBubbleShape(shape: layout.shape)
                    .stroke(Color.white.opacity(dragging ? 0.9 : hovering ? 0.65 : 0), lineWidth: 1.5)
                    .shadow(color: .black.opacity(dragging || hovering ? 0.35 : 0), radius: 1.5)
                    .contentShape(CameraBubbleShape(shape: layout.shape))
                    .frame(width: f.width, height: f.height)
                    .offset(x: f.minX, y: f.minY)
                    .onHover { h in withAnimation(Theme.snappy) { hovering = h } }
                    .pointerStyle(dragging ? .grabActive : .grabIdle)
                    .gesture(drag(frame: f, canvas: canvas))
                    .help("Drag to move the camera")
                    .accessibilityElement()
                    .accessibilityLabel("Camera bubble")
                    .accessibilityHint("Drag to move it. Corner presets are in the Camera panel.")
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    private func drag(frame f: CGRect, canvas: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { v in
                if dragOrigin == nil {
                    dragOrigin = CGPoint(x: f.minX - canvas.minX, y: f.minY - canvas.minY)
                    model.beginCameraDrag()
                }
                guard let o = dragOrigin else { return }
                let layout = model.edit.camera
                let raw = CameraPlacement.position(origin: CGPoint(x: o.x + v.translation.width, y: o.y + v.translation.height),
                                                   layout: layout, width: canvas.width, height: canvas.height)
                let s = CameraPlacement.snapped(raw, layout: layout, width: canvas.width, height: canvas.height,
                                                tolerance: Self.snapTolerance)
                model.updateCameraDrag(s.position, guides: s.guides)
            }
            .onEnded { _ in
                dragOrigin = nil
                model.endCameraDrag()
            }
    }

    /// Subtle lines for the edges and centre lines the bubble snapped to.
    private func guides(_ g: CameraPlacement.Guides, bubble f: CGRect, canvas c: CGRect) -> some View {
        Canvas { ctx, _ in
            var path = Path()
            func v(_ x: CGFloat) { path.move(to: CGPoint(x: x, y: c.minY)); path.addLine(to: CGPoint(x: x, y: c.maxY)) }
            func h(_ y: CGFloat) { path.move(to: CGPoint(x: c.minX, y: y)); path.addLine(to: CGPoint(x: c.maxX, y: y)) }
            if g.contains(.left) { v(f.minX) }
            if g.contains(.right) { v(f.maxX) }
            if g.contains(.centerX) { v(c.midX) }
            if g.contains(.top) { h(f.minY) }
            if g.contains(.bottom) { h(f.maxY) }
            if g.contains(.centerY) { h(c.midY) }
            let px = 1 / max(1, ctx.environment.displayScale)
            ctx.stroke(path, with: .color(.black.opacity(0.25)), style: StrokeStyle(lineWidth: 1 + 2 * px))
            ctx.stroke(path, with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}
