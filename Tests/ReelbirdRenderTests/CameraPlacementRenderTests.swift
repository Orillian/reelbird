import CoreGraphics
import ImageIO
import Foundation
import Testing
import ReelbirdCore
@testable import ReelbirdRender

/// Solid background, no shadow, zoom or cursor: only the screen card and the camera bubble.
private func cameraEdit(_ manifest: ProjectManifest) -> EditDocument {
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

private func frames(_ bundle: ProjectBundle, _ edit: EditDocument, at times: [Double], width: Int = 960) async throws -> [Pixels] {
    let manifest = try bundle.readManifest()
    let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: edit)
    let sources = try await MediaSources.load(bundle: bundle, manifest: manifest)
    return try times.map { Pixels(try Thumbnailer.render(plan: plan, sources: sources, at: $0, maxWidth: width)) }
}

/// The synthetic camera is solid green (with one thin moving line, so look at three neighbours).
private func isCamera(_ px: Pixels, _ x: Int, _ y: Int) -> Bool {
    (-1...1).contains { d in
        let c = px[min(px.width - 1, max(0, x + d)), y]
        return c.g > 150 && c.r < 90 && c.b < 90
    }
}

private func cameraBundle(seconds: Double = 4, events: [InputEvent]? = nil) async throws -> ProjectBundle {
    var o = Synthetic.Options()
    o.camera = true
    o.seconds = seconds
    o.stillPointer = .center
    if let events { o.events = [.move(0, .center)] + events }
    return try await Synthetic.makeBundle(o)
}

// Canvas 960×540: bubble 0.22 × 540 = 118.8 px, inset 0.035 × 540 = 18.9 px; room 803.3 × 383.3 px.

@Test func cameraBubbleRendersAtItsPlaceAndGlidesBetweenMoves() async throws {
    let bundle = try await cameraBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    var e = cameraEdit(try bundle.readManifest())
    e.camera.position = NormPoint(x: 0, y: 0)
    e.camera.moves = [CameraLayout.Move(t: 1.0, x: 1, y: 1)]
    let px = try await frames(bundle, e, at: [0.5, 1.15, 2.0])
    let d = 0.22 * 540, inset = 0.035 * 540
    let tl = (x: Int(inset + d / 2), y: Int(inset + d / 2))
    let br = (x: Int(960 - inset - d / 2), y: Int(540 - inset - d / 2))
    #expect(isCamera(px[0], tl.x, tl.y), "top left before the move \(px[0][tl.x, tl.y])")
    #expect(!isCamera(px[0], br.x, br.y))
    // Halfway through the 300 ms glide the bubble is centred.
    #expect(isCamera(px[1], 480, 270), "mid-glide centre \(px[1][480, 270])")
    #expect(!isCamera(px[1], tl.x, tl.y) && !isCamera(px[1], br.x, br.y))
    #expect(isCamera(px[2], br.x, br.y), "bottom right after the move \(px[2][br.x, br.y])")
    #expect(!isCamera(px[2], tl.x, tl.y))
}

@Test func cameraPlaceIgnoresPaddingAndFollowsTheCanvasAspect() async throws {
    let bundle = try await cameraBundle(seconds: 2)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    var e = cameraEdit(manifest)
    e.camera.position = NormPoint(x: 0.25, y: 1)
    var framesSeen: [CGRect] = []
    for padding in [0.0, 0.1, 0.3] {
        e.background.padding = padding
        let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: e)
        framesSeen.append(plan.cameraFrame(at: 1, width: 960, height: 540))
    }
    #expect(Set(framesSeen.map { "\($0)" }).count == 1, "an overlay on the canvas: padding doesn't move it \(framesSeen)")
    // Crop and zoom don't move it either.
    e.crop = NormRect(x: 0.1, y: 0.1, width: 0.6, height: 0.6)
    e.zoom.mode = .manual
    e.zoom.regions = [ZoomRegion(range: TimeRange(start: 0, end: 2), scale: 2, focus: NormPoint(x: 0.3, y: 0.3))]
    let cropped = try RenderPlan(bundle: bundle, manifest: manifest, edit: e)
    let cf = cropped.cameraFrame(at: 1, width: Double(cropped.canvasSize.width), height: Double(cropped.canvasSize.height))
    let short = Double(min(cropped.canvasSize.width, cropped.canvasSize.height))
    #expect(abs(cf.maxY - (Double(cropped.canvasSize.height) - 0.035 * short)) < 1e-6, "against the bottom edge at the inset")
    // 9:16: a quarter of the way across, against the bottom, inside the narrow frame.
    e.crop = nil
    e.zoom.mode = .off
    e.canvas.aspect = .vertical
    let px = try await frames(bundle, e, at: [1], width: 540)[0]
    let W = Double(px.width), H = Double(px.height), s = min(W, H)
    let d = 0.22 * s, inset = 0.035 * s
    let cx = inset + 0.25 * (W - 2 * inset - d) + d / 2, cy = H - inset - d / 2
    #expect(isCamera(px, Int(cx), Int(cy)), "vertical canvas bubble \(px[Int(cx), Int(cy)])")
    #expect(!isCamera(px, Int(W - inset - d / 2), Int(cy)))
}

