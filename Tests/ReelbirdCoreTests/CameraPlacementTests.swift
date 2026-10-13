import CoreGraphics
import Foundation
import Testing
@testable import ReelbirdCore

private func close(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }
private func close(_ a: NormPoint, _ b: NormPoint, _ tol: Double = 1e-6) -> Bool { close(a.x, b.x, tol) && close(a.y, b.y, tol) }

// MARK: Events

@Test func cameraEventLineParsesOnTheFastPath() throws {
    let line = #"{"rect":{"height":0.2,"width":0.125,"x":0.8,"y":0.75},"shape":"portrait","t":12.5,"type":"camera","x":0.8625,"y":0.85}"#
    let e = try #require(Array(line.utf8).withUnsafeBufferPointer { FlatEventParser.parse($0) })
    #expect(e.type == .camera && e.t == 12.5)
    #expect(e.rect == NormRect(x: 0.8, y: 0.75, width: 0.125, height: 0.2))
    #expect(e.shape == "portrait")
    #expect(e.x == 0.8625 && e.y == 0.85)
    // The same answer as Codable.
    #expect(try JSONCoding.decoder.decode(InputEvent.self, from: Data(line.utf8)) == e)
    // Focus rects take the fast path too; anything unexpected inside a rect falls back.
    let focus = #"{"rect":{"x":0.1,"y":0.2,"width":0.3,"height":0.4},"t":1,"type":"focus"}"#
    #expect(Array(focus.utf8).withUnsafeBufferPointer { FlatEventParser.parse($0) }?.rect == NormRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
    let odd = #"{"rect":{"x":0.1,"y":0.2,"w":0.3,"height":0.4},"t":1,"type":"focus"}"#
    #expect(Array(odd.utf8).withUnsafeBufferPointer { FlatEventParser.parse($0) } == nil)
}

@Test func cameraEventsRoundTripThroughTheLog() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rb-cam-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("events.jsonl")
    let log = try EventLogWriter(url: url)
    log.append(.move(0.1, NormPoint(x: 0.5, y: 0.5)))
    log.append(.camera(0, frame: NormRect(x: 0.85, y: 0.8, width: 0.1, height: 0.15), shape: .circle))
    log.append(.camera(4.2, frame: NormRect(x: 0.02, y: 0.03, width: 0.1, height: 0.15), shape: .roundedSquare))
    log.close()
    let events = try EventLog.read(url)
    let cams = events.filter { $0.type == .camera }
    #expect(cams.count == 2)
    #expect(cams[1].t == 4.2 && cams[1].shape == "roundedSquare")
    #expect(cams[1].rect == NormRect(x: 0.02, y: 0.03, width: 0.1, height: 0.15))
    #expect(close(cams[1].point!, NormPoint(x: 0.07, y: 0.105)))
}

// MARK: Back-compat

@Test func oldCameraLayoutsDecodeToTheSamePlacement() throws {
    for corner in CameraLayout.Corner.allCases {
        let json = #"{"camera":{"visible":true,"shape":"roundedRect","size":0.25,"corner":"\#(corner.rawValue)","inset":0.04,"mirror":true}}"#
        let e = try JSONCoding.decoder.decode(EditDocument.self, from: Data(json.utf8))
        #expect(e.camera.shape == .roundedSquare, "roundedRect reads as roundedSquare")
        #expect(e.camera.x == nil && e.camera.y == nil && e.camera.moves.isEmpty)
        #expect(e.camera.position == corner.position)
        // The rectangle the old renderer drew: inset from the corner's two edges.
        let W = 1920.0, H = 1080.0, short = 1080.0
        let d = 0.25 * short, inset = 0.04 * short
        let left = corner == .topLeft || corner == .bottomLeft, top = corner == .topLeft || corner == .topRight
        let old = CGRect(x: left ? inset : W - inset - d, y: top ? inset : H - inset - d, width: d, height: d)
        let new = CameraPlacement.frame(at: e.camera.path.position(at: 5), layout: e.camera, width: W, height: H)
        #expect(abs(new.minX - old.minX) < 1e-9 && abs(new.minY - old.minY) < 1e-9 && new.size == old.size, "\(corner): \(new) vs \(old)")
        // Saving it again writes no place of its own, only the corner.
        let out = String(decoding: try JSONCoding.encoder.encode(e.camera), as: UTF8.self)
        #expect(!out.contains("\"x\"") && !out.contains("\"y\""))
        #expect(out.contains("\"roundedSquare\""))
    }
    let empty = try JSONCoding.decoder.decode(CameraLayout.self, from: Data("{}".utf8))
    #expect(empty == CameraLayout() && empty.position == NormPoint(x: 1, y: 1))
    #expect(throws: DecodingError.self) { try JSONCoding.decoder.decode(CameraLayout.self, from: Data(#"{"shape":"hexagon"}"#.utf8)) }
}

