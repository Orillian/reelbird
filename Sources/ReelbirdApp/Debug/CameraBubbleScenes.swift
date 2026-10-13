import AppKit
import ReelbirdCore
import SwiftUI

/// Snapshot scenes for the live camera bubble: every shape × size with its toolbar, hover and pressed controls,
/// light and dark camera pictures, resting and lifted. With `camera-anim` in the filter, also frame sequences of
/// the shape morph, the S/M/L resize and the appear animation (60 fps, from the same spring the app runs) and
/// a contact sheet of each.
@MainActor enum CameraBubbleScenes {
    typealias Scene = SnapshotRunner.Scene

    static let stage = CGSize(width: 460, height: 440)

    static func scenes(animations: Bool) -> [Scene] {
        var out: [Scene] = []
        for shape in CameraLayout.Shape.allCases {
            for size in CameraBubbleSize.allCases {
                out.append(scene("camera-bubble-\(shape.rawValue)-\(size.rawValue)", shape: shape, size: size))
            }
        }
        out.append(scene("camera-bubble-hover", shape: .circle, size: .medium, hovered: 1))
        out.append(scene("camera-bubble-pressed", shape: .roundedSquare, size: .medium, pressed: 5))
        out.append(scene("camera-bubble-lightcam", shape: .portrait, size: .medium, light: true))
        out.append(scene("camera-bubble-rest", shape: .circle, size: .medium, toolbar: false))
        out.append(scene("camera-bubble-lifted", shape: .circle, size: .medium, toolbar: false, lifted: true))
        out.append(scene("camera-bubble-below", shape: .roundedSquare, size: .medium, nearTop: true))
        if animations { out += animationScenes() }
        return out
    }

    /// The bubble in the lower right of the stage (as on screen), its toolbar above.
    private static func place(_ shape: CameraLayout.Shape, _ size: CameraBubbleSize, nearTop: Bool = false) -> CGRect {
        let s = size.size(shape)
        let x = stage.width - 36 - s.width
        return CGRect(x: x, y: nearTop ? 24 : stage.height - 36 - s.height, width: s.width, height: s.height)
    }

    private static func scene(_ name: String, shape: CameraLayout.Shape, size: CameraBubbleSize, toolbar: Bool = true,
                              hovered: Int? = nil, pressed: Int? = nil, light: Bool = false, lifted: Bool = false,
                              nearTop: Bool = false) -> Scene {
        Scene(name: name, size: stage, backdrop: true) {
            let m = CameraBubbleModel(shape: shape, size: size)
            m.toolbarVisible = toolbar
            m.hovering = toolbar
            m.lifted = lifted
            m.toolbarAbove = !nearTop
            return AnyView(BubbleStage(model: m, bubble: place(shape, size, nearTop: nearTop), light: light,
                                       hovered: hovered, pressed: pressed))
        }
    }

    // MARK: Animation frames

    private struct Sequence {
        let name: String
        let from: (CameraLayout.Shape, CameraBubbleSize)
        let to: (CameraLayout.Shape, CameraBubbleSize)
        let style: BubbleSpring.Style
    }

    private static let tolerance = [0.2, 0.2, 0.2, 0.2, 0.002, 0.01]

    private static func vector(_ shape: CameraLayout.Shape, _ r: CGRect) -> [Double] {
        let c = CameraBubbleCorner(shape)
        return [r.minX, r.minY, r.width, r.height, c.radius, c.exponent]
    }

    private static func animationScenes() -> [Scene] {
        let sequences = [
            Sequence(name: "morph-circle-portrait", from: (.circle, .medium), to: (.portrait, .medium), style: BubbleSpring.morph),
            Sequence(name: "morph-portrait-square", from: (.portrait, .medium), to: (.roundedSquare, .medium), style: BubbleSpring.morph),
            Sequence(name: "resize-m-l", from: (.circle, .medium), to: (.circle, .large), style: BubbleSpring.resize),
            Sequence(name: "resize-l-s", from: (.circle, .large), to: (.circle, .small), style: BubbleSpring.resize),
        ]
        var out: [Scene] = []
        let room = CGRect(origin: .zero, size: stage).insetBy(dx: 8, dy: 8)
        for seq in sequences {
            let start = place(seq.from.0, seq.from.1)
            // The same growth rule as the app (stage coordinates are flipped, which the thirds rule doesn't mind).
            let end = BubbleLayout.resized(start, to: seq.to.1.size(seq.to.0), in: room)
            let frames = BubbleSpring.frames(from: vector(seq.from.0, start), to: vector(seq.to.0, end), style: seq.style, tolerance: tolerance)
            for (i, v) in frames.enumerated() {
                out.append(Scene(name: "camera-anim-\(seq.name)-\(String(format: "%02d", i))", size: stage, backdrop: true, build: {
                    AnyView(frameStage(v, shape: seq.to.0, size: seq.to.1))
                }, lightOnly: true))
            }
            out.append(sheet("camera-anim-\(seq.name)-sheet", frames: frames.map { v in AnyView(frameStage(v, shape: seq.to.0, size: seq.to.1)) }))
        }
        // Appear: scale and fade on the same spring as the app (response 0.38, damping 0.78).
        let presence = BubbleSpring.frames(from: [0], to: [1], style: .init(response: 0.38, damping: 0.78), tolerance: [0.002])
        var appear: [AnyView] = []
        for (i, v) in presence.enumerated() {
            let view = AnyView(presenceStage(v[0]))
            appear.append(view)
            out.append(Scene(name: "camera-anim-appear-\(String(format: "%02d", i))", size: stage, backdrop: true, build: { view }, lightOnly: true))
        }
        out.append(sheet("camera-anim-appear-sheet", frames: appear))
        return out
    }

