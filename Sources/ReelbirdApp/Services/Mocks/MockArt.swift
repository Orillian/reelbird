import AppKit
import CoreGraphics

/// Draws stand-in screen content for mocks: a plausible app window, so thumbnails, the preview
/// and the filmstrip look like a real recording instead of grey boxes.
enum MockArt {
    enum Variant: Int, CaseIterable { case docs, code, browser, design, chat }

    /// Height of the `.browser` variant's title bar and toolbar (including its divider) for an image `width` wide.
    static func browserToolbarHeight(width: Double) -> Double { 7.8 * width / 100 }

    static func image(width: Int, height: Int, variant: Variant, dark: Bool = false, t: Double = 0) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        draw(in: ctx, rect: CGRect(x: 0, y: 0, width: width, height: height), variant: variant, dark: dark, t: t)
        return ctx.makeImage()
    }

    /// Draws into a top-left-origin context.
    static func draw(in ctx: CGContext, rect r: CGRect, variant: Variant, dark: Bool, t: Double) {
        let u = r.width / 100 // one unit = 1% of width
        let bg = dark ? NSColor(hex: 0x1F2023) : NSColor(hex: 0xF7F7F5)
        let side = dark ? NSColor(hex: 0x26272B) : NSColor(hex: 0xEEEDEA)
        let line = dark ? NSColor(white: 1, alpha: 0.13) : NSColor(white: 0, alpha: 0.09)
        let text = dark ? NSColor(white: 1, alpha: 0.55) : NSColor(white: 0, alpha: 0.42)
        let strong = dark ? NSColor(white: 1, alpha: 0.82) : NSColor(white: 0, alpha: 0.72)
        let appAccent = NSColor(hex: 0x4C6FA8)

        func fill(_ c: NSColor, _ rect: CGRect, radius: CGFloat = 0) {
            ctx.setFillColor(c.cgColor)
            if radius > 0 {
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.fillPath()
            } else { ctx.fill(rect) }
        }
        func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat = 1.1, _ c: NSColor? = nil) {
            fill(c ?? text, CGRect(x: r.minX + x * u, y: r.minY + y * u, width: w * u, height: h * u), radius: h * u / 2)
        }

        fill(bg, r)
        // Title bar
        fill(side, CGRect(x: r.minX, y: r.minY, width: r.width, height: 3.6 * u))
        for (i, c) in [NSColor(hex: 0xEE6A5F), NSColor(hex: 0xF5BE4F), NSColor(hex: 0x62C554)].enumerated() {
            ctx.setFillColor(c.cgColor)
            ctx.fillEllipse(in: CGRect(x: r.minX + (1.4 + Double(i) * 1.7) * u, y: r.minY + 1.15 * u, width: 1.2 * u, height: 1.2 * u))
        }
        ctx.setFillColor(line.cgColor)
        ctx.fill(CGRect(x: r.minX, y: r.minY + 3.6 * u, width: r.width, height: max(1, 0.08 * u)))

        let hu = r.height / u // height in units
        switch variant {
        case .docs, .chat:
            fill(side, CGRect(x: r.minX, y: r.minY + 3.7 * u, width: 20 * u, height: r.height))
            for i in 0..<9 {
                let y = 7.5 + Double(i) * 3.2
                if i == 2 { fill(appAccent.withAlphaComponent(0.16), CGRect(x: r.minX + 1.2 * u, y: r.minY + (y - 1.1) * u, width: 17.6 * u, height: 3 * u), radius: 0.6 * u) }
                bar(2.2, y, Double([11, 8, 13, 9, 12, 7, 10, 8, 11][i]), 1.0, i == 2 ? appAccent : text)
            }
            bar(26, 9, 30, 2.4, strong)
            bar(26, 14, 52, 1.1); bar(26, 17, 48, 1.1); bar(26, 20, 55, 1.1); bar(26, 23, 31, 1.1)
            fill(line, CGRect(x: r.minX + 26 * u, y: r.minY + 27 * u, width: 66 * u, height: max(1, 0.1 * u)))
            for row in 0..<3 {
                let y = 30.0 + Double(row) * 9
                fill(dark ? NSColor(white: 1, alpha: 0.05) : NSColor.white, CGRect(x: r.minX + 26 * u, y: r.minY + y * u, width: 66 * u, height: 7 * u), radius: 0.8 * u)
                ctx.setFillColor((row == 1 ? appAccent : text).withAlphaComponent(row == 1 ? 0.9 : 0.4).cgColor)
                ctx.fillEllipse(in: CGRect(x: r.minX + 28 * u, y: r.minY + (y + 2) * u, width: 3 * u, height: 3 * u))
                bar(33, y + 2.2, 24, 1.0, strong); bar(33, y + 4.2, 38, 0.9)
            }
            if hu > 60 { bar(26, 60, 50, 1.1); bar(26, 63, 44, 1.1) }
            fill(appAccent, CGRect(x: r.minX + 80 * u, y: r.minY + 8 * u, width: 12 * u, height: 3.4 * u), radius: 0.7 * u)
        case .code:
            fill(side, CGRect(x: r.minX, y: r.minY + 3.7 * u, width: 18 * u, height: r.height))
            for i in 0..<12 { bar(2 + (i % 3 == 0 ? 0 : 1.5), 7 + Double(i) * 2.6, Double([9, 7, 10, 6, 8, 11, 7, 9, 6, 8, 10, 7][i]), 0.9) }
            let colors = [NSColor(hex: 0xB0548F), NSColor(hex: 0x4C6FA8), NSColor(hex: 0x3F8F6B), text]
            for i in 0..<(Int(hu / 2.6) - 3) {
                let y = 7 + Double(i) * 2.4
                let indent = Double([0, 2, 2, 4, 4, 2, 0, 0, 2, 4, 6, 4, 2, 0][i % 14])
                bar(20.5, y, 1.6, 0.8, text.withAlphaComponent(0.25))
                bar(24 + indent, y, Double(6 + (i * 7) % 9), 0.9, colors[i % 4].withAlphaComponent(0.8))
                bar(24 + indent + Double(7 + (i * 7) % 9), y, Double(5 + (i * 5) % 14), 0.9, text)
            }
            // Blinking caret that moves with time, so motion is visible in the preview.
            let caretLine = Int(t * 1.5) % 10
            fill(appAccent, CGRect(x: r.minX + 46 * u, y: r.minY + (7 + Double(caretLine) * 2.4 - 0.4) * u, width: 0.25 * u, height: 1.7 * u))
        case .browser:
            fill(side, CGRect(x: r.minX, y: r.minY + 3.7 * u, width: r.width, height: 4 * u))
            fill(bg, CGRect(x: r.minX + 25 * u, y: r.minY + 4.4 * u, width: 50 * u, height: 2.6 * u), radius: 1.3 * u)
            bar(28, 5.2, 20, 1.0)
            ctx.setFillColor(line.cgColor)
            ctx.fill(CGRect(x: r.minX, y: r.minY + 7.7 * u, width: r.width, height: max(1, 0.08 * u)))
            bar(10, 14, 36, 3.2, strong); bar(10, 20, 44, 1.2); bar(10, 23, 40, 1.2)
            fill(appAccent, CGRect(x: r.minX + 10 * u, y: r.minY + 28 * u, width: 13 * u, height: 3.6 * u), radius: 1.8 * u)
            fill(dark ? NSColor(white: 1, alpha: 0.06) : NSColor(hex: 0xE7E9EE), CGRect(x: r.minX + 54 * u, y: r.minY + 12 * u, width: 36 * u, height: 24 * u), radius: 1.2 * u)
            for c in 0..<3 {
                let x = 10.0 + Double(c) * 27.5
                fill(dark ? NSColor(white: 1, alpha: 0.05) : NSColor.white, CGRect(x: r.minX + x * u, y: r.minY + 42 * u, width: 25 * u, height: 14 * u), radius: 1 * u)
                bar(x + 2, 45, 12, 1.2, strong); bar(x + 2, 48.5, 19, 0.9); bar(x + 2, 51, 15, 0.9)
            }
        case .design:
            fill(side, CGRect(x: r.minX, y: r.minY + 3.7 * u, width: 15 * u, height: r.height))
            fill(side, CGRect(x: r.maxX - 18 * u, y: r.minY + 3.7 * u, width: 18 * u, height: r.height))
            for i in 0..<8 { bar(1.8, 7 + Double(i) * 2.8, Double([9, 7, 10, 6, 8, 11, 7, 9][i]), 0.9) }
            for i in 0..<7 { bar(84, 7 + Double(i) * 3.4, Double([10, 6, 12, 8, 7, 11, 9][i]), 0.9) }
            fill(dark ? NSColor(hex: 0x2B2C30) : NSColor(hex: 0xE4E3E0), CGRect(x: r.minX + 15 * u, y: r.minY + 3.7 * u, width: 67 * u, height: r.height))
            let art = CGRect(x: r.minX + 26 * u, y: r.minY + 10 * u, width: 45 * u, height: min(30 * u, r.height - 14 * u))
            fill(dark ? NSColor(hex: 0x1F2023) : .white, art, radius: 0.6 * u)
            fill(appAccent.withAlphaComponent(0.85), CGRect(x: art.minX + 4 * u, y: art.minY + 4 * u, width: 14 * u, height: 14 * u), radius: 7 * u)
            bar(art.minX / u - r.minX / u + 22, art.minY / u - r.minY / u + 6, 16, 1.8, strong)
            bar(art.minX / u - r.minX / u + 22, art.minY / u - r.minY / u + 10, 18, 1.0)
            ctx.setStrokeColor(appAccent.cgColor); ctx.setLineWidth(max(1, 0.15 * u))
            ctx.stroke(art.insetBy(dx: -0.4 * u, dy: -0.4 * u))
        }
    }

    /// A smooth synthetic waveform for mocks, `count` values in 0...1.
    static func waveform(count: Int, seed: Int = 7) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(count)
        var phrase = 0.0
        for i in 0..<count {
            let x = Double(i) / Double(max(1, count))
            phrase = 0.5 + 0.5 * sin(x * 31 + Double(seed)) * sin(x * 7.3 + 1)
            let speaking = sin(x * 53 + Double(seed) * 0.7) > -0.55 ? 1.0 : 0.08
            let jitter = 0.55 + 0.45 * abs(sin(Double(i) * 12.9898 + Double(seed)) * 43758.5453).truncatingRemainder(dividingBy: 1)
            out.append(Float(min(1, max(0.03, phrase * speaking * jitter))))
        }
        return out
    }
}
