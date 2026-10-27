import Foundation
import Testing
@testable import ReelbirdCore

private func seg(_ a: Double, _ b: Double, _ rate: Double, _ source: SpeedSegment.Source = .user) -> SpeedSegment {
    SpeedSegment(range: TimeRange(start: a, end: b), rate: rate, source: source)
}

@Test func speedTimelineMapsPiecesAtTheirRates() {
    // 0–10 s, cut 6–7, 2× over 2–4, 0.5× over 8–9.
    let speed = SpeedSettings(segments: [seg(2, 4, 2), seg(8, 9, 0.5)])
    let tl = EditTimeline(duration: 10, trim: nil, cuts: [TimeRange(start: 6, end: 7)], speed: speed)
    #expect(tl.kept == [TimeRange(start: 0, end: 6), TimeRange(start: 7, end: 10)])
    #expect(tl.pieces.map(\.rate) == [1, 2, 1, 1, 0.5, 1])
    // 2 + 1 + 2 + 1 + 2 + 1
    #expect(abs(tl.duration - 9) < 1e-9)
    #expect(tl.outputTime(forSource: 3) == 2.5)
    #expect(tl.outputTime(forSource: 4) == 3)
    #expect(tl.outputTime(forSource: 6.5) == nil)
    #expect(tl.outputTime(forSource: 8.5) == 7)
    #expect(tl.sourceTime(forOutput: 2.5) == 3)
    #expect(tl.sourceTime(forOutput: 7) == 8.5)
    #expect(tl.sourceTime(forOutput: 100) == 10)
    #expect(tl.sourceTime(forOutput: -1) == 0)
    #expect(tl.nearestOutputTime(forSource: 6.5) == 5)
    // Pieces that meet on the output timeline (across the cut) join up.
    #expect(tl.outputRanges(forSource: TimeRange(start: 1, end: 8.5)) == [TimeRange(start: 1, end: 7)])
    #expect(tl.outputRanges(forSource: TimeRange(start: 3, end: 4.5)) == [TimeRange(start: 2.5, end: 3.5)])
}

@Test func speedTimelineRoundTripsAndIsMonotonic() {
    let speed = SpeedSettings(segments: [seg(0.3, 1.7, 8), seg(2.05, 2.4, 0.25), seg(3, 5.5, 1.5), seg(7, 9.9, 4)])
    let tl = EditTimeline(duration: 12, trim: TimeRange(start: 0.1, end: 11.3),
                          cuts: [TimeRange(start: 1, end: 1.2), TimeRange(start: 4.4, end: 4.9)], speed: speed)
    // Output → source → output.
    var prevSource = -1.0
    var o = 0.0
    while o <= tl.duration {
        let s = tl.sourceTime(forOutput: o)
        #expect(s >= prevSource - 1e-12, "source time went backwards at output \(o)")
        prevSource = s
        if o < tl.duration - 1e-9 {
            let back = tl.outputTime(forSource: s)
            #expect(back != nil && abs(back! - o) < 1e-9, "output \(o) → source \(s) → \(String(describing: back))")
        }
        o += 0.0137
    }
    // Source → output → source, for kept moments; output is strictly increasing.
    var prevOut = -1.0
    var s = 0.0
    while s < 12 {
        if let out = tl.outputTime(forSource: s) {
            #expect(out > prevOut)
            prevOut = out
            #expect(abs(tl.sourceTime(forOutput: out) - s) < 1e-9)
        }
        s += 0.0091
    }
    // Boundaries: each piece starts where the last ended, on both timelines.
    for (a, b) in zip(tl.pieces, tl.pieces.dropFirst()) {
        #expect(abs(a.outputEnd - b.outputStart) < 1e-12)
        #expect(b.source.start >= a.source.end - 1e-12)
        #expect(tl.outputTime(forSource: b.source.start).map { abs($0 - b.outputStart) < 1e-9 } == true)
    }
    #expect(abs((tl.pieces.last?.outputEnd ?? 0) - tl.duration) < 1e-12)
}

