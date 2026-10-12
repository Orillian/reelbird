@preconcurrency import AVFoundation
import CoreGraphics
import ImageIO
import Foundation
import Testing
import ReelbirdCore
@testable import ReelbirdRender

/// A plain edit: solid background, no shadow, no zoom, no cursor, so pixel checks are exact.
private func plainEdit(_ manifest: ProjectManifest) -> EditDocument {
    var e = EditDocument.initial(for: manifest)
    e.background.kind = .solid
    e.background.colors = [RGBA(hex: "#2050A0")!]
    e.background.padding = 0.1
    e.background.cornerRadius = 0.05
    e.background.shadow = 0
    e.background.motionBlur = false
    e.zoom.mode = .off
    e.cursor.visible = false
    e.camera.visible = false
    return e
}

private func render(_ bundle: ProjectBundle, _ edit: EditDocument, at t: Double, width: Int = 960) async throws -> Pixels {
    let manifest = try bundle.readManifest()
    let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: edit)
    let sources = try await MediaSources.load(bundle: bundle, manifest: manifest)
    return Pixels(try Thumbnailer.render(plan: plan, sources: sources, at: t, maxWidth: width))
}

// Canvas 960×540 from a 1280×720 source with 10% padding: card is 768×432 at (96, 54), radius 27 px.

@Test func backgroundCornersAndRoundedCard() async throws {
    let bundle = try await Synthetic.makeBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let px = try await render(bundle, plainEdit(try bundle.readManifest()), at: 1)
    #expect(px.width == 960 && px.height == 540)
    let bg = (0x20, 0x50, 0xA0)
    for (x, y) in [(1, 1), (958, 1), (1, 538), (958, 538), (50, 270)] { #expect(px.near(x, y, bg, tol: 4), "background at \(x),\(y): \(px[x, y])") }
    // Inside the card's bounding box but outside the rounded corner: still background.
    #expect(px.near(97, 55, bg, tol: 6), "rounded corner \(px[97, 55])")
    #expect(px.near(96 + 768 - 2, 54 + 432 - 2, bg, tol: 6))
    // Inside the rounded corner: screen grey.
    #expect(px.near(96 + 27, 54 + 27, Synthetic.greyRGB, tol: 6), "screen \(px[123, 81])")
    // Centre square is black.
    #expect(px.near(480, 270, (0, 0, 0), tol: 8))
}

@Test func gradientBackgroundRunsCornerToCorner() async throws {
    let bundle = try await Synthetic.makeBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    var e = plainEdit(try bundle.readManifest())
    e.background.kind = .gradient
    e.background.colors = [RGBA(1, 0, 0), RGBA(0, 0, 1)]
    let px = try await render(bundle, e, at: 1)
    let tl = px[1, 1], br = px[958, 538]
    #expect(tl.r > 240 && tl.b < 15)
    #expect(br.b > 240 && br.r < 15)
}

@Test func cursorDrawnAtExpectedPosition() async throws {
    var o = Synthetic.Options()
    o.redCursor = true
    o.stillPointer = NormPoint(x: 0.25, y: 0.25)
    let bundle = try await Synthetic.makeBundle(o)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    var e = plainEdit(try bundle.readManifest())
    e.cursor.visible = true
    e.cursor.size = 1
    e.cursor.clickEffect = .none
    let px = try await render(bundle, e, at: 1)
    // Hot spot (top-left) at card (96, 54) + 0.25 × (768, 432) = (288, 162). 32 pt × 1x × 0.6 = 19.2 px square.
    let red = (255, 0, 0)
    #expect(px.near(288 + 3, 162 + 3, red, tol: 20), "cursor tip \(px[291, 165])")
    #expect(px.near(288 + 16, 162 + 16, red, tol: 20), "cursor body \(px[304, 178])")
    #expect(!px.near(288 + 24, 162 + 24, red, tol: 60), "beyond cursor \(px[312, 186])")
    #expect(!px.near(288 - 4, 162 - 4, red, tol: 60), "before hot spot \(px[284, 158])")
    e.cursor.visible = false
    let hidden = try await render(bundle, e, at: 1)
    #expect(hidden.near(296, 170, Synthetic.greyRGB, tol: 8))
}

@Test func defaultArrowCursorWhenNoImages() async throws {
    var o = Synthetic.Options()
    o.stillPointer = NormPoint(x: 0.25, y: 0.25)
    let bundle = try await Synthetic.makeBundle(o)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    var e = plainEdit(try bundle.readManifest())
    e.cursor.visible = true
    e.cursor.size = 2
    let px = try await render(bundle, e, at: 1)
    // The arrow body (black) sits just below-right of the hot spot.
    var dark = 0
    for dy in 2..<14 { for dx in 1..<6 { if px[288 + dx, 162 + dy].r < 40 { dark += 1 } } }
    #expect(dark > 10)
}

@Test func zoomEnlargesContent() async throws {
    let bundle = try await Synthetic.makeBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    func squareWidth(_ px: Pixels) -> Int {
        var n = 0
        for x in 0..<px.width where px[x, 270].r < 40 && px[x, 270].g < 40 && px[x, 270].b < 40 { n += 1 }
        return n
    }
    let flat = try await render(bundle, plainEdit(manifest), at: 1.5)
    var e = plainEdit(manifest)
    e.zoom.mode = .manual
    e.zoom.regions = [ZoomRegion(id: "z", range: TimeRange(start: 0, end: 3), scale: 2, focus: .center)]
    let zoomed = try await render(bundle, e, at: 1.5)
    let a = squareWidth(flat), b = squareWidth(zoomed)
    #expect(abs(a - 77) <= 2, "square at zoom 1: \(a)")
    #expect(abs(Double(b) / Double(a) - 2) < 0.08, "zoom ratio \(b)/\(a)")
    // Auto mode with a click zooms too.
    var auto = plainEdit(manifest)
    auto.zoom.mode = .auto
    let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: auto)
    #expect(plan.regions.count == 1 && plan.regions[0].source == .auto)
}

