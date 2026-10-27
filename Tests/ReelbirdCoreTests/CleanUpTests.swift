import Foundation
import Testing
@testable import ReelbirdCore

// Clean Up planner fixtures: words on the recording timeline, and a voice level that is speech (-20 dBFS) inside
// the given ranges and room noise (-70) elsewhere.

private func w(_ a: Double, _ b: Double, _ text: String) -> CleanUpInputs.Word { .init(range: TimeRange(start: a, end: b), text: text) }

private func envelope(duration: Double, loud: [(Double, Double, Float)]) -> AudioEnvelope {
    let n = Int(duration / 0.02)
    var levels = [Float](repeating: -70, count: n)
    for (a, b, level) in loud {
        for i in max(0, Int(a / 0.02))..<min(n, Int(b / 0.02)) { levels[i] = level }
    }
    return AudioEnvelope(levels: levels)
}

/// Words with the voice loud exactly over each word.
private func speech(_ words: [CleanUpInputs.Word], duration: Double, events: [InputEvent] = [], screen: [ScreenChange]? = nil) -> CleanUpInputs {
    CleanUpInputs(duration: duration, words: words, events: events,
                  envelope: envelope(duration: duration, loud: words.map { ($0.range.start, $0.range.end, -20) }), screen: screen, frameRate: 50)
}

private func click(_ t: Double) -> [InputEvent] {
    [InputEvent.down(t, NormPoint(x: 0.5, y: 0.5)), InputEvent.up(t + 0.08, NormPoint(x: 0.5, y: 0.5))]
}

private func key(_ t: Double) -> InputEvent { InputEvent(t: t, type: .key, chars: "a") }

/// Two sentences with a 2 s pause, starting at 0.4 s so there is no dead start to cut.
private let twoSentences = [w(0.4, 0.8, "Open"), w(0.8, 1.4, "settings."), w(3.4, 3.7, "Then"), w(3.7, 4.0, "click"), w(4.0, 4.5, "save.")]

@Test func cleanUpShortensAPauseButNeverRemovesIt() {
    let report = CleanUp.plan(speech(twoSentences, duration: 5), edit: EditDocument())
    let pause = try! #require(report.applied.first { $0.kind == .pause })
    let cut = try! #require(pause.cut)
    #expect(pause.range == TimeRange(start: 1.4, end: 3.4))
    let kept = pause.range.duration - cut.duration
    // clamp(0.35 + 0.1 × 1.25) + 0.1 after a sentence = 0.575, give or take the quiet-point and frame moves.
    #expect(kept > 0.45 && kept < 0.72, "kept \(kept)")
    #expect(cut.start - 1.4 >= 0.15 - 1e-9 && 3.4 - cut.end >= 0.1 - 1e-9, "air next to speech: \(cut)")
    // Frame-snapped (50 fps).
    #expect(abs(cut.start * 50 - (cut.start * 50).rounded()) < 1e-6)
    #expect(report.suggestions.isEmpty)
    // A short pause is left alone.
    let short = [w(0.4, 0.8, "Open"), w(1.3, 1.6, "it.")]
    #expect(CleanUp.plan(speech(short, duration: 2), edit: EditDocument()).applied.allSatisfy { $0.kind != .pause })
}

@Test func cleanUpSpeedsUpABusySilenceInsteadOfCuttingIt() {
    let words = [w(0.4, 0.9, "Watch"), w(0.9, 1.4, "this."), w(5.4, 5.8, "Done.")]
    let report = CleanUp.plan(speech(words, duration: 6, events: click(3)), edit: EditDocument())
    #expect(!report.applied.contains { $0.kind == .pause })
    let fast = try! #require(report.applied.first { $0.kind == .speedUp })
    #expect(fast.rate == 3 && fast.cut == nil)
    #expect(abs(fast.range.start - 1.7) < 1e-9 && abs(fast.range.end - 5.1) < 1e-9)
    // The screen changing (a page loading) counts as activity too; pointer moves alone get 2×.
    let loading = [ScreenChange(t: 2.5, change: 0.1)]
    let r2 = CleanUp.plan(speech(words, duration: 6, screen: loading), edit: EditDocument())
    #expect(r2.applied.first { $0.kind == .speedUp }?.rate == 3)
    let moves = (0..<20).map { InputEvent.move(2 + Double($0) * 0.1, NormPoint(x: 0.1 + Double($0) * 0.02, y: 0.5)) }
    let r3 = CleanUp.plan(speech(words, duration: 6, events: moves), edit: EditDocument())
    #expect(r3.applied.first { $0.kind == .speedUp }?.rate == 2)
}

