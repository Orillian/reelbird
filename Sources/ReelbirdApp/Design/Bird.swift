import AppKit
import SwiftUI

/// The Reelbird mascot: a plump little bird drawn from simple geometry in a 100×100 box.
/// Used sparingly: onboarding, empty states, the menu bar glyph.
enum BirdGeometry {
    static func body() -> CGPath {
        let p = CGMutablePath()
        p.addEllipse(in: CGRect(x: 18, y: 28, width: 62, height: 58))
        p.addEllipse(in: CGRect(x: 44, y: 18, width: 36, height: 36))
        return p
    }

    static func tail() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 28, y: 50))
        p.addCurve(to: CGPoint(x: 3, y: 36), control1: CGPoint(x: 20, y: 44), control2: CGPoint(x: 10, y: 36))
        p.addCurve(to: CGPoint(x: 9, y: 54), control1: CGPoint(x: 4, y: 44), control2: CGPoint(x: 6, y: 50))
        p.addCurve(to: CGPoint(x: 4, y: 64), control1: CGPoint(x: 7, y: 58), control2: CGPoint(x: 5, y: 61))
        p.addCurve(to: CGPoint(x: 30, y: 68), control1: CGPoint(x: 14, y: 68), control2: CGPoint(x: 22, y: 70))
        p.closeSubpath()
        return p
    }

    static func beak() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 77, y: 31))
        p.addQuadCurve(to: CGPoint(x: 94, y: 37), control: CGPoint(x: 88, y: 31))
        p.addQuadCurve(to: CGPoint(x: 77, y: 42), control: CGPoint(x: 88, y: 41))
        p.closeSubpath()
        return p
    }

    static func wing() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 26, y: 54))
        p.addCurve(to: CGPoint(x: 62, y: 58), control1: CGPoint(x: 36, y: 42), control2: CGPoint(x: 56, y: 44))
        p.addCurve(to: CGPoint(x: 32, y: 76), control1: CGPoint(x: 64, y: 70), control2: CGPoint(x: 46, y: 78))
        p.addCurve(to: CGPoint(x: 26, y: 54), control1: CGPoint(x: 26, y: 72), control2: CGPoint(x: 23, y: 62))
        p.closeSubpath()
        return p
    }

    static func belly() -> CGPath {
        CGPath(ellipseIn: CGRect(x: 50, y: 46, width: 34, height: 38), transform: nil)
    }

    static let eye = CGRect(x: 63.5, y: 30, width: 6.5, height: 6.5)

    static func legs() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 44, y: 85)); p.addLine(to: CGPoint(x: 42, y: 95))
        p.move(to: CGPoint(x: 56, y: 85)); p.addLine(to: CGPoint(x: 57, y: 95))
        return p
    }
}

struct BirdMascot: View {
    var size: CGFloat = 96
    /// Tilt the head as if looking up (onboarding success).
    var cheer = false

    var body: some View {
        Canvas { ctx, sz in
            let s = sz.width / 100
            ctx.scaleBy(x: s, y: s)
            let bodyColor = Color(nsColor: NSColor(hex: 0xE8653D))
            let wingColor = Color(nsColor: NSColor(hex: 0xC54A28))
            let bellyColor = Color(nsColor: NSColor(hex: 0xF8CB92))
            let beakColor = Color(nsColor: NSColor(hex: 0xF2A23A))
            let ink = Color(nsColor: NSColor(hex: 0x1C1A19))

            ctx.stroke(Path(BirdGeometry.legs()), with: .color(ink.opacity(0.85)), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
            ctx.fill(Path(BirdGeometry.tail()), with: .color(wingColor))
            ctx.fill(Path(BirdGeometry.body()), with: .color(bodyColor))
            var clipped = ctx
            clipped.clip(to: Path(BirdGeometry.body()))
            clipped.fill(Path(BirdGeometry.belly()), with: .color(bellyColor))
            ctx.fill(Path(BirdGeometry.wing()), with: .color(wingColor))
            ctx.fill(Path(BirdGeometry.beak()), with: .color(beakColor))
            ctx.fill(Path(ellipseIn: BirdGeometry.eye), with: .color(ink))
            ctx.fill(Path(ellipseIn: CGRect(x: 66.6, y: 31.2, width: 1.9, height: 1.9)), with: .color(.white))
            if cheer {
                ctx.fill(Path(ellipseIn: CGRect(x: 66, y: 41, width: 7, height: 4)), with: .color(Color.pink.opacity(0.35)))
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(cheer ? -6 : 0))
        .accessibilityLabel("Reelbird")
    }
}

extension NSImage {
    /// Template silhouette of the mascot for the menu bar (18 pt), with the eye cut out.
    /// `recording` adds a small dot at the top right.
    static func birdGlyph(recording: Bool = false, pointSize: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: pointSize + (recording ? 6 : 0), height: pointSize), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            let s = pointSize / 100
            ctx.translateBy(x: 0, y: pointSize * 0.02)
            ctx.scaleBy(x: s, y: s)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(BirdGeometry.tail()); ctx.fillPath()
            ctx.addPath(BirdGeometry.body()); ctx.fillPath()
            ctx.addPath(BirdGeometry.beak()); ctx.fillPath()
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(6); ctx.setLineCap(.round)
            ctx.addPath(BirdGeometry.legs()); ctx.strokePath()
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: BirdGeometry.eye.insetBy(dx: -1.2, dy: -1.2))
            // A soft wing line so the glyph reads as a bird, not a blob.
            ctx.setLineWidth(5)
            ctx.addPath(BirdGeometry.wing()); ctx.strokePath()
            ctx.restoreGState()
            if recording {
                ctx.setBlendMode(.normal)
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fillEllipse(in: CGRect(x: pointSize - 1, y: 1, width: 6, height: 6))
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Reelbird"
        return img
    }
}
