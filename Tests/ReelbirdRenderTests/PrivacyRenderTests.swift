@preconcurrency import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import Vision
import ReelbirdCore
@testable import ReelbirdRender

// Privacy blur and annotations in the renderer: blurred text can't be read back (Vision OCR finds nothing),
// overlays sit where `screenMapping` says under zoom, crop, padding and aspect, and exports carry the blur.

/// A 2560 × 1440 (2× Retina) screen of dark text on paper.
private enum TextScreen {
    static let width = 2560, height = 1440
    struct Line { let text: String; let x: Double; let baseline: Double; let size: Double }
    static let lines = [
        Line(text: "Account email jane.doe@example.com", x: 200, baseline: 300, size: 26),
        Line(text: "API key sk-proj-Ab3dEf9GhJk2LmN0pQr5", x: 200, baseline: 420, size: 26),
        Line(text: "Quarterly revenue 4,812,113", x: 200, baseline: 620, size: 52),
        Line(text: "Session token 7Q4ZK9PLMX21", x: 200, baseline: 800, size: 18),
    ]
    /// The words OCR must not read back from a blurred line.
    static let secrets = ["jane.doe@example.com", "sk-proj-Ab3dEf9GhJk2LmN0pQr5", "4,812,113", "7Q4ZK9PLMX21"]

    static func ctLine(_ l: Line) -> CTLine {
        let font = CTFontCreateUIFontForLanguage(.system, l.size, nil)!
        let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.08, alpha: 1)]
        return CTLineCreateWithAttributedString(NSAttributedString(string: l.text, attributes: attrs))
    }

    /// The line's box, normalized, with a little margin (as Find Sensitive Info pads its boxes).
    static func rect(_ l: Line) -> NormRect {
        var a: CGFloat = 0, d: CGFloat = 0, lead: CGFloat = 0
        let w = CTLineGetTypographicBounds(ctLine(l), &a, &d, &lead)
        let pad = (a + d) * 0.3
        return NormRect(x: (l.x - pad) / Double(width), y: (l.baseline - a - pad) / Double(height),
                        width: (w + 2 * pad) / Double(width), height: (a + d + 2 * pad) / Double(height))
    }

    /// Luma (0...255) of the screen.
    static let luma: [UInt8] = {
        var px = [UInt8](repeating: 0, count: width * height)
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.setFillColor(CGColor(gray: 0.96, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            for l in lines { ctx.textPosition = CGPoint(x: l.x, y: l.baseline); CTLineDraw(ctLine(l), ctx) }
        }
        return px
    }()

    static let draw: Synthetic.Draw = { y, ys, uv, uvs, w, h, _ in
        let src = luma
        for r in 0..<h {
            let row = y + r * ys
            for c in 0..<w { row[c] = UInt8(16 + Int(src[r * width + c]) * 219 / 255) }
        }
        for r in 0..<(h / 2) { memset(uv + r * uvs, 128, w) }
    }

    static func bundle(seconds: Double = 3) async throws -> ProjectBundle {
        var o = Synthetic.Options()
        o.width = width; o.height = height; o.seconds = seconds; o.microphone = false; o.captureScale = 2
        o.screen = draw
        o.stillPointer = NormPoint(x: 0.9, y: 0.9)
        return try await Synthetic.makeBundle(o)
    }
}

private func plain(_ manifest: ProjectManifest) -> EditDocument {
    var e = EditDocument.initial(for: manifest)
    e.background.kind = .solid
    e.background.colors = [RGBA(hex: "#2050A0")!]
    e.background.padding = 0.06
    e.background.shadow = 0
    e.background.motionBlur = false
    e.zoom.mode = .off
    e.cursor.visible = false
    e.camera.visible = false
    return e
}

private func blur(_ r: NormRect, style: Annotation.BlurStyle, strength: Double = 0) -> Annotation {
    var a = Annotation(kind: .blur, range: TimeRange(start: 0, end: 10), rect: r)
    a.style = style
    a.strength = strength
    return a
}

