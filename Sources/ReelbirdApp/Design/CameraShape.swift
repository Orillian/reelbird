import ReelbirdCore
import SwiftUI

/// The camera bubble's outline, from the same geometry the Metal renderer masks with
/// (`CameraPlacement.outline`), so the live bubble, the editor and the video agree.
struct CameraBubbleShape: Shape {
    /// Corner radius as a share of the shorter side (0.5 = fully round) and the superellipse exponent.
    var corner: CameraBubbleCorner

    init(shape: CameraLayout.Shape) { corner = CameraBubbleCorner(shape) }
    init(corner: CameraBubbleCorner) { self.corner = corner }

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(corner.radius, corner.exponent) }
        set { corner = CameraBubbleCorner(radius: newValue.first, exponent: newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        let pts = CameraPlacement.outline(width: rect.width, height: rect.height, radius: corner.radius * min(rect.width, rect.height),
                                          exponent: corner.exponent, perCorner: 28)
        var p = Path()
        p.addLines(pts.map { CGPoint(x: rect.minX + $0.x, y: rect.minY + $0.y) })
        p.closeSubpath()
        return p
    }
}

/// A bubble's corner, independent of its size: what the live bubble morphs between shapes.
struct CameraBubbleCorner: Hashable {
    var radius: Double
    var exponent: Double

    init(radius: Double, exponent: Double) { self.radius = radius; self.exponent = exponent }

    /// The renderer's corner for a shape (`CameraPlacement.corner`), as a share of the shorter side.
    init(_ shape: CameraLayout.Shape) {
        let c = CameraPlacement.corner(shape: shape, width: 1, height: 1)
        self.init(radius: c.radius, exponent: c.exponent)
    }
}

extension CameraLayout.Shape {
    var title: String {
        switch self {
        case .circle: "Circle"
        case .roundedSquare: "Square"
        case .portrait: "Portrait"
        }
    }

    /// A small icon size that keeps the shape's proportions.
    var glyphSize: CGSize { self == .portrait ? CGSize(width: 9, height: 12) : CGSize(width: 11, height: 11) }
}

/// A shape icon for pickers.
struct CameraShapeGlyph: View {
    let shape: CameraLayout.Shape
    var filled = false
    var scale: CGFloat = 1

    var body: some View {
        let s = shape.glyphSize
        Group {
            if filled {
                CameraBubbleShape(shape: shape).fill(.primary)
            } else {
                CameraBubbleShape(shape: shape).stroke(.primary, lineWidth: 1.4)
            }
        }
        .frame(width: s.width * scale, height: s.height * scale)
        .accessibilityHidden(true)
    }
}