@Test func timelineWithoutSpeedIsUnchanged() {
    let a = EditTimeline(duration: 10, trim: TimeRange(start: 1, end: 9), cuts: [TimeRange(start: 3, end: 4)])
    #expect(a.pieces.count == a.kept.count)
    #expect(a.pieces.allSatisfy { $0.rate == 1 && $0.audible })
    #expect(!a.hasSpeedChanges)
    #expect(a.duration == 7)
}

@Test func fastPiecesAreSilentUnlessKept() {
    var speed = SpeedSettings(segments: [seg(1, 2, 2), seg(3, 4, 4)])
    var tl = EditTimeline(duration: 5, trim: nil, cuts: [], speed: speed)
    #expect(tl.pieces.map(\.audible) == [true, true, true, false, true])
    speed.keepFastAudio = true
    tl = EditTimeline(duration: 5, trim: nil, cuts: [], speed: speed)
    #expect(tl.pieces.allSatisfy { $0.audible })
}

@Test func speedSettingsNormaliseAndReplaceOverlaps() {
    // Later segments win overlaps; out-of-range rates clamp; rate 1 and too-short ranges drop.
    let s = SpeedSettings(segments: [seg(0, 10, 2), seg(4, 6, 4), seg(7, 7.05, 3), seg(8, 9, 1), seg(-1, 0.5, 100)])
    #expect(s.segments.map(\.range) == [TimeRange(start: 0, end: 0.5), TimeRange(start: 0.5, end: 4), TimeRange(start: 4, end: 6),
                                        TimeRange(start: 6, end: 8), TimeRange(start: 9, end: 10)])
    #expect(s.segments.map(\.rate) == [8, 2, 4, 2, 2])
    #expect(Set(s.segments.map(\.id)).count == s.segments.count, "split pieces get their own IDs")
    var t = s
    t.set(TimeRange(start: 1, end: 9.5), rate: 1)
    #expect(t.segments.map(\.range) == [TimeRange(start: 0, end: 0.5), TimeRange(start: 0.5, end: 1), TimeRange(start: 9.5, end: 10)])
    t.set(TimeRange(start: 2, end: 3), rate: 1.5)
    #expect(t.rate(at: 2.5) == 1.5)
    #expect(t.rate(at: 5) == 1)
    #expect(SpeedSegment.label(1.5) == "1.5×" && SpeedSegment.label(2) == "2×" && SpeedSegment.label(0.25) == "0.25×")
    #expect(SpeedSegment.parseRate("2x") == 2 && SpeedSegment.parseRate("0.5×") == 0.5 && SpeedSegment.parseRate("fast") == nil)
}

@Test func oldEditFilesOpenAtNormalSpeed() throws {
    // A file written before speed existed.
    let old = #"{"formatVersion":1,"cuts":[{"start":1,"end":2}],"zoom":{"mode":"auto"}}"#
    let e = try JSONCoding.decoder.decode(EditDocument.self, from: Data(old.utf8))
    #expect(e.speed == SpeedSettings())
    #expect(e.cuts.count == 1)
    // A newer file with an odd segment, an unknown source and an unknown key still opens.
    let newer = #"{"speed":{"segments":[{"range":{"start":1,"end":3},"rate":2,"source":"magic","id":"a"},{"rate":3},{"range":{"start":5,"end":6},"rate":0.01}],"keepFastAudio":true,"future":1}}"#
    let n = try JSONCoding.decoder.decode(EditDocument.self, from: Data(newer.utf8))
    #expect(n.speed.keepFastAudio)
    #expect(n.speed.segments.count == 2)
    #expect(n.speed.segments[0].source == .user)
    #expect(n.speed.segments[1].rate == 0.25)
    // A broken speed block doesn't stop the edit opening.
    let broken = #"{"speed":"fast","cuts":[{"start":1,"end":2}]}"#
    let b = try JSONCoding.decoder.decode(EditDocument.self, from: Data(broken.utf8))
    #expect(b.speed.isEmpty && b.cuts.count == 1)
    // Round trip.
    var e2 = EditDocument()
    e2.speed.set(TimeRange(start: 2, end: 4), rate: 4, source: .typing)
    let back = try JSONCoding.decoder.decode(EditDocument.self, from: JSONCoding.encoder.encode(e2))
    #expect(back == e2)
    #expect(EditTimeline(duration: 10, trim: nil, cuts: [], speed: back.speed).duration == 8.5)
}