/// Everything Vision reads inside `rect` (canvas pixels) of `image`. Vision blocks, so it runs off the cooperative
/// pool (see BlockingWork).
private func readText(_ image: CGImage, in rect: CGRect) async throws -> [String] {
    try await BlockingWork.run("test.vision") { _ in try readTextNow(image, in: rect) }
}

private func readTextNow(_ image: CGImage, in rect: CGRect) throws -> [String] {
    let r = rect.insetBy(dx: -rect.height * 0.3, dy: -rect.height * 0.3)
        .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
    guard !r.isEmpty, let crop = image.cropping(to: r) else { return [] }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
}

/// Whether any 4-character run of the secret's letters and digits shows up in what was read.
private func leaks(_ read: [String], _ secret: String) -> Bool {
    let s = Array(secret.lowercased().filter { $0.isLetter || $0.isNumber })
    let text = read.joined(separator: " ").lowercased().filter { $0.isLetter || $0.isNumber }
    guard s.count >= 4 else { return text.contains(String(s)) }
    for i in 0...(s.count - 4) where text.contains(String(s[i..<i + 4])) { return true }
    return false
}

private func render(_ bundle: ProjectBundle, _ edit: EditDocument, at t: Double) async throws -> (CGImage, RenderPlan) {
    let manifest = try bundle.readManifest()
    let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: edit)
    let sources = try await MediaSources.load(bundle: bundle, manifest: manifest)
    return (try await Thumbnailer.render(plan: plan, sources: sources, at: t, maxWidth: 4096), plan)
}

