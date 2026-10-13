@preconcurrency import AVFoundation
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
    // The live size carries over: 160 of 720 pt, on the padded card (0.84 of the frame's height).
    #expect(abs(edit.camera.size - 160.0 / 720 * 0.84) < 1e-3, "size \(edit.camera.size)")
    var e = edit
    e.background.kind = .solid
    e.background.colors = [RGBA(hex: "#2050A0")!]
    e.background.shadow = 0
    e.background.motionBlur = false
    e.zoom.mode = .off
    e.cursor.visible = false
    let px = try await frames(bundle, e, at: [0.5, 2.5])
    let bd = edit.camera.size * 540, bi = 0.035 * 540
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

// MARK: - What you see is what you get

/// One live bubble as the recorder sees it: the captured region and the bubble's frame, both in global display
/// points with a top-left origin (a display left of or above the main one has negative coordinates).
private struct LiveBubble {
    let name: String
    let area: CGRect
    let frame: CGRect
    let shape: CameraLayout.Shape
    /// Expected place on the region in points, before scaling: the live frame moved inside the region's room.
    var expectedLocal: CGRect {
        let m = 0.035 * min(area.width, area.height)
        let x = min(max(frame.minX - area.minX, m), area.width - m - frame.width)
        let y = min(max(frame.minY - area.minY, m), area.height - m - frame.height)
        return CGRect(x: x, y: y, width: frame.width, height: frame.height)
    }
}

/// The live bubble's pixel size in points for a size preset, as the app draws it (`CameraBubbleSize.size`).
private func livePoints(_ points: Double, _ shape: CameraLayout.Shape) -> CGSize {
    let s = CameraPlacement.bubbleSize(shape: shape, size: points, short: 1)
    return CGSize(width: s.width.rounded(), height: s.height.rounded())
}

/// The camera's bounding box in an exported frame (green pixels; the thin 35% white rim still reads as green).
private func cameraBox(_ px: Pixels) -> CGRect? {
    var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
    for y in 0..<px.height {
        for x in 0..<px.width {
            let c = px[x, y]
            guard c.g > 150, c.r < 90, c.b < 90 else { continue }
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        }
    }
    return x1 < 0 ? nil : CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
}

/// Exports `edit` to an H.264 file and decodes the frame at `t`.
private func exportedFrame(_ bundle: ProjectBundle, _ edit: EditDocument, at t: Double) async throws -> Pixels {
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent("rb-wysiwyg-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: dest) }
    let url = try await Exporter.export(bundle: bundle, edit: edit, options: ExportOptions(format: .mp4H264, destination: dest)) { _ in }
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    let (img, _) = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600))
    return Pixels(img)
}