@Test func cleanUpKeepsCutsClearOfInput() {
    // A click 0.1 s after the pause ends: the cut stops 0.4 s before it.
    let report = CleanUp.plan(speech(twoSentences, duration: 5, events: click(3.5)), edit: EditDocument())
    let cut = try! #require(report.applied.first { $0.kind == .pause }?.cut)
    #expect(cut.end <= 3.5 - 0.4 + 1e-6, "\(cut)")
}

@Test func cleanUpTrimsDeadStartAndEnd() {
    let words = [w(3.0, 3.5, "Hello"), w(3.5, 4.0, "there."), w(14.5, 15.0, "Bye.")]
    // The stop shortcut at 19.6 s isn't content.
    let report = CleanUp.plan(speech(words, duration: 20, events: [key(19.6)]), edit: EditDocument())
    let start = try! #require(report.applied.first { $0.kind == .deadStart }?.cut)
    let end = try! #require(report.applied.first { $0.kind == .deadEnd }?.cut)
    #expect(start.start == 0 && abs(start.end - 2.7) < 0.011)
    #expect(abs(end.start - 15.6) < 0.011 && end.end == 20)
    // A click before the first word moves the start earlier.
    let r2 = CleanUp.plan(speech(words, duration: 20, events: click(1.5)), edit: EditDocument())
    #expect(abs((r2.applied.first { $0.kind == .deadStart }?.cut?.end ?? 0) - 1.0) < 0.011)
    // A trimmed start is left alone.
    var trimmed = EditDocument()
    trimmed.trim = TimeRange(start: 2.9, end: 20)
    #expect(!CleanUp.plan(speech(words, duration: 20), edit: trimmed).applied.contains { $0.kind == .deadStart })
}

@Test func cleanUpMergesTypingBurstsIntoOneSpeedUp() {
    // Keys every 0.4 s from 2 to 6 s, a 1.6 s thinking pause, keys again 7.6–10 s: one stretch at 2 s gaps.
    let keys = stride(from: 2.0, through: 6.0, by: 0.4).map(key) + stride(from: 7.6, through: 10.0, by: 0.4).map(key)
    let words = [w(0.4, 1.0, "Typing."), w(11.0, 11.5, "Done.")]
    let report = CleanUp.plan(speech(words, duration: 12, events: keys), edit: EditDocument())
    let typing = report.applied.filter { $0.kind == .speedUp }
    #expect(typing.count == 1, "\(typing)")
    #expect(typing.first?.rate == 4)
    #expect((typing.first?.range.start ?? 0) <= 2.0 && (typing.first?.range.end ?? 0) >= 9.7)
}

/// "the" holding a folded-in "um": voice 2.0–2.3, a dip, then the real word 2.42–2.62.
private func fillerInputs(previousEnd: Double = 1.4, word: String = "the") -> CleanUpInputs {
    let words = [w(0.6, previousEnd, "Click"), w(2.0, 2.9, word), w(2.9, 3.3, "button.")]
    let env = envelope(duration: 4, loud: [(0.6, previousEnd, -20), (2.0, 2.3, -22), (2.42, 2.62, -18), (2.9, 3.3, -20)])
    return CleanUpInputs(duration: 4, words: words, envelope: env, frameRate: 50)
}

@Test func cleanUpCutsAFoldedInUm() {
    let report = CleanUp.plan(fillerInputs(), edit: EditDocument())
    let um = try! #require(report.applied.first { $0.kind == .filler })
    let cut = try! #require(um.cut)
    #expect(cut.start <= 2.0 && cut.start >= 1.95, "\(cut)")
    #expect(cut.end > 2.3 && cut.end < 2.42, "\(cut)")
    #expect(um.confidence >= 0.8)
    // Words that are never fillers stay, however long.
    #expect(!CleanUp.plan(fillerInputs(word: "so"), edit: EditDocument()).applied.contains { $0.kind == .filler })
    // No quiet before the island (the last word runs right into it): only a suggestion.
    let tight = CleanUp.plan(fillerInputs(previousEnd: 2.0), edit: EditDocument())
    #expect(!tight.applied.contains { $0.kind == .filler })
    #expect(tight.suggestions.contains { $0.kind == .filler })
}