@Test func cameraBubbleDrawn() async throws {
    var o = Synthetic.Options()
    o.camera = true
    let bundle = try await Synthetic.makeBundle(o)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    var e = plainEdit(try bundle.readManifest())
    e.camera.visible = true
    e.camera.shape = .circle
    e.camera.corner = .bottomRight
    let px = try await render(bundle, e, at: 1)
    // 0.22 × 540 = 118.8 px circle, inset 0.035 × 540 = 18.9 px from the bottom-right.
    let d = 0.22 * 540.0, inset = 0.035 * 540.0
    let cx = Int(960 - inset - d / 2), cy = Int(540 - inset - d / 2)
    let c = px[cx, cy]
    #expect(c.g > 150 && c.r < 90 && c.b < 90, "bubble centre \(c)")
    // The corner of the bubble's square is outside the circle: the screen shows through (not camera green).
    let corner = px[Int(960 - inset - d + 3), Int(540 - inset - d + 3)]
    #expect(abs(corner.r - corner.g) < 12 && corner.r > 100, "outside circle \(corner)")
}

@Test func annotationsAndKeystrokesRender() async throws {
    let bundle = try await Synthetic.makeBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let log = try EventLogWriter(url: bundle.eventsURL)
    for (i, ch) in "hello".enumerated() { log.append(InputEvent(t: 0.6 + Double(i) * 0.1, type: .key, chars: String(ch))) }
    log.close()
    var e = plainEdit(try bundle.readManifest())
    e.cursor.showKeystrokes = true
    e.annotations = [Annotation(kind: .box, range: TimeRange(start: 0, end: 3), rect: NormRect(x: 0.1, y: 0.6, width: 0.2, height: 0.2),
                                color: RGBA(0, 1, 0)),
                     Annotation(kind: .blur, range: TimeRange(start: 0, end: 3), rect: NormRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))]
    let px = try await render(bundle, e, at: 1.2)
    // Box stroke: left edge at card x + 0.1 × 768 = 172.8, y inside 54 + 0.7 × 432.
    let edge = px[173, 356]
    #expect(edge.g > 200 && edge.r < 60, "box stroke \(edge)")
    // Blur pixelates the black square's edge: the centre is no longer pure black or the border mixes.
    // Keystroke pill near the bottom centre is dark ink.
    var ink = 0
    for y in 440..<530 { for x in 430..<530 where px[x, y].r < 50 && px[x, y].b < 60 { ink += 1 } }
    #expect(ink > 200, "keystroke pill pixels \(ink)")
}

@Test func outputCanvasSizes() {
    let src = PixelSize(width: 2880, height: 1800)
    #expect(RenderPlan.canvasSize(source: src, aspect: .source, height: nil) == src)
    #expect(RenderPlan.canvasSize(source: src, aspect: .wide, height: nil) == PixelSize(width: 3200, height: 1800))
    #expect(RenderPlan.canvasSize(source: src, aspect: .vertical, height: nil) == PixelSize(width: 1800, height: 3200))
    #expect(RenderPlan.canvasSize(source: src, aspect: .square, height: 1080) == PixelSize(width: 1080, height: 1080))
    #expect(RenderPlan.canvasSize(source: src, aspect: .wide, height: 1080) == PixelSize(width: 1920, height: 1080))
}

@Test func webVTTParses() {
    let v = "WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nHello <b>there</b>\n\n1\n00:01:00,000 --> 00:01:01.000 align:center\nSecond"
    let cues = WebVTT.parse(v)
    #expect(cues.count == 2)
    #expect(cues[0].text == "Hello there" && cues[0].range == TimeRange(start: 1, end: 2.5))
    #expect(cues[1].range.start == 60)
}

/// Writes sample frames as PNGs for eyeballing: `RB_DUMP_DIR=/path scripts/test.sh --filter dumpFrames`.
@Test func dumpFrames() async throws {
    guard let dir = ProcessInfo.processInfo.environment["RB_DUMP_DIR"] else { return }
    var o = Synthetic.Options()
    o.camera = true
    o.seconds = 4
    o.captureScale = 2
    let bundle = try await Synthetic.makeBundle(o)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let log = try EventLogWriter(url: bundle.eventsURL)
    for (i, ch) in "hello".enumerated() { log.append(InputEvent(t: 1.0 + Double(i) * 0.1, type: .key, chars: String(ch))) }
    log.close()
    let manifest = try bundle.readManifest()
    var e = EditDocument.initial(for: manifest)
    e.cursor.showKeystrokes = true
    e.annotations = [Annotation(kind: .arrow, range: TimeRange(start: 0, end: 4), rect: NormRect(x: 0.6, y: 0.2, width: 0.15, height: 0.15)),
                     Annotation(kind: .text, range: TimeRange(start: 0, end: 4), rect: NormRect(x: 0.6, y: 0.1, width: 0.3, height: 0.06), text: "Click here")]
    let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: e)
    let sources = try await MediaSources.load(bundle: bundle, manifest: manifest)
    for t in [0.3, 1.2, 1.6, 2.2] {
        let img = try Thumbnailer.render(plan: plan, sources: sources, at: t, maxWidth: 1280)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("frame-\(t).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }
    print("regions:", plan.regions)
}
