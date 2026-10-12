import Foundation
import Testing
@testable import ReelbirdCore

// MARK: - Spring

@Test func springEaseEndpointsAndMonotonic() {
    #expect(Spring.ease(0) == 0)
    #expect(Spring.ease(1) == 1)
    var prev = 0.0
    for i in 1...100 {
        let v = Spring.ease(Double(i) / 100)
        #expect(v >= prev)
        prev = v
    }
    #expect(abs(Spring.zoomDuration(from: 1, to: 1.8) - (0.6 + 0.55 * log(1.8))) < 1e-12)
}

// MARK: - Cursor

private func noisyLine(seconds: Double, rate: Double = 120, seed: UInt64 = 7) -> [InputEvent] {
    var rng = SplitMix(seed: seed)
    let n = Int(seconds * rate)
    return (0..<n).map { i in
        let t = Double(i) / rate
        let x = 0.1 + 0.8 * (t / seconds) + (rng.unit() - 0.5) * 0.01
        let y = 0.5 + (rng.unit() - 0.5) * 0.01
        return .move(t, NormPoint(x: x, y: y))
    }
}

@Test func cursorPathIsDeterministic() {
    let ev = noisyLine(seconds: 5)
    let a = CursorPath(events: ev, smoothing: 0.6), b = CursorPath(events: ev.reversed(), smoothing: 0.6)
    for i in 0..<500 {
        let t = Double(i) * 0.01
        #expect(a.position(at: t) == b.position(at: t))
    }
}

@Test func cursorRawFollowsSamplesAndSmoothingRemovesJitter() throws {
    let ev = noisyLine(seconds: 4)
    let raw = CursorPath(events: ev, smoothing: 0)
    let p = try #require(raw.position(at: ev[100].t))
    #expect(abs(p.x - ev[100].x!) < 1e-5 && abs(p.y - ev[100].y!) < 1e-5)

    func jitter(_ c: CursorPath) -> Double {
        var s = 0.0
        for i in 60..<400 { s += abs(c.position(at: Double(i) / 120)!.y - 0.5) }
        return s / 340
    }
    let smooth = CursorPath(events: ev, smoothing: 0.8)
    #expect(jitter(smooth) < jitter(raw) * 0.5)
    // Lag compensation: the smoothed cursor tracks the line, not far behind it.
    let mid = smooth.position(at: 2)!.x
    #expect(abs(mid - (0.1 + 0.8 * 0.5)) < 0.03)
}

@Test func cursorClicksLandExactly() throws {
    var ev: [InputEvent] = []
    for i in 0..<240 { ev.append(.move(Double(i) / 120, NormPoint(x: Double(i) / 240, y: 0.3))) }
    ev.append(.down(1.0, NormPoint(x: 0.7, y: 0.6)))
    ev.append(.up(1.08, NormPoint(x: 0.7, y: 0.6)))
    let c = CursorPath(events: ev, smoothing: 1)
    let p = try #require(c.position(at: 1.0))
    #expect(abs(p.x - 0.7) < 1e-4 && abs(p.y - 0.6) < 1e-4)
    #expect(c.clicks(near: 1.1, window: 0.2).count == 1)
    #expect(c.clicks(near: 3, window: 0.2).isEmpty)
    var seen = 0
    c.forEachRecentClick(before: 1.3, window: 0.5, limit: 4) { _ in seen += 1 }
    #expect(seen == 1)
}

@Test func cursorImagesAndIdleHide() {
    let ev: [InputEvent] = [
        InputEvent(t: 0.5, type: .cursor, image: "arrow"),
        .move(1, NormPoint(x: 0.2, y: 0.2)),
        .move(1.05, NormPoint(x: 0.25, y: 0.2)),
        InputEvent(t: 2, type: .cursor, image: "ibeam"),
        .move(10, NormPoint(x: 0.5, y: 0.5)),
    ]
    let c = CursorPath(events: ev, smoothing: 0.5)
    #expect(c.imageID(at: 0) == "arrow")
    #expect(c.imageID(at: 1.9) == "arrow")
    #expect(c.imageID(at: 2.1) == "ibeam")
    #expect(c.opacity(at: 1.5, hideAfter: 2) == 1)
    #expect(c.opacity(at: 5, hideAfter: 2) == 0)
    #expect(c.opacity(at: 10, hideAfter: 2) == 1)
    #expect(c.opacity(at: 5, hideAfter: 0) == 1)
    #expect(CursorPath(events: [], smoothing: 0.5).position(at: 1) == nil)
}

