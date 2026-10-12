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
    #expect(abs(Spring.zoomDuration(from: 1, to: 1.8) - (0.9 + 0.5 * log(1.8))) < 1e-12)
}

@Test func glideStartsGentlyPeaksEarlyAndLandsAtRest() {
    #expect(Spring.glide(0) == 0 && abs(Spring.glide(1) - 1) < 1e-12)
    let h = 1e-4
    func speed(_ u: Double) -> Double { (Spring.glide(min(1, u + h)) - Spring.glide(max(0, u - h))) / (min(1, u + h) - max(0, u - h)) }
    // Imperceptible start, zero speed at the end.
    #expect(speed(0.01) < 0.15 && speed(0.999) < 0.01)
    var peak = 0.0, at = 0.0, prev = 0.0
    for i in 1..<1000 {
        let u = Double(i) / 1000
        let v = Spring.glide(u)
        #expect(v >= prev)
        prev = v
        if speed(u) > peak { peak = speed(u); at = u }
    }
    // Peak a third of the way in, well below the fast-start spring's 3.6× average speed.
    #expect(abs(at - 0.33) < 0.03, "peak at \(at)")
    #expect(peak < 1.9, "peak speed \(peak)")
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

@Test func eventLogReadSpeed() throws {
    guard ProcessInfo.processInfo.environment["RB_BENCH"] != nil else { return }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("rb-ev-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let w = try EventLogWriter(url: url)
    for e in noisyLine(seconds: 3600, rate: 120) { w.append(e) }
    w.close()
    let clock = ContinuousClock()
    var n = 0
    let d = try clock.measure { n = try EventLog.read(url).count }
    print("EventLog.read 1 h @120 Hz (\(n) lines): \(d)")
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
    #expect(abs(z.range.start - 4.0) < 1e-9)
    #expect(abs(z.range.end - 6.8) < 1e-9)
    #expect(abs(z.scale - 1.8) < 1e-9)
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
    // A few seconds apart, far apart in space: two adjacent shots (the camera pans), leaving 0.8 s after the
    // first click and arriving before the second.
    let pan = AutoZoomPlanner.plan(events: [.down(2, NormPoint(x: 0.1, y: 0.1)), .down(5, NormPoint(x: 0.9, y: 0.9))],
                                   duration: 20, intensity: 0.5)
    #expect(pan.count == 2)
    if pan.count == 2 {
        #expect(abs(pan[0].range.end - pan[1].range.start) < 1e-9)
        #expect(pan[0].range.end > 2.6 && pan[0].range.end < 4.5)
    }
    // Too close in time for a calm pan: one shot survives and the other click is still on screen.
    let close = AutoZoomPlanner.plan(events: [.down(2, NormPoint(x: 0.1, y: 0.1)), .down(3.5, NormPoint(x: 0.9, y: 0.9))],
                                     duration: 20, intensity: 0.5)
    #expect(close.count == 1)
    let cam = CameraPath(regions: close, cursor: CursorPath(events: [], smoothing: 0), duration: 20)
    for (t, p) in [(2.0, NormPoint(x: 0.1, y: 0.1)), (3.5, NormPoint(x: 0.9, y: 0.9))] {
        let v = cam.viewport(at: t)
        #expect(p.x >= v.x && p.x <= v.x + v.width && p.y >= v.y && p.y <= v.y + v.height, "click at \(t) off screen: \(v)")
    }
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
        let expected = Spring.glide((tq - t0) / d)
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
    // A long diagonal hop eases out a little mid-way (van Wijk), but never all the way back to wide.
    #expect(minScale > 1.3 && minScale < 1.99, "min scale \(minScale)")
    #expect(abs(cam.transform(at: 7.5).center.x - 0.7) < 1e-3)
    // A short hop at the same depth is a plain pan.
    let c = ZoomRegion(id: "c", range: TimeRange(start: 5.5, end: 9), scale: 2, focus: NormPoint(x: 0.36, y: 0.3))
    let near = CameraPath(regions: [a, c], cursor: cur, duration: 12)
    var nearMin = 10.0
    for i in 0..<100 { nearMin = min(nearMin, near.transform(at: 4 + Double(i) * 0.025).scale) }
    #expect(nearMin > 1.95)
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

// MARK: - Motion quality

@Test func cursorSmoothingHasNoLag() throws {
    // A pointer gliding at constant speed: the smoothed cursor sits on the real one (zero-phase filter).
    var ev: [InputEvent] = []
    for i in 0..<480 { ev.append(.move(Double(i) / 120, NormPoint(x: 0.1 + 0.2 * Double(i) / 120, y: 0.5))) }
    let c = CursorPath(events: ev, smoothing: 1)
    for t in [1.0, 2.0, 3.0] {
        let p = try #require(c.position(at: t))
        #expect(abs(p.x - (0.1 + 0.2 * t)) < 0.002, "lag at \(t): \(p.x)")
    }
    // A step (a jump between two rests) is smoothed symmetrically and settles exactly on both rests.
    let step: [InputEvent] = [.move(0, NormPoint(x: 0.2, y: 0.5)), .move(2, NormPoint(x: 0.2, y: 0.5)), .move(2.01, NormPoint(x: 0.8, y: 0.5)),
                              .move(4, NormPoint(x: 0.8, y: 0.5))]
    let s = CursorPath(events: step, smoothing: 0.6)
    #expect(abs(s.position(at: 1)!.x - 0.2) < 1e-4 && abs(s.position(at: 3.5)!.x - 0.8) < 1e-4)
    let before = s.position(at: 2.005 - 0.05)!.x - 0.2, after = 0.8 - s.position(at: 2.005 + 0.05)!.x
    #expect(abs(before - after) < 0.02, "asymmetric: \(before) vs \(after)")
}

@Test func cursorStaysOnDraggedContent() throws {
    // Press, drag in a wobbly line, release: during the drag the cursor is the raw pointer.
    var ev: [InputEvent] = [.down(1, NormPoint(x: 0.2, y: 0.5))]
    for i in 0...120 {
        let t = 1 + Double(i) / 120
        ev.append(.move(t, NormPoint(x: 0.2 + 0.4 * Double(i) / 120, y: 0.5 + 0.01 * sin(Double(i)))))
    }
    ev.append(.up(2, NormPoint(x: 0.6, y: 0.5 + 0.01 * sin(120))))
    let c = CursorPath(events: ev, smoothing: 1)
    let raw = CursorPath(events: ev, smoothing: 0)
    for t in stride(from: 1.05, to: 1.95, by: 0.1) {
        let a = try #require(c.position(at: t)), b = try #require(raw.position(at: t))
        #expect(hypot(a.x - b.x, a.y - b.y) < 1e-4, "drag drift at \(t)")
    }
}

@Test func cursorHidesWhileTyping() {
    var ev: [InputEvent] = [.move(0, NormPoint(x: 0.3, y: 0.3)), .move(0.5, NormPoint(x: 0.4, y: 0.3))]
    for i in 0..<10 { ev.append(InputEvent(t: 2 + Double(i) * 0.1, type: .key, chars: "a")) }
    ev.append(InputEvent(t: 4, type: .key, chars: "c", mods: ["⌘"]))
    ev.append(.move(6, NormPoint(x: 0.5, y: 0.5)))
    let c = CursorPath(events: ev, smoothing: 0.5)
    #expect(c.opacity(at: 1.9, hideAfter: 0) == 1)
    #expect(c.opacity(at: 3, hideAfter: 0) == 0)
    #expect(c.opacity(at: 5.95, hideAfter: 0) > 0.5) // fading back in just before it moves
    #expect(c.opacity(at: 6.2, hideAfter: 0) == 1)
    // A shortcut alone doesn't hide it.
    let shortcut = CursorPath(events: [.move(0, NormPoint(x: 0.3, y: 0.3)), InputEvent(t: 1, type: .key, chars: "s", mods: ["⌘"])], smoothing: 0.5)
    #expect(shortcut.opacity(at: 2, hideAfter: 0) == 1)
}

@Test func croppedCameraFollowsAndStaysInFrame() {
    // A half-width window (9:16-style crop): the un-zoomed view follows the cursor across the screen.
    var ev: [InputEvent] = []
    for i in 0..<600 { let t = Double(i) / 60; ev.append(.move(t, NormPoint(x: t < 3 ? 0.15 : 0.9, y: 0.5))) }
    let cur = CursorPath(events: ev, smoothing: 0.5)
    let cam = CameraPath(regions: [], cursor: cur, duration: 10, aspect: 1.6, base: SIMD2(0.5, 1))
    let early = cam.viewport(at: 2.5), late = cam.viewport(at: 9)
    #expect(abs(early.width - 0.5) < 1e-6 && abs(early.height - 1) < 1e-6)
    #expect(early.x < 0.01, "view should sit at the left: \(early)")
    #expect(late.x + late.width > 0.99, "view should follow right: \(late)")
    for i in 0..<1200 {
        let v = cam.viewport(at: Double(i) / 120)
        #expect(v.x >= -1e-6 && v.x + v.width <= 1 + 1e-6)
    }
}
