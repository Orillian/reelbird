import AppKit
import ReelbirdCore
import ReelbirdRender

// The stand-in preview's overlays (snapshots, `--mock`): the same placement as the renderer's, drawn with
// Core Graphics. Blurs average the mock screen into cells of `PrivacyBlur.cellPixels`.
extension MockPreviewView {
    /// The mock's own geometry (see `draw`) as a screen mapping on a `width` × `height` canvas.
    func screenMapping(at t: Double, width W: Double, height H: Double) -> ScreenMapping {
        let short = min(W, H)
        let bg = edit.background
        let pad = bg.kind == .none ? 0 : short * bg.padding
        let avail = CGRect(x: 0, y: 0, width: W, height: H).insetBy(dx: pad, dy: pad)
        var screen = avail
        let sa = visibleAspect
        if avail.width / avail.height > sa {
            screen.size.width = avail.height * sa
            screen.origin.x = avail.midX - screen.width / 2
        } else {
            screen.size.height = avail.width / sa
            screen.origin.y = avail.midY - screen.height / 2
        }
        let c = crop.rect
        let full = CGRect(x: screen.minX - c.x * screen.width / c.width, y: screen.minY - c.y * screen.height / c.height,
                          width: screen.width / c.width, height: screen.height / c.height)
        let (scale, focus) = zoomState(at: t)
        guard scale > 1.001 else {
            return ScreenMapping(originX: full.minX, originY: full.minY, scaleX: full.width, scaleY: full.height)
        }
        let px = screen.minX + screen.width * focus.x, py = screen.minY + screen.height * focus.y
        let halfW = W / 2 / scale, halfH = H / 2 / scale
        let cx = min(max(px, halfW), W - halfW), cy = min(max(py, halfH), H - halfH)
        return ScreenMapping(originX: W / 2 + scale * (full.minX - cx), originY: H / 2 + scale * (full.minY - cy),
                             scaleX: scale * full.width, scaleY: scale * full.height)
    }

