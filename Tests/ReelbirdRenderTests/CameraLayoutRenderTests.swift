@preconcurrency import AVFoundation
import CoreGraphics
import ImageIO
import Foundation
import Testing
import ReelbirdCore
@testable import ReelbirdRender

// Camera during zooms (shrink, stepping aside) and camera layouts (camera only, split, screen only), drawn by the
// one renderer that preview and export share. Synthetic media: grey 16:9 screen with a black centre square,
// solid green camera; a solid blue background.

private func layoutEdit(_ manifest: ProjectManifest) -> EditDocument {
    var e = EditDocument.initial(for: manifest)
    e.background.kind = .solid
    e.background.colors = [RGBA(hex: "#2050A0")!]
    e.background.padding = 0.1
    e.background.shadow = 0
    e.background.motionBlur = false
    e.zoom.mode = .off
    e.cursor.visible = false
    e.camera.visible = true
    return e
}

private func render(_ bundle: ProjectBundle, _ edit: EditDocument, at times: [Double], width: Int = 960) async throws -> [Pixels] {
    let manifest = try bundle.readManifest()
    let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: edit)
    let sources = try await MediaSources.load(bundle: bundle, manifest: manifest)
    var frames: [Pixels] = []
    for t in times { frames.append(Pixels(try await Thumbnailer.render(plan: plan, sources: sources, at: t, maxWidth: width))) }
    return frames
}

private func green(_ px: Pixels, _ x: Double, _ y: Double) -> Bool {
    let xi = min(px.width - 2, max(1, Int(x))), yi = min(px.height - 1, max(0, Int(y)))
    return (-1...1).contains { d in
        let c = px[xi + d, yi]
        return c.g > 150 && c.r < 90 && c.b < 90
    }
}

private func blue(_ px: Pixels, _ x: Double, _ y: Double) -> Bool { px.near(Int(x), Int(y), (0x20, 0x50, 0xA0), tol: 14) }
private func grey(_ px: Pixels, _ x: Double, _ y: Double) -> Bool { px.near(Int(x), Int(y), (128, 128, 128), tol: 20) }

private func layoutBundle(seconds: Double, pointer: NormPoint = .center) async throws -> ProjectBundle {
    var o = Synthetic.Options()
    o.camera = true
    o.seconds = seconds
    o.stillPointer = pointer
    return try await Synthetic.makeBundle(o)
}