/// A take, "sorry", a pause, and the take again.
private func retakeWords() -> [CleanUpInputs.Word] {
    [w(0.4, 0.7, "Click"), w(0.7, 0.9, "the"), w(0.9, 1.2, "blue"), w(1.2, 1.6, "button,"), w(1.6, 2.0, "sorry."),
     w(3.0, 3.3, "Click"), w(3.3, 3.5, "the"), w(3.5, 3.9, "green"), w(3.9, 4.4, "button."), w(4.4, 4.9, "Done.")]
}

@Test func cleanUpCutsAnAnnouncedRetakeAndSuggestsADoubtfulOne() {
    let report = CleanUp.plan(speech(retakeWords(), duration: 5.2), edit: EditDocument())
    let retake = try! #require(report.applied.first { $0.kind == .retake })
    let cut = try! #require(retake.cut)
    #expect(cut.start <= 0.4 && cut.end <= 3.0 && cut.end > 2.6, "\(cut)")
    // The pause inside the retake isn't cut twice.
    #expect(!report.applied.contains { $0.kind == .pause && $0.editRange.overlaps(cut) })
    // A click in the earlier take may change what the later one shows: suggest only, and still shorten the pause.
    let clicked = CleanUp.plan(speech(retakeWords(), duration: 5.2, events: click(1.0)), edit: EditDocument())
    #expect(!clicked.applied.contains { $0.kind == .retake })
    #expect(clicked.suggestions.contains { $0.kind == .retake })
    // No cue phrase: suggest only.
    var plain = retakeWords()
    plain[4].text = "okay."
    let quiet = CleanUp.plan(speech(plain, duration: 5.2), edit: EditDocument())
    #expect(!quiet.applied.contains { $0.kind == .retake } && quiet.suggestions.contains { $0.kind == .retake })
}

@Test func cleanUpRunsAgainUndoesAndRestores() throws {
    let input = speech(twoSentences + [w(4.5, 4.6, "Ok"), w(6.8, 7.2, "Bye.")], duration: 7.6)
    var edit = EditDocument()
    edit.cuts = [TimeRange(start: 7.3, end: 7.4)] // made by hand
    let first = CleanUp.plan(input, edit: edit)
    #expect(first.count(.pause) == 2)
    CleanUp.apply(first, to: &edit)
    #expect(edit.cuts.count == 3)
    #expect(edit.cleanUp.applied.count == 2)
    // Running again finds nothing new.
    #expect(CleanUp.plan(input, edit: edit).applied.isEmpty)
    // Restore one: its moment plays again, and a later run leaves it alone.
    let id = edit.cleanUp.applied[0].id
    #expect(CleanUp.restore(id, in: &edit))
    #expect(edit.cuts.count == 2 && edit.cleanUp.applied.count == 1 && edit.cleanUp.restored.count == 1)
    #expect(CleanUp.plan(input, edit: edit).applied.isEmpty)
    // Undo all: only the hand-made cut stays.
    CleanUp.undoAll(&edit)
    #expect(edit.cuts == [TimeRange(start: 7.3, end: 7.4)])
    #expect(edit.cleanUp.isEmpty)
    // A Clean Up cut changed by hand isn't removed by undo.
    var e2 = EditDocument()
    CleanUp.apply(CleanUp.plan(input, edit: e2), to: &e2)
    e2.cuts[0].end += 0.05
    CleanUp.undoAll(&e2)
    #expect(e2.cuts.count == 1)
}

@Test func cleanUpSpeedUpsAreTaggedSpeedSegments() {
    let words = [w(0.4, 0.9, "Watch"), w(0.9, 1.4, "this."), w(5.4, 5.8, "Done.")]
    var edit = EditDocument()
    CleanUp.apply(CleanUp.plan(speech(words, duration: 6, events: click(3)), edit: edit), to: &edit)
    let seg = try! #require(edit.speed.segments.first)
    #expect(seg.source == .cleanUp && seg.rate == 3)
    #expect(edit.cleanUp.applied.first?.speedID == seg.id)
    CleanUp.undoAll(&edit)
    #expect(edit.speed.segments.isEmpty)
}

