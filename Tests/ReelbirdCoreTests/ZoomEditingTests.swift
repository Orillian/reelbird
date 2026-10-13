import Foundation
import Testing
@testable import ReelbirdCore

// Zoom handling: turning zooms off, instant cuts, depth keys, copy/paste, multi-select, and files from
// before these existed.

private func zoom(_ id: String, _ start: Double, _ end: Double, scale: Double = 2, source: ZoomRegion.Source = .user,
                  enabled: Bool = true, instant: Bool = false) -> ZoomRegion {
    ZoomRegion(id: id, range: TimeRange(start: start, end: end), scale: scale, focus: NormPoint(x: 0.3, y: 0.4),
               source: source, enabled: enabled, instant: instant)
}

// MARK: - Format

@Test func zoomRegionsFromOlderFilesAreOnAndAnimated() throws {
    let old = #"{"zoom":{"mode":"manual","intensity":0.5,"regions":[{"id":"z1","range":{"start":1,"end":3},"scale":2,"source":"user"}]}}"#
    let e = try JSONCoding.decoder.decode(EditDocument.self, from: Data(old.utf8))
    let r = try #require(e.zoom.regions.first)
    #expect(r.enabled && !r.instant && r.scale == 2 && r.id == "z1" && r.source == .user)
    // Newer files round-trip both flags.
    var z = r
    z.enabled = false
    z.instant = true
    let data = try JSONCoding.encoder.encode(z)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["enabled"] as? Bool == false && json["instant"] as? Bool == true)
    #expect(try JSONCoding.decoder.decode(ZoomRegion.self, from: data) == z)
    // A source from a newer version reads as a zoom you made instead of failing the whole edit.
    let future = #"{"id":"f","range":{"start":0,"end":1},"scale":1.5,"source":"agent"}"#
    #expect(try JSONCoding.decoder.decode(ZoomRegion.self, from: Data(future.utf8)).source == .user)
}

// MARK: - Editing

@Test func digitKeysSetDepthsInQuarterSteps() {
    #expect(ZoomEditing.depth(forDigit: 0) == nil)
    #expect(ZoomEditing.depth(forDigit: 1) == 1.25)
    #expect(ZoomEditing.depth(forDigit: 4) == 2)
    #expect(ZoomEditing.depth(forDigit: 8) == 3)
    #expect(ZoomEditing.depth(forDigit: 9) == ZoomEditing.maxDepth)
    #expect(ZoomEditing.depth(forDigit: 10) == nil)
    #expect(ZoomEditing.digitDepths == ZoomEditing.digitDepths.sorted())
}

@Test func boxSelectionPicksZoomsItTouches() {
    let rs = [zoom("c", 10, 12), zoom("a", 1, 3), zoom("b", 4, 6)]
    #expect(ZoomEditing.ids(overlapping: TimeRange(start: 2.5, end: 4.2), in: rs) == ["a", "b"])
    // Dragged right to left.
    #expect(ZoomEditing.ids(overlapping: TimeRange(start: 11, end: 5), in: rs) == ["b", "c"])
    #expect(ZoomEditing.ids(overlapping: TimeRange(start: 6.5, end: 9), in: rs).isEmpty)
    // Shift-click adds and removes.
    let s = ZoomEditing.toggling("b", in: ["a"])
    #expect(s == ["a", "b"] && ZoomEditing.toggling("a", in: s) == ["b"])
}

@Test func copyAndPasteKeepSpacingAndSettings() {
    let rs = [zoom("a", 2, 4, scale: 1.5), zoom("b", 6, 7, scale: 3, instant: true), zoom("c", 20, 22, source: .auto)]
    let clip = ZoomEditing.copy(["b", "a"], from: rs)
    #expect(clip.map(\.id) == ["a", "b"])
    var n = 0
    let (out, pasted) = ZoomEditing.paste(clip, at: 19, into: rs, duration: 30) { n += 1; return "p\(n)" }
    #expect(pasted == ["p1", "p2"])
    let p1 = out.first { $0.id == "p1" }, p2 = out.first { $0.id == "p2" }
    #expect(p1?.range == TimeRange(start: 19, end: 21) && p1?.scale == 1.5 && p1?.source == .user)
    #expect(p2?.range == TimeRange(start: 23, end: 24) && p2?.instant == true && p2?.scale == 3)
    // The automatic zoom they cover is replaced; your own zooms stay.
    #expect(!out.contains { $0.id == "c" } && out.contains { $0.id == "a" } && out.contains { $0.id == "b" })
    #expect(out.map(\.range.start) == out.map(\.range.start).sorted())
    // Near the end: clamped, and zooms that would start past it are dropped.
    let late = ZoomEditing.paste(clip, at: 28.5, into: [], duration: 30) { "x" }
    #expect(late.pasted.count == 1 && late.regions[0].range == TimeRange(start: 28.5, end: 30))
    #expect(ZoomEditing.paste([], at: 3, into: rs, duration: 30).pasted.isEmpty)
}