@Test func eachLayoutDrawsWhereItShouldInWideAndTallCanvases() async throws {
    let bundle = try await layoutBundle(seconds: 10)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    for aspect in [CanvasSettings.Aspect.wide, .vertical] {
        var e = layoutEdit(manifest)
        e.canvas.aspect = aspect
        e.layouts = [LayoutSegment(range: TimeRange(start: 1, end: 3), kind: .fullCamera),
                     LayoutSegment(range: TimeRange(start: 4, end: 6), kind: .split),
                     LayoutSegment(range: TimeRange(start: 7, end: 9), kind: .screenOnly)]
        let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: e)
        let px = try await render(bundle, e, at: [0.5, 2, 5, 8], width: aspect == .wide ? 960 : 540)
        let W = Double(px[0].width), H = Double(px[0].height)
        let tag = "\(aspect.rawValue)"

        // Overlay: the bubble in its corner over the background; the card shows the screen.
        let bubble = plan.cameraFrame(at: 0.5, width: W, height: H)
        #expect(green(px[0], bubble.midX, bubble.midY), "\(tag) bubble")
        #expect(blue(px[0], 3, 3), "\(tag) background \(px[0][3, 3])")
        #expect(!green(px[0], W / 2, H * 0.3), "\(tag) the screen in the middle")

        // Camera only: the camera fills the frame, edge to edge.
        for (x, y) in [(W / 2, H / 2), (4.0, 4.0), (W - 5, H - 5), (W - 5, 4.0), (4.0, H - 5)] {
            #expect(green(px[1], x, y), "\(tag) full camera at \(x),\(y): \(px[1][Int(x), Int(y)])")
        }

        // Split: card and camera panel side by side (stacked when tall), on the background.
        let tile = plan.cameraTile(at: 5, width: W, height: H)
        let card = SplitGeometry.rects(width: W, height: H, background: e.background, cardAspect: plan.cardAspect).card
        #expect(tile.rect == SplitGeometry.rects(width: W, height: H, background: e.background, cardAspect: plan.cardAspect).camera)
        if aspect == .wide {
            #expect(tile.rect.minX > card.maxX && abs(tile.rect.minY - card.minY) < 1e-6 && abs(tile.rect.height - card.height) < 1e-6)
        } else {
            #expect(tile.rect.minY > card.maxY && abs(tile.rect.minX - card.minX) < 1e-6 && abs(tile.rect.width - card.width) < 1e-6)
        }
        #expect(green(px[2], tile.rect.midX, tile.rect.midY), "\(tag) split camera")
        #expect(green(px[2], tile.rect.minX + 6, tile.rect.midY) && green(px[2], tile.rect.maxX - 7, tile.rect.midY), "\(tag) panel filled")
        #expect(grey(px[2], card.minX + card.width * 0.25, card.minY + card.height * 0.75), "\(tag) split screen \(px[2][Int(card.minX + card.width * 0.25), Int(card.minY + card.height * 0.75)])")
        #expect(!green(px[2], card.midX - card.width * 0.3, card.midY))
        #expect(blue(px[2], 3, 3) && blue(px[2], W - 4, H - 4), "\(tag) background around the split")
        let gap = aspect == .wide ? CGPoint(x: (card.maxX + tile.rect.minX) / 2, y: card.midY) : CGPoint(x: card.midX, y: (card.maxY + tile.rect.minY) / 2)
        #expect(blue(px[2], gap.x, gap.y), "\(tag) gap between card and camera \(px[2][Int(gap.x), Int(gap.y)])")

        // Screen only: no camera anywhere.
        let hidden = plan.cameraTile(at: 8, width: W, height: H)
        #expect(hidden.opacity == 0)
        var any = false
        for gy in stride(from: 4.0, to: H, by: 12) { for gx in stride(from: 4.0, to: W - 2, by: 12) where green(px[3], gx, gy) { any = true } }
        #expect(!any, "\(tag) screen only shows no camera")
        let full = CanvasLayout(plan: plan, width: W, height: H).card
        let probe = (x: full.minX + full.width * 0.25, y: full.minY + full.height * 0.75) // clear of the test card's text rows
        #expect(grey(px[3], probe.x, probe.y), "\(tag) the screen card as usual \(px[3][Int(probe.x), Int(probe.y)]) \(full)")
    }
}

@Test func layoutChangesBlendTheTileAndTheCard() async throws {
    let bundle = try await layoutBundle(seconds: 8)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    var e = layoutEdit(manifest)
    e.layouts = [LayoutSegment(range: TimeRange(start: 2, end: 4), kind: .fullCamera),
                 LayoutSegment(range: TimeRange(start: 4, end: 6), kind: .split)]
    let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: e)
    let W = 960.0, H = 540.0
    let half = LayoutTimeline.transitionDuration / 2
    let bubble = plan.cameraFrame(at: 0, width: W, height: H)
    // Steady on both sides of an edge; in between the tile grows from the bubble to the frame.
    #expect(plan.cameraTile(at: 2 - half, width: W, height: H).rect == bubble)
    #expect(plan.cameraTile(at: 2 + half, width: W, height: H).rect == CGRect(x: 0, y: 0, width: W, height: H))
    let mid = plan.cameraTile(at: 2, width: W, height: H)
    #expect(mid.rect.width > bubble.width && mid.rect.width < W && mid.rect.maxX > bubble.maxX - 1)
    #expect(mid.radius < bubble.width / 2 && mid.radius > 0)
    // Camera only → split, straight: the tile shrinks into the panel while the card slides into its place.
    let split = SplitGeometry.rects(width: W, height: H, background: e.background, cardAspect: plan.cardAspect)
    #expect(plan.cameraTile(at: 4 + half, width: W, height: H).rect == split.camera)
    let m = plan.cameraTile(at: 4, width: W, height: H).rect
    #expect(m.width < W && m.width > split.camera.width)
    let fullCard = CanvasLayout(plan: plan, width: W, height: H).card
    let cardMid = CanvasLayout(plan: plan, width: W, height: H, layout: plan.layoutState(at: 6)).card
    #expect(cardMid.width < fullCard.width && cardMid.width > split.card.width, "the card slides back mid-change")
    #expect(CanvasLayout(plan: plan, width: W, height: H, layout: plan.layoutState(at: 5)).card == split.card)
    #expect(CanvasLayout(plan: plan, width: W, height: H, layout: plan.layoutState(at: 7)).card == fullCard)
    // Mid-change frames render (the camera is where the blended tile is).
    let px = try await render(bundle, e, at: [2, 6])
    #expect(green(px[0], mid.rect.midX, mid.rect.midY))
    let back = plan.cameraTile(at: 6, width: W, height: H).rect
    #expect(green(px[1], back.midX, back.midY))
    // Without a camera track nothing changes: the overlay throughout.
    var noCam = e
    noCam.camera.visible = false
    #expect(try RenderPlan(bundle: bundle, manifest: manifest, edit: noCam).layoutState(at: 3) == .overlay)
}

