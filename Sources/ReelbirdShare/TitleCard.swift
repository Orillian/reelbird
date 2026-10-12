import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Images for link previews: a 1200×630 title card, and JPEG encoding for posters.
enum TitleCard {
    static let size = CGSize(width: 1200, height: 630)

    /// A title card in the viewer page's palette: ink background, amber mark, title, wordmark.
    static func jpeg(title: String) -> Data? {
        let w = Int(size.width), h = Int(size.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        // Background: warm ink with a faint amber light from the top-left.
        ctx.setFillColor(CGColor(srgbRed: 0.075, green: 0.067, blue: 0.059, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        if let glow = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 1, green: 0.55, blue: 0.24, alpha: 0.16),
            CGColor(srgbRed: 1, green: 0.55, blue: 0.24, alpha: 0),
        ] as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 120, y: CGFloat(h) - 80), startRadius: 0,
                                   endCenter: CGPoint(x: 120, y: CGFloat(h) - 80), endRadius: 760, options: [])
        }

        // Play mark.
        let mark = CGRect(x: 88, y: CGFloat(h) - 88 - 72, width: 72, height: 72)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.553, blue: 0.290, alpha: 1))
        ctx.fillEllipse(in: mark)
        ctx.setFillColor(CGColor(srgbRed: 0.075, green: 0.067, blue: 0.059, alpha: 1))
        ctx.beginPath()
        ctx.move(to: CGPoint(x: mark.minX + 29, y: mark.minY + 21))
        ctx.addLine(to: CGPoint(x: mark.minX + 29, y: mark.maxY - 21))
        ctx.addLine(to: CGPoint(x: mark.minX + 53, y: mark.midY))
        ctx.closePath()
        ctx.fillPath()

        // Title, up to three lines.
        let titleFont = CTFontCreateUIFontForLanguage(.system, 68, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 68, nil)
        let bold = CTFontCreateCopyWithSymbolicTraits(titleFont, 68, nil, .traitBold, .traitBold) ?? titleFont
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): bold,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0.98, green: 0.96, blue: 0.93, alpha: 1),
        ]
        let text = title.isEmpty ? "Untitled recording" : title
        let framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let box = CGRect(x: 88, y: 150, width: CGFloat(w) - 176, height: 250)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: box, transform: nil), nil)
        let lines = (CTFrameGetLines(frame) as? [CTLine]) ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let shown = min(3, lines.count)
        for i in 0..<shown {
            var line = lines[i]
            if i == shown - 1, lines.count > shown {
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
                line = CTLineCreateTruncatedLine(line, Double(box.width), .end, ellipsis) ?? line
            }
            ctx.textPosition = CGPoint(x: box.minX + origins[i].x, y: box.minY + origins[i].y)
            CTLineDraw(line, ctx)
        }

        // Wordmark.
        let small = CTFontCreateUIFontForLanguage(.system, 28, nil) ?? titleFont
        let smallBold = CTFontCreateCopyWithSymbolicTraits(small, 28, nil, .traitBold, .traitBold) ?? small
        let word = CTLineCreateWithAttributedString(NSAttributedString(string: "Reelbird", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): smallBold,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0.98, green: 0.96, blue: 0.93, alpha: 0.55),
        ]))
        ctx.textPosition = CGPoint(x: 88, y: 76)
        CTLineDraw(word, ctx)

        guard let image = ctx.makeImage() else { return nil }
        return jpeg(image, quality: 0.86)
    }

    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