@Suite(.serialized) struct PrivacyRenderTests {

@Test func blurredTextCantBeReadBack() async throws {
    let bundle = try await TextScreen.bundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    let base = plain(manifest)
    let rects = TextScreen.lines.map(TextScreen.rect)

    // Control: without a blur, OCR reads every line at this size.
    let (clear, clearPlan) = try await render(bundle, base, at: 1)
    let m0 = clearPlan.screenMapping(atSource: 1, width: Double(clear.width), height: Double(clear.height))
    for (r, secret) in zip(rects, TextScreen.secrets) {
        let read = try await readText(clear, in: m0.rect(r))
        #expect(leaks(read, secret), "control: OCR should read \(secret), read \(read)")
    }

    for style in Annotation.BlurStyle.allCases {
        // The weakest strength, at zoom 1 and at a 3× zoom onto the blurred lines.
        var e = base
        e.annotations = rects.map { blur($0, style: style) }
        let (img, plan) = try await render(bundle, e, at: 1)
        let m = plan.screenMapping(atSource: 1, width: Double(img.width), height: Double(img.height))
        for (r, secret) in zip(rects, TextScreen.secrets) {
            let read = try await readText(img, in: m.rect(r))
            #expect(!leaks(read, secret), "\(style): \(secret) readable after blur: \(read)")
        }
        for (i, r) in rects.enumerated() {
            var z = e
            z.zoom.mode = .manual
            z.zoom.regions = [ZoomRegion(range: TimeRange(start: 0, end: 3), scale: 3, focus: r.center)]
            let (zimg, zplan) = try await render(bundle, z, at: 2)
            #expect(zplan.camera.transform(at: 2).scale > 2.7)
            let zm = zplan.screenMapping(atSource: 2, width: Double(zimg.width), height: Double(zimg.height))
            let read = try await readText(zimg, in: zm.rect(r))
            #expect(!leaks(read, TextScreen.secrets[i]), "\(style) at 3×: \(TextScreen.secrets[i]) readable: \(read)")
        }
    }
    // Zoomed control: the unblurred line is readable at 3×, so the zoomed checks above mean something.
    var zc = base
    zc.zoom.mode = .manual
    zc.zoom.regions = [ZoomRegion(range: TimeRange(start: 0, end: 3), scale: 3, focus: rects[3].center)]
    let (zclear, zcplan) = try await render(bundle, zc, at: 2)
    let read = try await readText(zclear, in: zcplan.screenMapping(atSource: 2, width: Double(zclear.width), height: Double(zclear.height)).rect(rects[3]))
    #expect(leaks(read, TextScreen.secrets[3]), "zoomed control read \(read)")
}

@Test func overlaysLandWhereScreenMappingSays() async throws {
    var o = Synthetic.Options()
    o.microphone = false
    o.stillPointer = NormPoint(x: 0.9, y: 0.9)
    let bundle = try await Synthetic.makeBundle(o)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    let box = NormRect(x: 0.3, y: 0.35, width: 0.3, height: 0.3)
    let green = RGBA(0, 1, 0)

    func check(_ name: String, at t: Double, _ configure: (inout EditDocument) -> Void) async throws {
        var e = plain(manifest)
        configure(&e)
        e.annotations = [Annotation(kind: .box, range: TimeRange(start: 0, end: 10), rect: box, color: green)]
        let (img, plan) = try await render(bundle, e, at: t)
        let px = Pixels(img)
        let W = Double(img.width), H = Double(img.height)
        let m = plan.screenMapping(atSource: t, width: W, height: H)
        // The mapping is the compositor's own placement (crop, card, zoom) in closed form.
        let layout = CanvasLayout(plan: plan, width: W, height: H, layout: plan.layoutState(at: t))
        let (s, raw) = plan.camera.transform(at: t)
        let c = layout.fillCenter(scale: s, center: raw)
        for p in [NormPoint(x: 0.1, y: 0.2), NormPoint(x: 0.73, y: 0.41), NormPoint(x: 0.5, y: 0.95)] {
            let a = m.point(p), b = layout.map(plan.crop.toView(p), scale: s, center: c)
            #expect(abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6, "\(name) mapping at \(p)")
        }
        // The box's stroke is on the mapped edges; inside it is the screen.
        let r = m.rect(box)
        func isGreen(_ x: Double, _ y: Double) -> Bool {
            let q = px[Int(x.rounded()), Int(y.rounded())]
            return q.g > 180 && q.r < 90 && q.b < 90
        }
        for (x, y) in [(r.minX, r.midY), (r.maxX, r.midY), (r.midX, r.minY), (r.midX, r.maxY)] where x > 2 && x < W - 2 && y > 2 && y < H - 2 {
            #expect(isGreen(x, y), "\(name): stroke at \(Int(x)),\(Int(y)) is \(px[Int(x), Int(y)])")
        }
        #expect(!isGreen(r.midX + r.width * 0.1, r.midY + r.height * 0.1), "\(name): inside the box")
    }

    try await check("padding", at: 1) { e in e.background.padding = 0.15 }
    try await check("zoom", at: 1.5) { e in
        e.zoom.mode = .manual
        e.zoom.regions = [ZoomRegion(range: TimeRange(start: 0, end: 3), scale: 1.6, focus: NormPoint(x: 0.45, y: 0.5))]
    }
    try await check("crop", at: 1) { e in e.crop = NormRect(x: 0.15, y: 0.2, width: 0.6, height: 0.7) }
    try await check("crop zoom vertical", at: 1.5) { e in
        e.crop = NormRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        e.canvas.aspect = .vertical
        e.zoom.mode = .manual
        e.zoom.regions = [ZoomRegion(range: TimeRange(start: 0, end: 3), scale: 1.4, focus: NormPoint(x: 0.45, y: 0.5))]
    }
    try await check("square no background", at: 1) { e in e.canvas.aspect = .square; e.background.kind = .none }
}

@Test func blurFollowsMovingKeysAndCellsHoldStill() async throws {
    let bundle = try await TextScreen.bundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    var e = plain(try bundle.readManifest())
    let a = TextScreen.rect(TextScreen.lines[0]), b = TextScreen.rect(TextScreen.lines[1])
    var moving = blur(a, style: .pixelate)
    moving.keys = [Annotation.Key(t: 0, rect: a), Annotation.Key(t: 1, rect: a), Annotation.Key(t: 2, rect: b), Annotation.Key(t: 3, rect: b)]
    moving.rect = a.union(b)
    e.annotations = [moving]
    // At 0.5 s only line 1 is hidden; at 2.5 s only line 2; at 1.5 s (between keys) both.
    for (t, hidden, shown) in [(0.5, [0], [1]), (2.5, [1], [0]), (1.5, [0, 1], [Int]())] {
        let (img, plan) = try await render(bundle, e, at: t)
        let m = plan.screenMapping(atSource: t, width: Double(img.width), height: Double(img.height))
        for i in hidden {
            let read = try await readText(img, in: m.rect(TextScreen.rect(TextScreen.lines[i])))
            #expect(!leaks(read, TextScreen.secrets[i]), "t \(t) line \(i)")
        }
        for i in shown {
            let read = try await readText(img, in: m.rect(TextScreen.rect(TextScreen.lines[i])))
            #expect(leaks(read, TextScreen.secrets[i]), "t \(t) line \(i) shown")
        }
    }
}

@Test func exportCarriesTheBlur() async throws {
    let bundle = try await TextScreen.bundle(seconds: 2)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    var e = plain(try bundle.readManifest())
    let hidden = TextScreen.rect(TextScreen.lines[1]), shown = TextScreen.rect(TextScreen.lines[0])
    e.annotations = [blur(hidden, style: .blur, strength: 0)]
    let url = try await Exporter.export(bundle: bundle, edit: e, options: ExportOptions(format: .mp4H264)) { _ in }
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    let frame = try await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
    let plan = try RenderPlan(bundle: bundle, manifest: try bundle.readManifest(), edit: e)
    let m = plan.screenMapping(atSource: 1, width: Double(frame.width), height: Double(frame.height))
    let hiddenRead = try await readText(frame, in: m.rect(hidden)), shownRead = try await readText(frame, in: m.rect(shown))
    #expect(!leaks(hiddenRead, TextScreen.secrets[1]))
    #expect(leaks(shownRead, TextScreen.secrets[0]), "the rest of the export stays readable")
}

/// Every overlay kind on one frame, for eyeballing: `RB_DUMP_DIR=/path scripts/test.sh --filter dumpOverlayFrames`.
@Test func dumpOverlayFrames() async throws {
    guard let dir = ProcessInfo.processInfo.environment["RB_DUMP_DIR"] else { return }
    let bundle = try await TextScreen.bundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    var e = EditDocument.initial(for: try bundle.readManifest())
    e.zoom.mode = .off
    e.cursor.visible = false
    let r = TextScreen.lines.map(TextScreen.rect)
    var arrow = Annotation(kind: .arrow, range: TimeRange(start: 0, end: 3), rect: .full)
    arrow.setArrow(tail: NormPoint(x: 0.78, y: 0.62), head: NormPoint(x: 0.6, y: 0.47))
    var text = Annotation(kind: .text, range: TimeRange(start: 0, end: 3), rect: NormRect(x: 0.62, y: 0.66, width: 0.2, height: 0.05), text: "Revenue is up")
    text.fontSize = 0.026
    var sun = Annotation(kind: .text, range: TimeRange(start: 0, end: 3), rect: NormRect(x: 0.62, y: 0.74, width: 0.2, height: 0.05), text: "Sun label",
                         color: RGBA(hex: "#FFB627")!)
    sun.fontSize = 0.022
    e.annotations = [blur(r[0], style: .blur, strength: 0.5), blur(r[1], style: .pixelate, strength: 0.5),
                     Annotation(kind: .box, range: TimeRange(start: 0, end: 3), rect: r[2].insetBy(dx: -0.01, dy: -0.01)),
                     arrow, text, sun,
                     Annotation(kind: .highlight, range: TimeRange(start: 0, end: 3), rect: r[3].insetBy(dx: -0.01, dy: -0.01))]
    let (img, _) = try await render(bundle, e, at: 1)
    let url = URL(fileURLWithPath: dir).appendingPathComponent("overlays.png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}
}