/// The live bubble's place and size, as the recorder logs them (`CameraBubbleLog`: normalized to the captured
/// region, moved inside it, rounded to 4 decimals), become the first edit; the exported video shows the bubble at
/// the same centre and size relative to the frame. Display, window and area captures; a second display at negative
/// coordinates; each shape and live size. Points are normalized away, so Retina scale doesn't enter.
@Test func liveBubbleLandsAtTheSameCentreAndSizeInTheExport() async throws {
    let bundle = try await cameraBundle(seconds: 2)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    #expect(manifest.track(.screen)?.pixelSize == PixelSize(width: 1280, height: 720))

    let medium = livePoints(200, .circle), large = livePoints(280, .portrait), small = livePoints(140, .roundedSquare)
    let cases = [
        // The default spot: bottom right of a 1600×900 pt display at the editor's inset (31.5 pt).
        LiveBubble(name: "display, default corner", area: CGRect(x: 0, y: 0, width: 1600, height: 900),
                   frame: CGRect(origin: CGPoint(x: 1600 - 31.5 - medium.width, y: 900 - 31.5 - medium.height), size: medium), shape: .circle),
        // A second display to the left of and above the main one.
        LiveBubble(name: "second display, portrait L", area: CGRect(x: -1920, y: -300, width: 1920, height: 1080),
                   frame: CGRect(origin: CGPoint(x: -1500, y: 200), size: large), shape: .portrait),
        // A window: the bubble partly outside it lands at the nearest place over it.
        LiveBubble(name: "window, square S half outside", area: CGRect(x: 420, y: 260, width: 800, height: 450),
                   frame: CGRect(origin: CGPoint(x: 1150, y: 420), size: small), shape: .roundedSquare),
        // An area, bubble centred on it.
        LiveBubble(name: "area, centred", area: CGRect(x: 200, y: 120, width: 960, height: 540),
                   frame: CGRect(origin: CGPoint(x: 680 - medium.width / 2, y: 390 - medium.height / 2), size: medium), shape: .circle),
    ]

    for padded in [false, true] {
        for c in cases {
            let r4: (Double) -> Double = { ($0 * 10_000).rounded() / 10_000 }
            let n = try #require(CameraPlacement.normalizedBubble(frame: c.frame, area: c.area))
            let rect = NormRect(x: r4(n.x), y: r4(n.y), width: r4(n.width), height: r4(n.height))
            var initial = EditDocument.initial(for: manifest)
            if !padded { initial.background.kind = .none }
            // As `EditDocument.initial(for:events:)` does, with this edit's background.
            let screen = PixelSize(width: 1280, height: 720)
            CameraPlacement.apply(events: [.camera(0, frame: rect, shape: c.shape)], screen: screen, crop: nil, duration: 2,
                                  sizeScale: CameraPlacement.cardScale(source: screen, background: initial.background), to: &initial.camera)
            var e = initial
            e.zoom.mode = .off
            e.cursor.visible = false
            e.background.shadow = 0
            e.background.motionBlur = false
            let px = try await exportedFrame(bundle, e, at: 1)
            #expect(px.width == 1280 && px.height == 720)
            let box = try #require(cameraBox(px), "\(c.name): no bubble")
            let W = 1280.0, H = 720.0
            let local = c.expectedLocal, k = W / c.area.width
            let expected: CGRect
            if padded {
                // Same place in the frame's room; size relative to the screen card (the captured region).
                let pad = 0.08 * H, cardH = H - 2 * pad
                let size = CGSize(width: local.width / c.area.height * cardH, height: local.height / c.area.height * cardH)
                let m = 0.035 * H, mLive = 0.035 * c.area.height
                func place(_ o: Double, _ s: Double, _ L: Double) -> Double { let room = L - 2 * mLive - s; return room > 0 ? (o - mLive) / room : 0.5 }
                let px0 = place(local.minX, local.width, c.area.width), py0 = place(local.minY, local.height, c.area.height)
                expected = CGRect(x: m + px0 * (W - 2 * m - size.width), y: m + py0 * (H - 2 * m - size.height),
                                  width: size.width, height: size.height)
            } else {
                expected = CGRect(x: local.minX * k, y: local.minY * k, width: local.width * k, height: local.height * k)
            }
            let what = "\(c.name)\(padded ? ", padded" : ""): expected \(expected), got \(box)"
            // Within 3 px on a 1280 px frame (measured: within 1 px).
            #expect(abs(box.midX - expected.midX) <= 3 && abs(box.midY - expected.midY) <= 3, "centre: \(what)")
            #expect(abs(box.width - expected.width) <= 3 && abs(box.height - expected.height) <= 3, "size: \(what)")
        }
    }
}

/// The live preview is mirrored (`CameraPreview.makeView`'s default, which is `CameraLayout().mirror`), and so is
/// the export by default: a line at 31% across the camera frame shows on the right of the exported bubble.
@Test func exportMirrorsTheCameraLikeTheLivePreview() async throws {
    #expect(CameraLayout().mirror)
    let bundle = try await cameraBundle(seconds: 2)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    var e = cameraEdit(try bundle.readManifest())
    e.camera.position = NormPoint(x: 0.5, y: 0.5)
    e.camera.size = 0.4
    // Frame 50: the synthetic camera's bright line is at x = 200 of 640 (31% across; 25% across the 4:3 → 1:1 crop).
    func lineX(mirror: Bool) async throws -> Double {
        e.camera.mirror = mirror
        let plan = try RenderPlan(bundle: bundle, manifest: try bundle.readManifest(), edit: e)
        let f = plan.cameraFrame(at: 1, width: 960, height: 540)
        let px = try await frames(bundle, e, at: [50.0 / 30 + 0.005])[0]
        let y = Int(f.midY)
        var best = Int(f.minX), bestSum = 0
        for x in Int(f.minX + 6)..<Int(f.maxX - 6) {
            let c = px[x, y]
            if c.r + c.g + c.b > bestSum { bestSum = c.r + c.g + c.b; best = x }
        }
        return (Double(best) - f.minX) / f.width
    }
    let mirrored = try await lineX(mirror: true), plain = try await lineX(mirror: false)
    #expect(abs(plain - 0.25) < 0.04, "unmirrored line at \(plain)")
    #expect(abs(mirrored - 0.75) < 0.04, "mirrored line at \(mirrored)")
}
