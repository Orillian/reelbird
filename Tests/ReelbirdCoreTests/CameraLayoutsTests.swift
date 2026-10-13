import Foundation
import Testing
@testable import ReelbirdCore

private func seg(_ kind: LayoutSegment.Kind, _ a: Double, _ b: Double, id: String? = nil) -> LayoutSegment {
    LayoutSegment(id: id ?? "\(kind.rawValue)-\(a)", range: TimeRange(start: a, end: b), kind: kind)
}

@Test func editsWithoutLayoutsOrZoomedSizeStillOpen() throws {
    // An edit.json from before layouts and the zoomed size: the new keys take their defaults.
    let old = #"{"formatVersion":1,"camera":{"visible":true,"shape":"circle","size":0.3,"corner":"topLeft"}}"#
    let e = try JSONCoding.decoder.decode(EditDocument.self, from: Data(old.utf8))
    #expect(e.layouts.isEmpty)
    #expect(e.camera.size == 0.3 && e.camera.corner == .topLeft)
    #expect(e.camera.shrinkWhenZoomed && e.camera.smartFraming && e.camera.sizeWhileZoomed == 0.7)

    // New keys round-trip; an out-of-range size while zoomed is clamped; a layout this version doesn't know is
    // skipped instead of failing the document; overlapping segments are tidied.
    let new = #"""
    {"camera":{"sizeWhileZoomed":0.1,"shrinkWhenZoomed":false,"smartFraming":false},
     "layouts":[{"id":"b","range":{"start":4,"end":9},"kind":"split"},
                {"id":"a","range":{"start":1,"end":5},"kind":"fullCamera"},
                {"id":"x","range":{"start":10,"end":12},"kind":"pictureInPicture"},
                {"id":"c","range":{"start":12,"end":13},"kind":"screenOnly"}]}
    """#
    let n = try JSONCoding.decoder.decode(EditDocument.self, from: Data(new.utf8))
    #expect(n.camera.sizeWhileZoomed == CameraPlacement.zoomedSizeRange.lowerBound)
    #expect(!n.camera.shrinkWhenZoomed && !n.camera.smartFraming)
    #expect(n.layouts.map(\.id) == ["a", "b", "c"])
    #expect(n.layouts[0].range == TimeRange(start: 1, end: 4), "an overlap ends where the next starts")
    let again = try JSONCoding.decoder.decode(EditDocument.self, from: JSONCoding.encoder.encode(n))
    #expect(again == n)
}

@Test func layoutSegmentsAreNormalized() {
    let s = LayoutSegment.normalized([seg(.split, 5, 6), seg(.fullCamera, -1, 2), seg(.screenOnly, 3, 3.1), seg(.split, .nan, 4)])
    #expect(s.map(\.kind) == [.fullCamera, .split])
    #expect(s[0].range == TimeRange(start: 0, end: 2), "clamped to the start of the recording")
    // A segment swallowed by the next one's start is dropped.
    let t = LayoutSegment.normalized([seg(.split, 1, 3), seg(.fullCamera, 1.1, 4)])
    #expect(t.map(\.kind) == [.fullCamera])
}

@Test func layoutChangesSpringAcrossTheEdges() {
    let tl = LayoutTimeline([seg(.fullCamera, 4, 10)], duration: 20)
    let d = LayoutTimeline.transitionDuration
    #expect(tl.state(at: 0) == .overlay)
    #expect(tl.state(at: 4 - d / 2 - 0.01) == .overlay, "before the change")
    let start = tl.state(at: 4 - d / 2)
    #expect(start.from == .overlay && start.to == .fullCamera && start.progress == 0)
    let mid = tl.state(at: 4)
    #expect(mid.from == .overlay && mid.to == .fullCamera)
    #expect(abs(mid.progress - LayoutTimeline.ease(0.5)) < 1e-9 && mid.progress > 0.5, "springy: past halfway at the edge")
    #expect(tl.state(at: 4 + d / 2).kind == .fullCamera && tl.state(at: 4 + d / 2).isSteady)
    #expect(tl.state(at: 7) == LayoutTimeline.State(from: .fullCamera, to: .fullCamera, progress: 1))
    let back = tl.state(at: 10)
    #expect(back.from == .fullCamera && back.to == .overlay)
    #expect(tl.state(at: 11) == LayoutTimeline.State(from: .overlay, to: .overlay, progress: 1))
    // Monotonic through each change.
    var last = -1.0
    for i in 0...50 {
        let p = tl.state(at: 4 - d / 2 + d * Double(i) / 50).progress
        #expect(p >= last - 1e-12)
        last = p
    }
    #expect(LayoutTimeline.ease(0) == 0 && abs(LayoutTimeline.ease(1) - 1) < 1e-12)
}

@Test func layoutEdgesBackToBackAtTheEndsAndCloseTogether() {
    // Back to back: straight from camera to split, no bubble in between.
    let tl = LayoutTimeline([seg(.fullCamera, 2, 5), seg(.split, 5, 8)], duration: 20)
    let at5 = tl.state(at: 5)
    #expect(at5.from == .fullCamera && at5.to == .split)
    #expect(tl.state(at: 6) .kind == .split)
    #expect(tl.state(at: 8).from == .split && tl.state(at: 8).to == .overlay)
    // A segment from 0 is there from the first frame; one to the end stays to the last.
    let ends = LayoutTimeline([seg(.screenOnly, 0, 3), seg(.fullCamera, 15, 20)], duration: 20)
    #expect(ends.state(at: 0) == LayoutTimeline.State(from: .screenOnly, to: .screenOnly, progress: 1))
    #expect(ends.state(at: 19.99).kind == .fullCamera && ends.state(at: 19.99).isSteady)
    #expect(ends.state(at: 25).kind == .fullCamera)
    // Edges closer than the transition share the time between them.
    let short = LayoutTimeline([seg(.fullCamera, 5, 5.3)], duration: 20)
    #expect(short.state(at: 5 - 0.16) == .overlay, "before a 0.3 s change")
    #expect(short.state(at: 5.15).weight(.fullCamera) == 1, "fully in at the middle, then straight back out")
    #expect(short.state(at: 5.3).from == .fullCamera && short.state(at: 5.3).to == .overlay)
    #expect(short.state(at: 5.46) == LayoutTimeline.State(from: .overlay, to: .overlay, progress: 1))
    #expect(LayoutTimeline([], duration: 10).isEmpty)
}

@Test func insertingALayoutGivesWay() {
    let base = [seg(.split, 2, 10, id: "s")]
    let out = LayoutSegment.inserting(seg(.fullCamera, 4, 6, id: "c"), into: base)
    #expect(out.map(\.kind) == [.split, .fullCamera, .split])
    #expect(out[0].id == "s" && out[0].range == TimeRange(start: 2, end: 4))
    #expect(out[2].range == TimeRange(start: 6, end: 10))
    // A bubble range clears.
    let cleared = LayoutSegment.inserting(seg(.overlay, 0, 5), into: out)
    #expect(cleared.map(\.kind) == [.fullCamera, .split] && cleared[0].range == TimeRange(start: 5, end: 6))
}

@Test func liveLayoutEventsSeedTheFirstEdit() throws {
    let r = NormRect(x: 0.8, y: 0.75, width: 0.1, height: 0.18)
    let events: [InputEvent] = [
        .camera(0, frame: r, shape: .circle),
        .move(1, NormPoint(x: 0.5, y: 0.5)),
        .camera(3, frame: r, shape: .circle, layout: .fullCamera),
        .camera(5, frame: NormRect(x: 0, y: 0, width: 0.1, height: 0.18), shape: .circle, layout: .fullCamera), // a drag
        .camera(7, frame: r, shape: .circle, layout: .screenOnly),
        .camera(9, frame: r, shape: .circle, layout: .overlay),
        .camera(12, frame: r, shape: .circle, layout: .fullCamera),
    ]
    let segs = LayoutSegment.segments(fromLive: events, duration: 15)
    #expect(segs.map(\.kind) == [.fullCamera, .screenOnly, .fullCamera])
    #expect(segs.map(\.range) == [TimeRange(start: 3, end: 7), TimeRange(start: 7, end: 9), TimeRange(start: 12, end: 15)])

    var m = ProjectManifest(title: "t", appVersion: "test",
                            capture: CaptureInfo(source: .synthetic(name: "t"), pixelSize: PixelSize(width: 1920, height: 1080), scale: 2, frameRate: 60),
                            clock: ClockInfo(originHostTime: 0), duration: 15)
    m.tracks = [TrackInfo(kind: .screen, directory: "screen", codec: "hevc", pixelSize: PixelSize(width: 1920, height: 1080)),
                TrackInfo(kind: .camera, directory: "camera", codec: "h264", pixelSize: PixelSize(width: 1280, height: 720))]
    let e = EditDocument.initial(for: m, events: events)
    #expect(e.layouts.map(\.kind) == [.fullCamera, .screenOnly, .fullCamera])
    // Without a camera track, nothing is seeded.
    m.tracks.removeLast()
    #expect(EditDocument.initial(for: m, events: events).layouts.isEmpty)

    // The event line keeps its layout through the fast parser.
    let line = #"{"layout":"screenOnly","rect":{"height":0.18,"width":0.1,"x":0.8,"y":0.75},"shape":"circle","t":7,"type":"camera","x":0.85,"y":0.84}"#
    let parsed = line.utf8.withContiguousStorageIfAvailable { FlatEventParser.parse(UnsafeBufferPointer(start: $0.baseAddress, count: $0.count)) } ?? nil
    #expect(parsed?.layout == "screenOnly" && parsed?.type == .camera)
}

@Test func bubbleShrinksIntoItsCorner() {
    var layout = CameraLayout()
    layout.size = 0.3
    let W = 1920.0, H = 1080.0
    let full = CameraPlacement.frame(at: NormPoint(x: 1, y: 1), layout: layout, width: W, height: H)
    let small = CameraPlacement.frame(at: NormPoint(x: 1, y: 1), layout: layout, width: W, height: H, sizeScale: 0.7)
    #expect(abs(small.width - full.width * 0.7) < 1e-9)
    #expect(abs(small.maxX - full.maxX) < 1e-9 && abs(small.maxY - full.maxY) < 1e-9, "stays against the same edges")
    let centred = CameraPlacement.frame(at: NormPoint(x: 0.5, y: 0.5), layout: layout, width: W, height: H, sizeScale: 0.5)
    #expect(abs(centred.midX - W / 2) < 1e-9 && abs(centred.midY - H / 2) < 1e-9)
}
