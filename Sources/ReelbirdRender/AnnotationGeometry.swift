import CoreGraphics
import CoreText
import Foundation
import ReelbirdCore

extension RenderPlan {
    /// Where full-screen normalized coordinates land on a `width` × `height` canvas at recording time `t`
    /// (crop, padding, card aspect and the zoom camera). Drawing overlays with it lines them up exactly with
    /// what the compositor draws.
    public func screenMapping(atSource t: Double, width: Double, height: Double) -> ScreenMapping {
        let layout = CanvasLayout(plan: self, width: width, height: height, layout: layoutState(at: t))
        let (s, raw) = camera.transform(at: t)
        return layout.screenMapping(scale: s, center: layout.fillCenter(scale: s, center: raw), crop: crop)
    }
}

extension CanvasLayout {
    /// `map(crop.toView(p), scale, center)` as one affine map per axis.
    func screenMapping(scale s: Double, center c: NormPoint, crop: CropSpace) -> ScreenMapping {
        let r = crop.rect
        let kx = card.width * s / base.x, ky = card.height * s / base.y
        return ScreenMapping(originX: card.minX + card.width / 2 - kx * c.x - kx * r.x / r.width,
                             originY: card.minY + card.height / 2 - ky * c.y - ky * r.y / r.height,
                             scaleX: kx / r.width, scaleY: ky / r.height)
    }
}

/// Text annotation labels: a rounded label in the annotation's colour with white (or ink, on light colours)
/// semibold text. The editor sizes a text annotation's `rect` with `labelSize` so its handles match the label.
public enum AnnotationLabel {
    /// Size in pixels of the label for `text` at `fontPixels` (the same layout the compositor draws).
    public static func labelSize(text: String, fontPixels: Double) -> CGSize {
        let size = TextCache.labelSize(text: text.isEmpty ? " " : text, fontSize: max(4, fontPixels), weight: 600, pill: true, maxWidth: 0)
        return CGSize(width: size.width, height: size.height)
    }

    /// Whether the label's text is dark (on light colours such as Sun or White).
    public static func usesDarkText(on c: RGBA) -> Bool {
        0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b > 0.62
    }

    static func textColor(on c: RGBA) -> UInt32 { usesDarkText(on: c) ? 0x1A1512FF : 0xFFFFFFFF }
}