    private static func frameStage(_ v: [Double], shape: CameraLayout.Shape, size: CameraBubbleSize) -> some View {
        let m = CameraBubbleModel(shape: shape, size: size)
        m.corner = CameraBubbleCorner(radius: v[4], exponent: v[5])
        m.toolbarVisible = true
        m.hovering = true
        return BubbleStage(model: m, bubble: CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))
    }

    private static func presenceStage(_ p: Double) -> some View {
        let m = CameraBubbleModel(shape: .circle, size: .medium)
        m.presence = p
        return BubbleStage(model: m, bubble: place(.circle, .medium))
    }

    /// Every other frame, small, in rows of six, numbered.
    private static func sheet(_ name: String, frames: [AnyView]) -> Scene {
        let picked = frames.enumerated().filter { $0.offset % 2 == 0 || $0.offset == frames.count - 1 }
        let scale: CGFloat = 0.3, cols = 6
        let cell = CGSize(width: stage.width * scale, height: stage.height * scale)
        let rows = (picked.count + cols - 1) / cols
        let size = CGSize(width: CGFloat(cols) * (cell.width + 6) + 6, height: CGFloat(rows) * (cell.height + 22) + 6)
        return Scene(name: name, size: size, backdrop: false, build: {
            AnyView(
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(0..<rows, id: \.self) { r in
                        HStack(spacing: 6) {
                            ForEach(Array(picked[(r * cols)..<min(picked.count, (r + 1) * cols)]), id: \.offset) { item in
                                VStack(spacing: 2) {
                                    ZStack { SheetBackdrop(); item.element }
                                        .frame(width: stage.width, height: stage.height)
                                        .scaleEffect(scale)
                                        .frame(width: cell.width, height: cell.height)
                                        .clipped()
                                    Text("\(item.offset)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)))
        }, lightOnly: true)
    }
}

/// A plain desktop for contact sheets.
private struct SheetBackdrop: View {
    var body: some View {
        LinearGradient(colors: [Color(nsColor: NSColor(hex: 0x8DA3B8)), Color(nsColor: NSColor(hex: 0x52677D))], startPoint: .top, endPoint: .bottom)
    }
}

/// The bubble and its toolbar laid out as the two panels sit on screen (stage coordinates, top-left origin).
private struct BubbleStage: View {
    let model: CameraBubbleModel
    let bubble: CGRect
    var light = false
    var hovered: Int? = nil
    var pressed: Int? = nil

    var body: some View {
        let p = CameraBubbleController.padding
        let camera = MockCameraView(frame: .zero)
        camera.light = light
        let tw = CameraBubbleToolbar.width, th = CameraBubbleToolbar.height
        let gap = CameraBubbleController.toolbarGap
        let ty = model.toolbarAbove ? bubble.minY - gap - th : bubble.maxY + gap
        return ZStack(alignment: .topLeading) {
            CameraBubbleView(camera: camera, model: model)
                .frame(width: bubble.width + 2 * p, height: bubble.height + 2 * p)
                // The panel's own fade (window alpha in the app).
                .compositingGroup()
                .opacity(min(1, max(0, model.presence)))
                .offset(x: bubble.minX - p, y: bubble.minY - p)
            // Kept on the stage sideways, as the app keeps it on screen.
            CameraBubbleToolbar(model: model, hovered: hovered, pressed: pressed)
                .offset(x: min(max(bubble.midX - tw / 2, 4), CameraBubbleScenes.stage.width - 4 - tw), y: ty)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
