import CoreGraphics
import Foundation
import ImageIO
import ReelbirdCore
import UniformTypeIdentifiers

/// Still images for a guide's steps: the screen as the video shows it (crop, blurs and drawn overlays) at the
/// moment just before each action, without zoom, camera, background, captions, keystrokes or the cursor, so the
/// page can mark the click itself.
public enum StepImages {
    /// The edit the step images render with.
    public static func guideEdit(_ edit: EditDocument) -> EditDocument {
        var g = edit
        g.zoom.mode = .off
        g.camera.visible = false
        g.layouts = []
        g.background.kind = .none
        g.background.padding = 0
        g.background.cornerRadius = 0
        g.background.shadow = 0
        g.background.motionBlur = false
        g.captions.burnIn = false
        g.cursor.visible = false
        g.cursor.showKeystrokes = false
        g.cursor.showTypedText = false
        g.canvas.aspect = .source
        g.canvas.outputHeight = nil
        return g
    }

    /// One image per step, in order, at most `maxWidth` pixels wide. A step whose moment is no longer in the
    /// video (cut since the scan) shows the nearest kept frame.
    public static func render(bundle: ProjectBundle, edit: EditDocument, steps: [GuideStep], maxWidth: Int = 1600,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [CGImage] {
        guard !steps.isEmpty else { return [] }
        let manifest = try bundle.readManifest()
        let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: guideEdit(edit))
        let sources = try await MediaSources.load(bundle: bundle, manifest: manifest)
        var out: [CGImage] = []
        for (i, s) in steps.enumerated() {
            try Task.checkCancellation()
            let t = plan.timeline.outputTime(forSource: s.imageTime) ?? plan.timeline.nearestOutputTime(forSource: s.imageTime)
            out.append(try await Thumbnailer.render(plan: plan, sources: sources, at: t, maxWidth: maxWidth))
            progress(Double(i + 1) / Double(steps.count))
        }
        return out
    }

    /// The image with the click marked for exports that can't overlay it (Markdown, skills): a coral ring at
    /// `point` (or around `box`) with a soft halo.
    public static func marked(_ image: CGImage, point: NormPoint?, box: NormRect?) -> CGImage {
        guard point != nil || box != nil,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        let W = CGFloat(image.width), H = CGFloat(image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
        // CoreGraphics has a bottom-left origin.
        let coral = CGColor(srgbRed: 1, green: 0.353, blue: 0.212, alpha: 1)
        let unit = max(W, H) / 1600
        let line = max(2, 4 * unit)
        if let p = point {
            let r = max(14, 26 * unit)
            let c = CGPoint(x: CGFloat(p.x) * W, y: (1 - CGFloat(p.y)) * H)
            ctx.setFillColor(coral.copy(alpha: 0.18) ?? coral)
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.setStrokeColor(coral)
            ctx.setLineWidth(line)
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        } else if let b = box {
            let pad = 6 * unit
            let rect = CGRect(x: CGFloat(b.x) * W - pad, y: (1 - CGFloat(b.y + b.height)) * H - pad,
                              width: CGFloat(b.width) * W + pad * 2, height: CGFloat(b.height) * H + pad * 2)
            ctx.setStrokeColor(coral)
            ctx.setLineWidth(line)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 6 * unit, cornerHeight: 6 * unit, transform: nil))
            ctx.strokePath()
        }
        return ctx.makeImage() ?? image
    }

    /// JPEG bytes (sRGB), or `nil` when encoding fails.
    public static func jpeg(_ image: CGImage, quality: Double = 0.84) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