@Test func cursorOneHourBuildsFast() {
    let ev = noisyLine(seconds: 3600, rate: 120)
    let clock = ContinuousClock()
    var path: CursorPath?
    let elapsed = clock.measure { path = CursorPath(events: ev, smoothing: 0.6) }
    print("CursorPath 1 h @120 Hz (\(ev.count) events): \(elapsed)")
    #expect(elapsed < .milliseconds(500))
    let sampleTime = clock.measure {
        var acc = 0.0
        for i in 0..<100_000 { acc += path!.position(at: Double(i) * 0.036)!.x }
        #expect(acc > 0)
    }
    print("CursorPath 100k lookups: \(sampleTime)")
}

// MARK: - Auto-zoom

@Test func plannerSingleClickShot() throws {
    let ev: [InputEvent] = [.down(5, NormPoint(x: 0.5, y: 0.5))]
    let r = AutoZoomPlanner.plan(events: ev, duration: 20, intensity: 0.5)
    #expect(r.count == 1)
    let z = try #require(r.first)
    #expect(abs(z.range.start - 4.4) < 1e-9)
    #expect(abs(z.range.end - 6.8) < 1e-9)
    #expect(abs(z.scale - 2.0) < 1e-9)
    #expect(z.source == .auto)
    #expect(z.focus == NormPoint(x: 0.5, y: 0.5))
}

@Test func plannerClampsFocusIntoFrame() throws {
    let r = AutoZoomPlanner.plan(events: [.down(3, NormPoint(x: 0.99, y: 0.01))], duration: 10, intensity: 1)
    let z = try #require(r.first)
    let f = try #require(z.focus)
    let half = 0.5 / z.scale
    #expect(f.x <= 1 - half + 1e-9 && f.y >= half - 1e-9)
}

@Test func plannerClustersMergesAndPans() {
    // Two clicks 1 s apart close together: one shot.
    let one = AutoZoomPlanner.plan(events: [.down(2, NormPoint(x: 0.4, y: 0.4)), .down(3, NormPoint(x: 0.45, y: 0.42))],
                                   duration: 20, intensity: 0.5)
    #expect(one.count == 1)
    // Far apart in time: two shots with a wide shot between.
    let two = AutoZoomPlanner.plan(events: [.down(2, NormPoint(x: 0.4, y: 0.4)), .down(12, NormPoint(x: 0.6, y: 0.6))],
                                   duration: 20, intensity: 0.5)
    #expect(two.count == 2)
    #expect(two[1].range.start - two[0].range.end > 1.2)
    // Close in time, far apart in space: two adjacent shots (the camera pans).
    let pan = AutoZoomPlanner.plan(events: [.down(2, NormPoint(x: 0.1, y: 0.1)), .down(3.5, NormPoint(x: 0.9, y: 0.9))],
                                   duration: 20, intensity: 0.5)
    #expect(pan.count == 2)
    #expect(abs(pan[0].range.end - pan[1].range.start) < 1e-9)
    // Bounding box sets depth: a wide cluster zooms less than a single click.
    #expect(one[0].scale <= 2.0)
    let wide = AutoZoomPlanner.plan(events: [.down(2, NormPoint(x: 0.3, y: 0.5)), .down(3, NormPoint(x: 0.6, y: 0.5))],
                                    duration: 20, intensity: 1)
    #expect(wide.count == 1 && wide[0].scale < 2.2)
}