@Test func speedMergesLikeOtherEdits() {
    let base = EditDocument()
    var ours = base
    ours.zoom.intensity = 0.9
    var theirs = base
    theirs.speed.set(TimeRange(start: 1, end: 2), rate: 2)
    let m = EditMerge.merge(base: base, ours: ours, theirs: theirs)
    #expect(m.conflicts.isEmpty)
    #expect(m.edit.speed == theirs.speed && m.edit.zoom.intensity == 0.9)
}

// MARK: Suggestions

private func typing(from a: Double, to b: Double, every gap: Double = 0.15) -> [InputEvent] {
    stride(from: a, through: b, by: gap).map { InputEvent(t: $0, type: .key, chars: "a") }
}

@Test func suggestsTypingAndIdleStretches() {
    var events: [InputEvent] = [.move(0, NormPoint(x: 0.5, y: 0.5)), .move(0.5, NormPoint(x: 0.6, y: 0.5))]
    events += typing(from: 2, to: 8)            // 6 s of typing
    events += typing(from: 10.5, to: 11.5)      // too short (and more than the 2 s key gap after the first run)
    events += [.down(12, NormPoint(x: 0.5, y: 0.5)), .up(12.1, NormPoint(x: 0.5, y: 0.5))]
    // Jitter during the idle stretch doesn't count as input.
    events += [.move(15, NormPoint(x: 0.6, y: 0.5)), .move(16, NormPoint(x: 0.6005, y: 0.5))]
    events += typing(from: 25, to: 29)          // typing while talking
    events.append(.down(30, NormPoint(x: 0.1, y: 0.1)))
    // Silent: 12.5–24 (idle) and 2–8 (typing in silence); speech elsewhere.
    let silences = [TimeRange(start: 2, end: 8.2), TimeRange(start: 12.5, end: 24)]
    let edit = EditDocument()
    let s = SpeedSuggester.suggest(events: events, silences: silences, duration: 32, edit: edit)
    #expect(s.map(\.kind) == [.typing, .idle, .typing])
    #expect(abs(s[0].range.start - 2) < 1e-9 && abs(s[0].range.end - 8.15) < 1e-6)
    #expect(s[0].rate == 4)
    #expect(abs(s[1].range.start - 12.9) < 1e-9 && abs(s[1].range.end - 23.6) < 1e-9)
    #expect(s[1].rate == 8)
    #expect(s[2].rate == 2, "typing over speech keeps the voice at 2×")
    let sum = SpeedSuggester.summary(s)
    #expect(sum.typing == 2 && sum.idle == 1)
    #expect(abs(sum.saved - (s[0].range.duration * 0.75 + 10.7 * 0.875 + s[2].range.duration * 0.5)) < 1e-6)
}

@Test func suggestionsSkipCutsTrimAndExistingSpeed() {
    let events = typing(from: 2, to: 12)
    var edit = EditDocument()
    edit.cuts = [TimeRange(start: 5, end: 6)]
    edit.trim = TimeRange(start: 0, end: 11)
    edit.speed.set(TimeRange(start: 8, end: 9), rate: 1.5)
    let s = SpeedSuggester.suggest(events: events, silences: nil, duration: 20, edit: edit)
    #expect(s.map(\.range) == [TimeRange(start: 2, end: 5), TimeRange(start: 6, end: 8), TimeRange(start: 9, end: 11)])
    // No silence information (no audio): typing counts as not talking.
    #expect(s.allSatisfy { $0.rate == 4 && $0.kind == .typing })
    // Applying them gives removable segments marked as suggestions.
    for x in s { edit.speed.set(x.range, rate: x.rate, source: x.segment.source) }
    #expect(edit.speed.segments.filter { $0.source == .typing }.count == 3)
    #expect(SpeedSuggester.suggest(events: events, silences: nil, duration: 20, edit: edit).isEmpty)
}

@Test func noKeystrokesNoTypingSuggestions() {
    let events: [InputEvent] = (0..<200).map { .move(Double($0) * 0.05, NormPoint(x: Double($0) / 200, y: 0.5)) }
    #expect(SpeedSuggester.suggest(events: events, silences: [], duration: 10, edit: EditDocument()).isEmpty)
}