@Test func bubbleShrinksWithTheZoomOnItsCurve() async throws {
    let bundle = try await layoutBundle(seconds: 8)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    var e = layoutEdit(manifest)
    e.zoom.mode = .manual
    e.zoom.regions = [ZoomRegion(range: TimeRange(start: 2, end: 5), scale: 2, focus: NormPoint(x: 0.4, y: 0.4))]
    let W = 960.0, H = 540.0
    let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: e)
    let before = plan.cameraFrame(at: 0.5, width: W, height: H)
    let hold = plan.cameraFrame(at: 3.5, width: W, height: H)
    #expect(plan.zoomProgress(at: 0.5) == 0 && abs(plan.zoomProgress(at: 3.5) - 1) < 1e-3)
    #expect(abs(hold.width - before.width * 0.7) < 0.5, "70% of its size while zoomed: \(hold.width) vs \(before.width)")
    #expect(abs(hold.maxX - before.maxX) < 1e-6 && abs(hold.maxY - before.maxY) < 1e-6, "shrinks into its corner")
    // On the zoom's own curve: the size follows ln(scale) / ln(depth) through the zoom in.
    for t in stride(from: 1.4, through: 2.6, by: 0.2) {
        let s = plan.camera.transform(at: t).scale
        let expected = 1 + (0.7 - 1) * min(1, log(s) / log(2))
        #expect(abs(plan.cameraSizeScale(at: t) - expected) < 1e-9)
    }
    #expect(plan.cameraSizeScale(at: 1.6) < 1 && plan.cameraSizeScale(at: 1.6) > 0.7, "mid zoom-in")
    #expect(plan.cameraFrame(at: 7.5, width: W, height: H) == before, "back to size after the zoom")
    // The slider and the switch.
    e.camera.sizeWhileZoomed = 0.4
    #expect(abs(try RenderPlan(bundle: bundle, manifest: manifest, edit: e).cameraFrame(at: 3.5, width: W, height: H).width - before.width * 0.4) < 0.5)
    e.camera.shrinkWhenZoomed = false
    #expect(try RenderPlan(bundle: bundle, manifest: manifest, edit: e).cameraFrame(at: 3.5, width: W, height: H) == before)
    // Pixels: the corner of the full-size bubble is background while zoomed in.
    e.camera.shrinkWhenZoomed = true
    e.camera.sizeWhileZoomed = 0.5
    let px = try await render(bundle, e, at: [0.5, 3.5])
    let p = CGPoint(x: before.minX + before.width * 0.3, y: before.minY + before.height * 0.3)
    #expect(green(px[0], p.x, p.y), "inside the bubble before")
    #expect(!green(px[1], p.x, p.y), "outside the shrunk bubble while zoomed")
    #expect(green(px[1], before.maxX - before.width * 0.25, before.maxY - before.height * 0.25), "still in its corner")
}