@Test func plannerIgnoresStopClickAndIsDeterministic() {
    #expect(AutoZoomPlanner.plan(events: [.down(9.5, NormPoint(x: 0.5, y: 0.5))], duration: 10, intensity: 0.5).isEmpty)
    var rng = SplitMix(seed: 3)
    let ev = (0..<200).map { i in InputEvent.down(Double(i) * 1.7 + rng.unit(), NormPoint(x: rng.unit(), y: rng.unit())) }
    let a = AutoZoomPlanner.plan(events: ev, duration: 400, intensity: 0.7)
    let b = AutoZoomPlanner.plan(events: ev.shuffled(), duration: 400, intensity: 0.7)
    #expect(a == b)
    for i in a.indices.dropFirst() { #expect(a[i].range.start >= a[i - 1].range.end - 1e-9) }
    let subtle = AutoZoomPlanner.plan(events: [.down(5, .center)], duration: 20, intensity: 0)
    let punchy = AutoZoomPlanner.plan(events: [.down(5, .center)], duration: 20, intensity: 1)
    #expect(subtle[0].scale < punchy[0].scale)
}

@Test func plannerZoomsOnTypingBursts() throws {
    var ev: [InputEvent] = [InputEvent(t: 1, type: .focus, rect: NormRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05))]
    for i in 0..<12 { ev.append(InputEvent(t: 3 + Double(i) * 0.2, type: .key, chars: "a")) }
    ev.append(InputEvent(t: 8, type: .key, chars: "s", mods: ["⌘"]))
    let r = AutoZoomPlanner.plan(events: ev, duration: 20, intensity: 0.5)
    #expect(r.count == 1)
    let f = try #require(r.first?.focus)
    #expect(abs(f.y - 0.25) < 0.01 || f.y < 0.4)
    #expect(r[0].range.start < 3 && r[0].range.end > 5.2)
}

@Test func plannerKeepsUserRegions() {
    let user = ZoomRegion(id: "u", range: TimeRange(start: 4, end: 7), scale: 3, focus: .center, source: .user)
    let staleAuto = ZoomRegion(id: "old", range: TimeRange(start: 10, end: 12), scale: 2, source: .auto)
    let ev: [InputEvent] = [.down(5, .center), .down(15, .center)]
    let m = AutoZoomPlanner.merged(existing: [user, staleAuto], events: ev, duration: 30, intensity: 0.5)
    #expect(m.contains(user))
    #expect(!m.contains { $0.id == "old" })
    #expect(m.count == 2)
}

// MARK: - Camera

@Test func cameraHoldsRegionAndIsWideOutside() {
    let cur = CursorPath(events: [], smoothing: 0.5)
    let r = ZoomRegion(id: "a", range: TimeRange(start: 2, end: 6), scale: 2, focus: NormPoint(x: 0.3, y: 0.7))
    let cam = CameraPath(regions: [r], cursor: cur, duration: 10)
    let w = cam.transform(at: 0.5)
    #expect(abs(w.scale - 1) < 1e-6 && abs(w.center.x - 0.5) < 1e-6)
    let z = cam.transform(at: 4)
    #expect(abs(z.scale - 2) < 1e-4)
    #expect(abs(z.center.x - 0.3) < 1e-4 && abs(z.center.y - 0.7) < 1e-4)
    #expect(abs(cam.transform(at: 9).scale - 1) < 1e-6)
}

@Test func cameraInterpolatesInLogSpaceAboutAFixedPoint() {
    let cur = CursorPath(events: [], smoothing: 0.5)
    let s1 = 3.0
    let r = ZoomRegion(id: "a", range: TimeRange(start: 3, end: 8), scale: s1, focus: NormPoint(x: 0.3, y: 0.4))
    let cam = CameraPath(regions: [r], cursor: cur, duration: 10)
    let d = Spring.zoomDuration(from: 1, to: s1)
    let t0 = 3 - d / 2
    let ax = (0.5 - 0.3 * s1) / (1 - s1), ay = (0.5 - 0.4 * s1) / (1 - s1)
    for k in 1..<10 {
        let p = Double(k) / 10
        let t = t0 + d * p
        // Sample exactly on table points to avoid interpolation error in the check.
        let tq = (t * CameraPath.sampleRate).rounded() / CameraPath.sampleRate
        let (s, c) = cam.transform(at: tq)
        let expected = Spring.ease((tq - t0) / d)
        #expect(abs(log(s) / log(s1) - expected) < 1e-3)
        // The anchor point stays put on screen: (A - c)·s + 0.5 == A.
        #expect(abs((ax - c.x) * s + 0.5 - ax) < 1e-3)
        #expect(abs((ay - c.y) * s + 0.5 - ay) < 1e-3)
    }
}

