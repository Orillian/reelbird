import CoreGraphics
import Foundation

/// Where full-screen normalized coordinates land on the output canvas at one moment: the crop, padding, card
/// aspect and the zoom camera folded into one affine map per axis (`px = origin + p · scale`). The editor uses it
/// to draw overlay handles on the preview and to turn drags back into screen coordinates.
public struct ScreenMapping: Hashable, Sendable {
    public var originX: Double
    public var originY: Double
    public var scaleX: Double
    public var scaleY: Double

    public init(originX: Double, originY: Double, scaleX: Double, scaleY: Double) {
        self.originX = originX; self.originY = originY; self.scaleX = scaleX; self.scaleY = scaleY
    }

    /// Canvas point for a normalized screen point.
    public func point(_ p: NormPoint) -> CGPoint {
        CGPoint(x: originX + p.x * scaleX, y: originY + p.y * scaleY)
    }

    /// Canvas rectangle for a normalized screen rectangle.
    public func rect(_ r: NormRect) -> CGRect {
        CGRect(x: originX + r.x * scaleX, y: originY + r.y * scaleY, width: r.width * scaleX, height: r.height * scaleY)
    }

    /// Normalized screen point under a canvas point.
    public func screenPoint(_ p: CGPoint) -> NormPoint {
        NormPoint(x: scaleX != 0 ? (Double(p.x) - originX) / scaleX : 0, y: scaleY != 0 ? (Double(p.y) - originY) / scaleY : 0)
    }

    /// Normalized screen rectangle under a canvas rectangle.
    public func screenRect(_ r: CGRect) -> NormRect {
        let a = screenPoint(CGPoint(x: r.minX, y: r.minY)), b = screenPoint(CGPoint(x: r.maxX, y: r.maxY))
        return NormRect.spanning(a, b)
    }

    /// The same map with the canvas moved by (`dx`, `dy`) (e.g. into a view where the canvas is letterboxed).
    public func offsetBy(dx: Double, dy: Double) -> ScreenMapping {
        ScreenMapping(originX: originX + dx, originY: originY + dy, scaleX: scaleX, scaleY: scaleY)
    }

    /// Screen-video pixels per canvas point along x (how far one canvas point reaches into the screen video).
    public func screenPixelsPerPoint(screenWidth: Int) -> Double { scaleX != 0 ? Double(screenWidth) / abs(scaleX) : 1 }
}