@Test func cameraShapesMaskTheirOwnOutline() async throws {
    let bundle = try await cameraBundle(seconds: 2)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    var e = cameraEdit(try bundle.readManifest())
    e.camera.position = NormPoint(x: 0.5, y: 0.5)
    e.camera.size = 0.4
    func shot(_ shape: CameraLayout.Shape) async throws -> (Pixels, CGRect) {
        e.camera.shape = shape
        let plan = try RenderPlan(bundle: bundle, manifest: try bundle.readManifest(), edit: e)
        return (try await frames(bundle, e, at: [1])[0], plan.cameraFrame(at: 1, width: 960, height: 540))
    }
    // A point 12% in from the bubble's corner: outside a circle, inside the squircle's continuous corner.
    let (circle, cr) = try await shot(.circle)
    let probe = { (r: CGRect) in (Int(r.minX + 0.12 * r.width), Int(r.minY + 0.12 * r.height)) }
    #expect(!isCamera(circle, probe(cr).0, probe(cr).1))
    #expect(isCamera(circle, Int(cr.midX), Int(cr.midY)))
    let (square, sr) = try await shot(.roundedSquare)
    #expect(sr.size == cr.size)
    #expect(isCamera(square, probe(sr).0, probe(sr).1), "squircle corner \(square[probe(sr).0, probe(sr).1])")
    // The very corner is still rounded off.
    #expect(!isCamera(square, Int(sr.minX + 2), Int(sr.minY + 2)))
    // Portrait: 3:4, taller than the circle; its top edge is camera where the circle's is not.
    let (tile, pr) = try await shot(.portrait)
    #expect(abs(pr.width / pr.height - 0.75) < 0.01 && pr.height > cr.height)
    #expect(isCamera(tile, Int(pr.midX), Int(pr.minY + 4)))
    #expect(isCamera(tile, Int(pr.minX + 4), Int(pr.midY)))
    #expect(!isCamera(tile, Int(pr.minX + 1), Int(pr.minY + 1)))
    // Measured extents match the planned rectangle (no stretch, centred mask).
    var top = Int(pr.midY), bottom = Int(pr.midY)
    while top > 0, isCamera(tile, Int(pr.midX), top - 1) { top -= 1 }
    while bottom < tile.height - 1, isCamera(tile, Int(pr.midX), bottom + 1) { bottom += 1 }
    #expect(abs(Double(bottom - top + 1) - pr.height) < 6, "portrait height \(bottom - top + 1) vs \(pr.height)")
}

/// End to end from a recording's log: camera events as the recorder writes them become the first edit's
/// placement, and the rendered video shows the bubble at the start place, then where it was dragged.
@Test func recordedCameraMovesShowInTheVideo() async throws {
    // A 1280×720 screen; the live bubble is 160 pt, inset like the editor (0.035 × 720 = 25.2).
    let inset = 0.035 * 720, d = 160.0
    func at(_ x: Double, _ y: Double) -> NormRect { NormRect(x: x / 1280, y: y / 720, width: d / 1280, height: d / 720) }
    let events: [InputEvent] = [
        .camera(0, frame: at(1280 - inset - d, 720 - inset - d), shape: .roundedSquare),
        .camera(1.5, frame: at(0, 0), shape: .roundedSquare),
    ]
    let bundle = try await cameraBundle(seconds: 3, events: events)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let edit = try bundle.readEdit()  // no edit.json yet: the first edit, placed from the log
    #expect(edit.camera.shape == .roundedSquare)
    #expect(edit.camera.position == NormPoint(x: 1, y: 1))
    #expect(edit.camera.moves == [CameraLayout.Move(t: 1.5, x: 0, y: 0)])
    var e = edit
    e.background.kind = .solid
    e.background.colors = [RGBA(hex: "#2050A0")!]
    e.background.shadow = 0
    e.background.motionBlur = false
    e.zoom.mode = .off
    e.cursor.visible = false
    let px = try await frames(bundle, e, at: [0.5, 2.5])
    let bd = 0.22 * 540, bi = 0.035 * 540
    #expect(isCamera(px[0], Int(960 - bi - bd / 2), Int(540 - bi - bd / 2)), "starts bottom right")
    #expect(isCamera(px[1], Int(bi + bd / 2), Int(bi + bd / 2)), "moved to the top left")
    #expect(!isCamera(px[1], Int(960 - bi - bd / 2), Int(540 - bi - bd / 2)))
}

/// Writes one frame per camera shape for eyeballing: `RB_DUMP_DIR=/path scripts/test.sh --filter dumpCameraShapes`.
@Test func dumpCameraShapes() async throws {
    guard let dir = ProcessInfo.processInfo.environment["RB_DUMP_DIR"] else { return }
    let bundle = try await cameraBundle(seconds: 2)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    let sources = try await MediaSources.load(bundle: bundle, manifest: manifest)
    for shape in CameraLayout.Shape.allCases {
        for (name, aspect, place) in [("wide", CanvasSettings.Aspect.wide, NormPoint(x: 1, y: 1)), ("vertical", .vertical, NormPoint(x: 0.5, y: 1))] {
            var e = EditDocument.initial(for: manifest)
            e.camera.visible = true
            e.camera.shape = shape
            e.camera.position = place
            e.canvas.aspect = aspect
            let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: e)
            let img = try Thumbnailer.render(plan: plan, sources: sources, at: 1, maxWidth: 1280)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("camera-\(shape.rawValue)-\(name).png")
            let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
    }
}