@Test func cameraViewportNeverLeavesFrame() {
    var rng = SplitMix(seed: 11)
    let ev = (0..<4000).map { i in InputEvent.move(Double(i) / 60, NormPoint(x: rng.unit() * 1.4 - 0.2, y: rng.unit() * 1.4 - 0.2)) }
    let cur = CursorPath(events: ev, smoothing: 0.3)
    var regions: [ZoomRegion] = []
    for i in 0..<20 {
        let start = Double(i) * 3.1 + rng.unit()
        let focus: NormPoint? = i % 3 == 0 ? nil : NormPoint(x: rng.unit() * 1.2 - 0.1, y: rng.unit())
        regions.append(ZoomRegion(id: "r\(i)", range: TimeRange(start: start, end: start + 0.5 + rng.unit() * 4),
                                  scale: 1 + rng.unit() * 4, focus: focus))
    }
    let cam = CameraPath(regions: regions, cursor: cur, duration: 66)
    var prev: (Double, NormPoint)?
    for i in 0..<(66 * 240) {
        let t = Double(i) / 240
        let v = cam.viewport(at: t)
        #expect(v.x >= -1e-6 && v.y >= -1e-6 && v.x + v.width <= 1 + 1e-6 && v.y + v.height <= 1 + 1e-6)
        let tr = cam.transform(at: t)
        if let p = prev {
            // Continuity: no jumps between 240 Hz samples.
            #expect(abs(log(tr.scale) - log(p.0)) < 0.08)
            #expect(abs(tr.center.x - p.1.x) < 0.03 && abs(tr.center.y - p.1.y) < 0.03)
        }
        prev = (tr.scale, tr.center)
    }
}

@Test func cameraPansBetweenCloseRegions() {
    let cur = CursorPath(events: [], smoothing: 0.5)
    let a = ZoomRegion(id: "a", range: TimeRange(start: 2, end: 5), scale: 2, focus: NormPoint(x: 0.3, y: 0.3))
    let b = ZoomRegion(id: "b", range: TimeRange(start: 5.5, end: 9), scale: 2, focus: NormPoint(x: 0.7, y: 0.7))
    let cam = CameraPath(regions: [a, b], cursor: cur, duration: 12)
    var minScale = 10.0
    for i in 0..<100 { minScale = min(minScale, cam.transform(at: 4 + Double(i) * 0.025).scale) }
    #expect(minScale > 1.99)
    #expect(abs(cam.transform(at: 7.5).center.x - 0.7) < 1e-3)
}

@Test func cameraFollowsCursorWithDeadZone() {
    var ev: [InputEvent] = []
    for i in 0..<600 {
        let t = Double(i) / 60
        // Small wiggle for 4 s, then a big move to the right.
        let x = t < 4 ? 0.5 + 0.02 * sin(t * 6) : min(0.9, 0.5 + (t - 4) * 0.2)
        ev.append(.move(t, NormPoint(x: x, y: 0.5)))
    }
    let cur = CursorPath(events: ev, smoothing: 0.5)
    let r = ZoomRegion(id: "f", range: TimeRange(start: 0.5, end: 10), scale: 2, focus: nil)
    let cam = CameraPath(regions: [r], cursor: cur, duration: 10)
    var lo = 1.0, hi = 0.0
    for i in 0..<100 { let x = cam.transform(at: 1.5 + Double(i) * 0.02).center.x; lo = min(lo, x); hi = max(hi, x) }
    #expect(hi - lo < 1e-3) // the wiggle stays inside the dead zone
    #expect(cam.transform(at: 9.5).center.x > 0.6) // the big move is followed
}

@Test func cameraOneHourBuildsFast() {
    var rng = SplitMix(seed: 5)
    let ev = noisyLine(seconds: 3600, rate: 60)
    let cur = CursorPath(events: ev, smoothing: 0.6)
    let regions = (0..<600).map { i in
        ZoomRegion(id: "r\(i)", range: TimeRange(start: Double(i) * 6, end: Double(i) * 6 + 3), scale: 2,
                   focus: i % 2 == 0 ? nil : NormPoint(x: rng.unit(), y: rng.unit()))
    }
    let clock = ContinuousClock()
    let elapsed = clock.measure { _ = CameraPath(regions: regions, cursor: cur, duration: 3600) }
    print("CameraPath 1 h, 600 regions: \(elapsed)")
    #expect(elapsed < .milliseconds(500))
}

/// Small deterministic RNG for tests.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