@Test func toggleDepthAndInstantWorkOnSeveralZooms() {
    let rs = [zoom("a", 1, 2, source: .auto), zoom("b", 3, 4, enabled: false), zoom("c", 5, 6)]
    // Mixed: turning off wins; all off: back on.
    let off = ZoomEditing.togglingEnabled(["a", "b"], in: rs)
    #expect(off.filter { ["a", "b"].contains($0.id) }.allSatisfy { !$0.enabled })
    #expect(off[0].source == .user, "a touched automatic zoom becomes yours")
    let on = ZoomEditing.togglingEnabled(["a", "b"], in: off)
    #expect(on.filter { ["a", "b"].contains($0.id) }.allSatisfy { $0.enabled })
    #expect(on[2] == rs[2], "zooms outside the selection are untouched")

    let instant = ZoomEditing.togglingInstant(["a", "c"], in: rs)
    #expect(instant[0].instant && instant[2].instant && !instant[1].instant)
    #expect(!ZoomEditing.togglingInstant(["a", "c"], in: instant)[0].instant)

    let deep = ZoomEditing.settingDepth(2.75, for: ["b", "c"], in: rs)
    #expect(deep[1].scale == 2.75 && deep[1].enabled, "setting a depth turns the zoom back on")
    #expect(deep[2].scale == 2.75 && deep[0].scale == 2)
    #expect(ZoomEditing.settingDepth(9, for: ["c"], in: rs)[2].scale == ZoomEditing.maxDepth)
    // Unchanged zooms keep their source.
    #expect(ZoomEditing.settingDepth(2, for: ["a"], in: rs)[0].source == .auto)
}

@Test func outsideEditsMakeAutomaticZoomsYours() {
    let before = [zoom("auto-1", 1, 2, source: .auto), zoom("auto-2", 3, 4, source: .auto)]
    var after = before
    after[1].enabled = false
    let marked = ZoomEditing.markingEdited(after, before: before)
    #expect(marked[0].source == .auto && marked[1].source == .user)
}

@Test func plannerKeepsZoomsYouTurnedOff() {
    // A click at 5 s would plan an automatic zoom there; the one turned off keeps that moment unzoomed.
    let ev: [InputEvent] = [.move(0, NormPoint(x: 0.5, y: 0.5)), .down(5, NormPoint(x: 0.4, y: 0.4)), .up(5.1, NormPoint(x: 0.4, y: 0.4))]
    let fresh = AutoZoomPlanner.plan(events: ev, duration: 20, intensity: 0.5)
    guard var off = fresh.first else { Issue.record("no automatic zoom planned for the click"); return }
    off.enabled = false
    let merged = AutoZoomPlanner.merged(existing: [off], events: ev, duration: 20, intensity: 0.5)
    #expect(merged.contains(off))
    #expect(!merged.contains { $0.enabled && $0.range.overlaps(off.range) })
}

// MARK: - Camera path

@Test func cameraSkipsZoomsTurnedOff() {
    let cur = CursorPath(events: [], smoothing: 0.5)
    let cam = CameraPath(regions: [zoom("a", 2, 6, enabled: false)], cursor: cur, duration: 10)
    #expect(cam.regions.isEmpty)
    for t in stride(from: 0.0, through: 10, by: 0.25) { #expect(abs(cam.transform(at: t).scale - 1) < 1e-9) }
}

@Test func instantZoomCutsWithoutInBetweenFrames() {
    let cur = CursorPath(events: [], smoothing: 0.5)
    let cam = CameraPath(regions: [zoom("a", 2, 6, scale: 2.5, instant: true)], cursor: cur, duration: 10)
    #expect(cam.cutTimes.count == 2)
    // Every frame at 60 fps is either fully wide or fully zoomed: no animation.
    var sawZoom = false
    for f in 0..<600 {
        let s = cam.transform(at: Double(f) / 60).scale
        #expect(abs(s - 1) < 1e-6 || abs(s - 2.5) < 1e-3, "frame \(f): \(s)")
        if abs(s - 2.5) < 1e-3 { sawZoom = true }
    }
    #expect(sawZoom)
    #expect(abs(cam.transform(at: 1.99).scale - 1) < 1e-6 && abs(cam.transform(at: 2.01).scale - 2.5) < 1e-3)
    #expect(abs(cam.transform(at: 5.99).scale - 2.5) < 1e-3 && abs(cam.transform(at: 6.01).scale - 1) < 1e-6)
    #expect(abs(cam.transform(at: 2.01).center.x - 0.3) < 1e-3)
    // Motion blur asks whether a cut falls between two times.
    #expect(cam.hasCut(after: 1.99, upTo: 2.01) && cam.hasCut(after: 5.9, upTo: 6.1))
    #expect(!cam.hasCut(after: 2.1, upTo: 5.9) && !cam.hasCut(after: 0, upTo: 1.9))
    // The same zoom animated passes through in-between scales.
    let smooth = CameraPath(regions: [zoom("a", 2, 6, scale: 2.5)], cursor: cur, duration: 10)
    #expect(smooth.cutTimes.isEmpty)
    #expect((1.05...2.45).contains(smooth.transform(at: 2).scale))
}

@Test func instantZoomNextToAnimatedOnesStaysClean() {
    let cur = CursorPath(events: [], smoothing: 0.5)
    // Animated zoom straight into an instant one, then another animated one right after.
    let rs = [zoom("a", 1, 4), zoom("b", 4.2, 6, scale: 3, instant: true), zoom("c", 6.2, 9)]
    let cam = CameraPath(regions: rs, cursor: cur, duration: 12)
    #expect(cam.cutTimes.count == 2)
    // Inside the instant zoom: its depth exactly.
    #expect(abs(cam.transform(at: 5).scale - 3) < 1e-3)
    // Times stay ordered and finite everywhere.
    for f in 0..<720 {
        let (s, c) = cam.transform(at: Double(f) / 60)
        #expect(s.isFinite && s >= 1 - 1e-9 && c.x.isFinite && c.y.isFinite)
    }
    // Two instant zooms back to back cut straight from one to the other.
    let pair = CameraPath(regions: [zoom("x", 1, 3, scale: 2, instant: true), zoom("y", 3, 5, scale: 3, instant: true)],
                          cursor: cur, duration: 6)
    #expect(abs(pair.transform(at: 2.99).scale - 2) < 1e-3 && abs(pair.transform(at: 3.01).scale - 3) < 1e-3)
}