@Test func cleanUpSuggestionsCanBeAcceptedOrDismissed() {
    var edit = EditDocument()
    let input = fillerInputs(previousEnd: 2.0)
    CleanUp.apply(CleanUp.plan(input, edit: edit), to: &edit)
    let s = try! #require(edit.cleanUp.suggestions.first { $0.kind == .filler })
    var accepted = edit
    #expect(CleanUp.accept(s.id, in: &accepted))
    #expect(accepted.cuts.contains(s.cut!) && accepted.cleanUp.applied.contains { $0.id == s.id })
    #expect(CleanUp.dismiss(s.id, in: &edit))
    #expect(edit.cleanUp.suggestions.isEmpty)
    #expect(!CleanUp.plan(input, edit: edit).suggestions.contains { $0.kind == .filler })
}

@Test func cleanUpRecordRoundTripsAndOlderFilesHaveNone() throws {
    var edit = EditDocument()
    CleanUp.apply(CleanUp.plan(speech(twoSentences, duration: 5), edit: edit), to: &edit)
    edit.cleanUp.restored = [.init(kind: .filler, range: TimeRange(start: 1, end: 1.2))]
    let data = try JSONCoding.encoder.encode(edit)
    let back = try JSONCoding.decoder.decode(EditDocument.self, from: data)
    #expect(back.cleanUp == edit.cleanUp)
    let old = try JSONCoding.decoder.decode(EditDocument.self, from: Data(#"{"formatVersion": 1, "cuts": []}"#.utf8))
    #expect(old.cleanUp.isEmpty)
    // An item of a kind from a newer version is skipped, not the whole record.
    let newer = #"{"cleanUp": {"applied": [{"id": "x", "kind": "hum", "range": {"start": 0, "end": 1}, "reason": "", "confidence": 1}, {"id": "pause-1", "kind": "pause", "range": {"start": 1, "end": 2}, "cut": {"start": 1.2, "end": 1.8}, "reason": "pause", "confidence": 0.9}]}}"#
    let n = try JSONCoding.decoder.decode(EditDocument.self, from: Data(newer.utf8))
    #expect(n.cleanUp.applied.map(\.id) == ["pause-1"])
}

@Test func cleanUpWithoutATranscriptUsesTheVoiceLevel() {
    // Speech 0.4–1.4 and 3.4–4.5, no words.
    let env = envelope(duration: 5, loud: [(0.4, 1.4, -20), (3.4, 4.5, -20)])
    let report = CleanUp.plan(CleanUpInputs(duration: 5, envelope: env, frameRate: 50), edit: EditDocument())
    #expect(report.count(.pause) == 1)
    #expect(report.applied.allSatisfy { $0.kind != .filler && $0.kind != .retake })
}

@Test func cleanUpThresholdFollowsTheRoom() {
    // A noisy room: the floor at -40 dBFS puts the threshold at -33, not the fixed -45.
    let env = AudioEnvelope(levels: [Float](repeating: -40, count: 100) + [Float](repeating: -15, count: 20))
    #expect(abs(env.adaptiveThreshold() - (-33)) < 0.01)
    #expect(AudioEnvelope(levels: [Float](repeating: -100, count: 50)).adaptiveThreshold() == -60)
    #expect(AudioEnvelope(levels: [], window: 0.02).quietest(in: TimeRange(start: 0, end: 1)) == nil)
}

@Test func timelineReportsCutJoins() {
    let tl = EditTimeline(duration: 10, trim: nil, cuts: [TimeRange(start: 2, end: 3), TimeRange(start: 6, end: 7)],
                          speed: SpeedSettings(segments: [SpeedSegment(range: TimeRange(start: 4, end: 5), rate: 2)]))
    // Speed changes aren't joins; the two cuts are.
    #expect(tl.joins == [2, 4.5])
    #expect(tl.lastJoin(atOrBeforeOutput: 1) == nil)
    let j = try! #require(tl.lastJoin(atOrBeforeOutput: 4.4))
    #expect(j.output == 2 && j.sourceBefore == 2 && j.sourceAfter == 3)
    #expect(tl.lastJoin(atOrBeforeOutput: 5)?.sourceAfter == 7)
    #expect(CleanUp.summary(applied: [], suggestions: 0) == "Nothing to clean up")
}