@Test func bubbleStepsAsideFromTheZoomedCursorAndComesBack() async throws {
    // The pointer sits bottom right, under the bubble; a cursor-following zoom brings it right under the bubble.
    let bundle = try await layoutBundle(seconds: 9, pointer: NormPoint(x: 0.93, y: 0.9))
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    var e = layoutEdit(manifest)
    e.zoom.mode = .manual
    e.zoom.regions = [ZoomRegion(range: TimeRange(start: 2, end: 5), scale: 1.8)]
    let W = 960.0, H = 540.0
    let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: e)
    let home = NormPoint(x: 1, y: 1)
    #expect(plan.cameraPlace(at: 0.5) == home)
    let aside = plan.cameraPlace(at: 3.5)
    #expect(aside == NormPoint(x: 1, y: 0), "nearest free corner: straight up (\(aside))")
    // The cursor is no longer under the bubble.
    let layout = CanvasLayout(plan: plan, width: W, height: H)
    let (s, c) = plan.camera.transform(at: 3.5)
    let cursor = layout.map(try #require(plan.cursor.position(at: 3.5)), scale: s, center: layout.fillCenter(scale: s, center: c))
    #expect(!plan.cameraFrame(at: 3.5, width: W, height: H).contains(cursor))
    #expect(CameraPlacement.frame(at: home, layout: e.camera, width: W, height: H, sizeScale: 0.7).insetBy(dx: -10, dy: -10).contains(cursor),
            "it would have been under the bubble")
    // Glides with the zoom (in between mid zoom-in) and back after it.
    let gliding = plan.cameraPlace(at: 2)
    #expect(gliding.y > 0.01 && gliding.y < 0.99 && gliding.x == 1)
    #expect(plan.cameraPlace(at: 8) == home)
    // Pixels: the bubble shows top right while zoomed.
    let px = try await render(bundle, e, at: [3.5])
    let f = plan.cameraFrame(at: 3.5, width: W, height: H)
    #expect(f.minY < H / 2 && green(px[0], f.midX, f.midY))
    // A fixed focus counts too; and the switch keeps it in place.
    e.zoom.regions = [ZoomRegion(range: TimeRange(start: 2, end: 5), scale: 2, focus: NormPoint(x: 0.95, y: 0.95))]
    #expect(try RenderPlan(bundle: bundle, manifest: manifest, edit: e).cameraPlace(at: 3.5) != home)
    e.camera.smartFraming = false
    #expect(try RenderPlan(bundle: bundle, manifest: manifest, edit: e).cameraPlace(at: 3.5) == home)
    // A focus away from the bubble leaves it where it is.
    e.camera.smartFraming = true
    e.zoom.regions = [ZoomRegion(range: TimeRange(start: 2, end: 5), scale: 2, focus: NormPoint(x: 0.2, y: 0.2))]
    #expect(try RenderPlan(bundle: bundle, manifest: manifest, edit: e).cameraPlace(at: 3.5) == home)
}

/// Review images (not a check): with RB_REVIEW_DIR set, writes PNGs of each layout, the changes between them and
/// the bubble during a zoom, in 16:9 and 9:16.
@Test(.enabled(if: ProcessInfo.processInfo.environment["RB_REVIEW_DIR"] != nil)) func cameraLayoutReviewFrames() async throws {
    let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RB_REVIEW_DIR"]!, isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let bundle = try await layoutBundle(seconds: 14, pointer: NormPoint(x: 0.93, y: 0.9))
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    let sources = try await MediaSources.load(bundle: bundle, manifest: manifest)
    for aspect in [CanvasSettings.Aspect.wide, .vertical] {
        var e = layoutEdit(manifest)
        e.background.kind = .gradient
        e.background.colors = [RGBA(hex: "#F6C68B")!, RGBA(hex: "#E2795C")!]
        e.background.shadow = 0.5
        e.canvas.aspect = aspect
        e.zoom.mode = .manual
        e.zoom.regions = [ZoomRegion(range: TimeRange(start: 11, end: 13.5), scale: 1.8)]
        e.layouts = [LayoutSegment(range: TimeRange(start: 2, end: 4), kind: .fullCamera),
                     LayoutSegment(range: TimeRange(start: 4, end: 7), kind: .split),
                     LayoutSegment(range: TimeRange(start: 8, end: 9.5), kind: .screenOnly)]
        let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: e)
        let shots: [(String, Double)] = [("overlay", 1), ("to-camera-mid", 2), ("camera", 3), ("camera-to-split-mid", 4), ("split", 5.5),
                                          ("split-to-bubble-mid", 7), ("screen-only", 9), ("zoom-in-mid", 10.6), ("zoomed-aside", 12.2)]
        for (name, t) in shots {
            let img = try await Thumbnailer.render(plan: plan, sources: sources, at: t, maxWidth: aspect == .wide ? 1280 : 720)
            let url = out.appendingPathComponent("\(aspect == .wide ? "16x9" : "9x16")-\(name).png")
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
    }
}