    /// Draws the overlays at `sourceTime`, in un-zoomed view coordinates (`full` = the whole screen image).
    func drawOverlays(_ ctx: CGContext, full: CGRect, screen: CGRect, short: CGFloat, image: CGImage?) {
        let t = sourceTime
        let visible = edit.annotations.filter { $0.range.contains(t) }
        let ordered = visible.filter { $0.kind == .highlight } + visible.filter { $0.kind == .blur }
            + visible.filter { $0.kind != .highlight && $0.kind != .blur }
        func rect(_ n: NormRect) -> CGRect {
            CGRect(x: full.minX + n.x * full.width, y: full.minY + n.y * full.height, width: n.width * full.width, height: n.height * full.height)
        }
        func point(_ p: NormPoint) -> CGPoint { CGPoint(x: full.minX + p.x * full.width, y: full.minY + p.y * full.height) }
        func color(_ c: RGBA, _ a: Double = 1) -> CGColor { CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a * a) }
        for a in ordered {
            let r = rect(a.rect(at: t))
            switch a.kind {
            case .highlight:
                ctx.saveGState()
                let path = CGMutablePath()
                path.addRect(full.insetBy(dx: -full.width, dy: -full.height))
                path.addPath(CGPath(roundedRect: r, cornerWidth: short * 0.01, cornerHeight: short * 0.01, transform: nil))
                ctx.addPath(path)
                ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
                ctx.fillPath(using: .evenOdd)
                ctx.restoreGState()
            case .blur:
                guard let image else { continue }
                ctx.saveGState()
                ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 0, cornerHeight: 0, transform: nil))
                ctx.clip()
                switch a.blurShape {
                case .rectangle: ctx.addRect(r)
                case .rounded: ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(r.width, r.height) * 0.1, cornerHeight: min(r.width, r.height) * 0.1, transform: nil))
                case .oval: ctx.addEllipse(in: r)
                }
                ctx.clip()
                if a.blurStyle == .solid {
                    ctx.setFillColor(color(a.color))
                    ctx.fill(r)
                    ctx.restoreGState()
                    continue
                }
                let ref = a.blurReferenceRect
                let screenPx = Double(max(1, sourceSize.width))
                let cellPx = PrivacyBlur.cellPixels(shortSidePixels: min(ref.width * screenPx, ref.height * Double(sourceSize.height)),
                                                    strength: a.blurStrength, captureScale: 2)
                let cellView = cellPx / screenPx * full.width
                let sx = Double(image.width) / full.width
                let src = CGRect(x: (r.minX - full.minX) * sx, y: (r.minY - full.minY) * sx, width: r.width * sx, height: r.height * sx).integral
                let cols = max(1, Int((r.width / cellView).rounded(.up))), rows = max(1, Int((r.height / cellView).rounded(.up)))
                if let piece = image.cropping(to: src),
                   let tiny = CGContext(data: nil, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: cols * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    tiny.interpolationQuality = .medium
                    tiny.draw(piece, in: CGRect(x: 0, y: 0, width: cols, height: rows))
                    if let cells = tiny.makeImage() {
                        ctx.interpolationQuality = a.blurStyle == .pixelate ? .none : .high
                        ctx.translateBy(x: r.minX, y: r.minY + Double(rows) * cellView)
                        ctx.scaleBy(x: 1, y: -1)
                        ctx.draw(cells, in: CGRect(x: 0, y: 0, width: Double(cols) * cellView, height: Double(rows) * cellView))
                    }
                }
                ctx.restoreGState()
            case .box:
                let w = max(2, short * 0.0045)
                ctx.setStrokeColor(color(a.color))
                ctx.setLineWidth(w)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: short * 0.008, cornerHeight: short * 0.008, transform: nil))
                ctx.strokePath()
            case .arrow:
                let ends = a.arrowEnds
                let p0 = point(ends.tail), p1 = point(ends.head)
                let th = max(2, short * 0.006), head = th * 4.2
                let len = max(1, hypot(p1.x - p0.x, p1.y - p0.y))
                let d = CGPoint(x: (p1.x - p0.x) / len, y: (p1.y - p0.y) / len), n = CGPoint(x: -d.y, y: d.x)
                let shaftEnd = CGPoint(x: p1.x - d.x * head * 0.8, y: p1.y - d.y * head * 0.8)
                ctx.setStrokeColor(color(a.color)); ctx.setLineWidth(th); ctx.setLineCap(.round)
                ctx.move(to: p0); ctx.addLine(to: shaftEnd); ctx.strokePath()
                ctx.setFillColor(color(a.color))
                let base = CGPoint(x: p1.x - d.x * head, y: p1.y - d.y * head)
                ctx.move(to: p1)
                ctx.addLine(to: CGPoint(x: base.x + n.x * head * 0.6, y: base.y + n.y * head * 0.6))
                ctx.addLine(to: CGPoint(x: base.x - n.x * head * 0.6, y: base.y - n.y * head * 0.6))
                ctx.closePath(); ctx.fillPath()
            case .text:
                guard let str = a.text, !str.isEmpty else { continue }
                // Letters sized so the label fills the overlay's box, as the renderer's does.
                let unit = AnnotationLabel.labelSize(text: str, fontPixels: 100)
                let size = a.fontSize == nil ? a.textSize * full.height : max(4, r.height / max(1, unit.height) * 100)
                let label = AnnotationLabel.labelSize(text: str, fontPixels: size)
                let box = CGRect(x: r.minX, y: r.midY - label.height / 2, width: label.width, height: label.height)
                ctx.setFillColor(color(a.color))
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: min(box.height / 2, size * 0.9), cornerHeight: min(box.height / 2, size * 0.9), transform: nil))
                ctx.fillPath()
                let dark = AnnotationLabel.usesDarkText(on: a.color)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                    .foregroundColor: dark ? NSColor(hex: 0x1A1512) : NSColor.white,
                ]
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                NSAttributedString(string: str, attributes: attrs).draw(at: CGPoint(x: box.minX + size * 0.75 + 1, y: box.minY + size * 0.45 + 1))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
}
