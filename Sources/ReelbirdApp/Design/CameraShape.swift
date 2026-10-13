import ReelbirdCore
import SwiftUI

/// The camera bubble's outline, from the same geometry the Metal renderer masks with
/// (`CameraPlacement.outline`), so the live bubble, the editor and the video agree.
struct CameraBubbleShape: Shape {
    var shape: CameraLayout.Shape

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        let pts = CameraPlacement.outline(shape: shape, width: rect.width, height: rect.height, perCorner: 28)
        var p = Path()
        p.addLines(pts.map { CGPoint(x: rect.minX + $0.x, y: rect.minY + $0.y) })
        p.closeSubpath()
        return p
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