@Test func freePlacementAndMovesRoundTrip() throws {
    var c = CameraLayout()
    c.position = NormPoint(x: 0.25, y: 2)   // clamped
    c.moves = [CameraLayout.Move(t: 9, x: 0, y: 0), CameraLayout.Move(t: 3, x: 1, y: 0)]
    let back = try JSONCoding.decoder.decode(CameraLayout.self, from: try JSONCoding.encoder.encode(c))
    #expect(back.position == NormPoint(x: 0.25, y: 1))
    #expect(back.moves.map(\.t) == [3, 9], "moves come back sorted")
    // Only one of x / y set: the other comes from the corner.
    let half = try JSONCoding.decoder.decode(CameraLayout.self, from: Data(#"{"corner":"topLeft","x":0.5}"#.utf8))
    #expect(half.position == NormPoint(x: 0.5, y: 0))
    var pinned = back
    pinned.pin(to: .topRight)
    #expect(pinned.position == NormPoint(x: 1, y: 0) && pinned.moves.isEmpty && pinned.x == nil)
}

// MARK: Mapping

@Test func liveBubbleIsMovedInsideTheCapturedArea() throws {
    let window = CGRect(x: 100, y: 100, width: 800, height: 600)
    // Inside: kept as is.
    let inside = try #require(CameraPlacement.normalizedBubble(frame: CGRect(x: 500, y: 400, width: 200, height: 200), area: window))
    #expect(close(inside.x, 0.5) && close(inside.y, 0.5) && close(inside.width, 0.25) && close(inside.height, 1.0 / 3))
    // Right of and below the window: the nearest place inside is its bottom-right corner.
    let outside = try #require(CameraPlacement.normalizedBubble(frame: CGRect(x: 1200, y: 900, width: 200, height: 200), area: window))
    #expect(close(outside.x + outside.width, 1) && close(outside.y + outside.height, 1))
    // Half over the left edge: slides in, keeps its height.
    let edge = try #require(CameraPlacement.normalizedBubble(frame: CGRect(x: 0, y: 300, width: 200, height: 200), area: window))
    #expect(close(edge.x, 0) && close(edge.y, 200.0 / 600))
    // Larger than a tiny area: centred on that axis.
    let tiny = try #require(CameraPlacement.normalizedBubble(frame: CGRect(x: 0, y: 0, width: 200, height: 200), area: CGRect(x: 0, y: 0, width: 100, height: 400)))
    #expect(close(tiny.x + tiny.width / 2, 0.5))
    #expect(CameraPlacement.normalizedBubble(frame: .zero, area: .zero) == nil)
}

@Test func recordedPlacesMapToTheCanvasRoom() {
    let screen = PixelSize(width: 3024, height: 1964)
    let inset = CameraLayout().inset
    let m = inset * 1964  // the same proportional inset on the screen, in pixels
    func bubble(x: Double, y: Double, d: Double = 400) -> NormRect {
        NormRect(x: x / 3024, y: y / 1964, width: d / 3024, height: d / 1964)
    }
    // At the screen's default corner spot (bottom right, inset like the editor): exactly the corner.
    #expect(CameraPlacement.position(recorded: bubble(x: 3024 - m - 400, y: 1964 - m - 400), screen: screen) == NormPoint(x: 1, y: 1))
    // Flush to the top-left edges: the top-left corner.
    #expect(CameraPlacement.position(recorded: bubble(x: 0, y: 0), screen: screen) == NormPoint(x: 0, y: 0))
    // Centred: centred.
    #expect(CameraPlacement.position(recorded: bubble(x: (3024 - 400) / 2, y: (1964 - 400) / 2), screen: screen) == NormPoint(x: 0.5, y: 0.5))
    // A third of the way across the room it can move in.
    let room = 3024 - 2 * m - 400
    let p = CameraPlacement.position(recorded: bubble(x: m + room / 3, y: 1964 - m - 400), screen: screen)
    #expect(close(p.x, 1.0 / 3, 1e-9) && p.y == 1)
}

@Test func recordedPlacesFollowTheCrop() {
    let screen = PixelSize(width: 2000, height: 1000)
    let crop = CropSpace(NormRect(x: 0, y: 0.2, width: 0.5, height: 0.8))
    // A bubble in the cropped-off right half goes to the visible area's right edge.
    let right = CameraPlacement.position(recorded: NormRect(x: 0.8, y: 0.5, width: 0.05, height: 0.1), screen: screen, crop: crop)
    #expect(right.x == 1)
    // In the hidden top strip: the top edge.
    let top = CameraPlacement.position(recorded: NormRect(x: 0.2, y: 0.01, width: 0.05, height: 0.1), screen: screen, crop: crop)
    #expect(top.y == 0)
    // Centred in the visible part: centred.
    let mid = CameraPlacement.position(recorded: NormRect(x: 0.25 - 0.025, y: 0.6 - 0.05, width: 0.05, height: 0.1), screen: screen, crop: crop)
    #expect(close(mid, NormPoint(x: 0.5, y: 0.5)))
}

@Test func outputFrameKeepsItsSpotAcrossAspectsAndStaysOnCanvas() {
    var layout = CameraLayout()
    for shape in CameraLayout.Shape.allCases {
        layout.shape = shape
        for (W, H) in [(1920.0, 1080.0), (1080.0, 1920.0), (1080.0, 1080.0), (1440.0, 1080.0)] {
            let short = min(W, H), inset = layout.inset * short
            for p in [NormPoint(x: 0, y: 0), NormPoint(x: 1, y: 1), NormPoint(x: 0.5, y: 0.5), NormPoint(x: 0.3, y: 0.9)] {
                let f = CameraPlacement.frame(at: p, layout: layout, width: W, height: H)
                #expect(f.minX >= inset - 1e-9 && f.maxX <= W - inset + 1e-9 && f.minY >= inset - 1e-9 && f.maxY <= H - inset + 1e-9,
                        "\(shape) \(W)×\(H) \(p): \(f)")
                // The inverse gives the place back.
                let back = CameraPlacement.position(origin: f.origin, layout: layout, width: W, height: H)
                #expect(close(back, p, 1e-9))
            }
            let centre = CameraPlacement.frame(at: NormPoint(x: 0.5, y: 0.5), layout: layout, width: W, height: H)
            #expect(close(centre.midX, W / 2, 1e-9) && close(centre.midY, H / 2, 1e-9))
        }
    }
}

@Test func shapesHaveTheirProportionsAndACentredFaceCrop() {
    let c = CameraPlacement.bubbleSize(shape: .circle, size: 0.22, short: 1000)
    let s = CameraPlacement.bubbleSize(shape: .roundedSquare, size: 0.22, short: 1000)
    let p = CameraPlacement.bubbleSize(shape: .portrait, size: 0.22, short: 1000)
    #expect(c.width == 220 && c.height == 220 && s.width == 220 && s.height == 220)
    #expect(close(p.width / p.height, 0.75) && abs(p.width * p.height / (220 * 220) - 1) < 0.02, "portrait \(p)")
    // Portrait from a 4:3 camera: a centred vertical slice, no stretching.
    let fill = CameraPlacement.aspectFill(camera: 4.0 / 3, bubble: 0.75)
    #expect(close(fill.u0 + fill.u1, 1) && fill.v0 == 0 && fill.v1 == 1)
    #expect(close((fill.u1 - fill.u0) * 4 / 3, 0.75))
    let wide = CameraPlacement.aspectFill(camera: 0.5, bubble: 1)
    #expect(close(wide.v0 + wide.v1, 1) && wide.u0 == 0)
    // Squircle corners: continuous (exponent 4), the same radius for square and portrait at equal width.
    let ci = CameraPlacement.corner(shape: .circle, width: 100, height: 100)
    #expect(ci.radius == 50 && ci.exponent == 2)
    let sq = CameraPlacement.corner(shape: .roundedSquare, width: 100, height: 100)
    let po = CameraPlacement.corner(shape: .portrait, width: 100, height: 133)
    #expect(sq.exponent == 4 && sq.radius == po.radius)
}

@Test func outlineMatchesTheShape() {
    let circle = CameraPlacement.outline(shape: .circle, width: 100, height: 100)
    #expect(circle.allSatisfy { abs(hypot($0.x - 50, $0.y - 50) - 50) < 1e-6 })
    for shape in [CameraLayout.Shape.roundedSquare, .portrait] {
        let (w, h) = shape == .portrait ? (75.0, 100.0) : (100.0, 100.0)
        let pts = CameraPlacement.outline(shape: shape, width: w, height: h)
        #expect(pts.allSatisfy { $0.x >= -1e-9 && $0.x <= w + 1e-9 && $0.y >= -1e-9 && $0.y <= h + 1e-9 })
        // Touches the edges; the corner is cut away, but less than a circular corner of that radius would.
        #expect(pts.contains { abs($0.y) < 1e-9 } && pts.contains { abs($0.x - w) < 1e-9 })
        let (r, _) = CameraPlacement.corner(shape: shape, width: w, height: h)
        let diag = pts.map { hypot($0.x, $0.y) }.min()!
        #expect(diag > 0.1 * r && diag < r * (2.0.squareRoot() - 1), "squircle corner is fuller than a circular one: \(diag)")
    }
}

// MARK: Glide

@Test func glideEasesBetweenPlaces() {
    var c = CameraLayout()
    c.position = NormPoint(x: 1, y: 1)
    c.moves = [CameraLayout.Move(t: 10, x: 0, y: 0)]
    let path = c.path
    #expect(path.position(at: 0) == NormPoint(x: 1, y: 1))
    #expect(path.position(at: 9.999) == NormPoint(x: 1, y: 1))
    #expect(path.position(at: 10) == NormPoint(x: 1, y: 1))
    #expect(close(path.position(at: 10.15), NormPoint(x: 0.5, y: 0.5)), "halfway through the glide")
    let early = path.position(at: 10.03), late = path.position(at: 10.27)
    #expect(early.x > 0.95 && late.x < 0.05, "ease in and out: \(early) \(late)")
    #expect(path.position(at: 10.3) == NormPoint(x: 0, y: 0))
    #expect(path.position(at: 60) == NormPoint(x: 0, y: 0))
    #expect(path.isMoving(at: 10.1) && !path.isMoving(at: 10.31) && !path.isMoving(at: 5))
    // Monotonic along the glide.
    var prev = 1.0
    for i in 0...30 {
        let x = path.position(at: 10 + Double(i) * 0.01).x
        #expect(x <= prev + 1e-12)
        prev = x
    }
}

@Test func overlappingMovesStayContinuous() {
    var c = CameraLayout()
    c.position = NormPoint(x: 0, y: 0)
    c.moves = [CameraLayout.Move(t: 1, x: 1, y: 0), CameraLayout.Move(t: 1.15, x: 1, y: 1)]
    let path = c.path
    let before = path.position(at: 1.15 - 1e-6), at = path.position(at: 1.15)
    #expect(close(before, at, 1e-4), "no jump when a move starts mid-glide: \(before) → \(at)")
    #expect(path.position(at: 1.45) == NormPoint(x: 1, y: 1))
}

@Test func editingSetsThePlaceInEffect() {
    var c = CameraLayout()
    c.moves = [CameraLayout.Move(t: 5, x: 0, y: 0), CameraLayout.Move(t: 8, x: 1, y: 0)]
    c.setPosition(NormPoint(x: 0.5, y: 0.5), at: 2)
    #expect(c.position == NormPoint(x: 0.5, y: 0.5) && c.moves[0].x == 0)
    c.setPosition(NormPoint(x: 0.2, y: 0.3), at: 6)
    #expect(c.moves[0].position == NormPoint(x: 0.2, y: 0.3))
    c.setPosition(NormPoint(x: 0.7, y: 0.7), at: 30)
    #expect(c.moves[1].position == NormPoint(x: 0.7, y: 0.7))
    #expect(c.moveIndex(at: 4.9) == nil && c.moveIndex(at: 5) == 0)
}

@Test func dragSnapsToEdgesAndCentreLines() {
    let layout = CameraLayout()
    // 1000×500 canvas: bubble 110 px, inset 17.5 px; room 855 × 355.
    let s1 = CameraPlacement.snapped(NormPoint(x: 0.004, y: 0.5), layout: layout, width: 1000, height: 500, tolerance: 6)
    #expect(s1.position == NormPoint(x: 0, y: 0.5) && s1.guides == [.left, .centerY])
    let s2 = CameraPlacement.snapped(NormPoint(x: 0.503, y: 0.995), layout: layout, width: 1000, height: 500, tolerance: 6)
    #expect(s2.position == NormPoint(x: 0.5, y: 1) && s2.guides == [.centerX, .bottom])
    let s3 = CameraPlacement.snapped(NormPoint(x: 0.3, y: 0.3), layout: layout, width: 1000, height: 500, tolerance: 6)
    #expect(s3.position == NormPoint(x: 0.3, y: 0.3) && s3.guides.isEmpty)
}

// MARK: From the recording

@Test func initialEditPlacesTheCameraFromEvents() throws {
    var manifest = ProjectManifest(title: "t", appVersion: "test",
                                   capture: CaptureInfo(source: .synthetic(name: "t"), pixelSize: PixelSize(width: 2000, height: 1000), scale: 2, frameRate: 60),
                                   clock: ClockInfo(originHostTime: 0), duration: 30)
    manifest.tracks = [TrackInfo(kind: .screen, directory: "screen", codec: "hevc", pixelSize: PixelSize(width: 2000, height: 1000)),
                       TrackInfo(kind: .camera, directory: "camera", codec: "h264", pixelSize: PixelSize(width: 1280, height: 720))]
    let m = 0.035 * 1000
    let d = 200.0
    func at(_ x: Double, _ y: Double) -> NormRect { NormRect(x: x / 2000, y: y / 1000, width: d / 2000, height: d / 1000) }
    let events: [InputEvent] = [
        .move(0, NormPoint(x: 0.5, y: 0.5)),
        .camera(0, frame: at(2000 - m - d, 1000 - m - d), shape: .portrait),   // bottom right
        .camera(4, frame: at(2000 - m - d, 1000 - m - d), shape: .portrait),   // same place (a resize): no move
        .camera(12, frame: at(0, 0), shape: .portrait),                         // top left
        .camera(20, frame: at((2000 - d) / 2, 1000 - m - d), shape: .portrait), // bottom centre
    ]
    let e = EditDocument.initial(for: manifest, events: events)
    #expect(e.camera.shape == .portrait)
    #expect(e.camera.position == NormPoint(x: 1, y: 1) && e.camera.x == nil, "starts pinned to the default corner")
    #expect(e.camera.moves == [CameraLayout.Move(t: 12, x: 0, y: 0), CameraLayout.Move(t: 20, x: 0.5, y: 1)])
    // No camera events (an older recording): the default corner, no moves.
    let plain = EditDocument.initial(for: manifest, events: [.move(0, .center)])
    #expect(plain.camera == EditDocument.initial(for: manifest).camera)
    // No camera track: events are ignored.
    manifest.tracks.removeLast()
    #expect(EditDocument.initial(for: manifest, events: events).camera.moves.isEmpty)
}
