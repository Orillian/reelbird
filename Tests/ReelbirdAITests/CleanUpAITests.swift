import Foundation
import ReelbirdCore
import Testing
@testable import ReelbirdAI

/// Room noise in the synthetic recordings: a faint tone well under speech, so the noise floor is real.
private let room: Float = 0.002

@Test func cleanUpFindsAFoldedInUmInEncodedAudio() async throws {
    let url = TestAudio.tempURL("m4a")
    defer { try? FileManager.default.removeItem(at: url) }
    // "Click" 1.0–1.4, quiet, "um" 2.0–2.3, a 120 ms dip, "the" 2.42–2.72, quiet.
    try await TestAudio.writeAAC([
        .init(duration: 1.0, amplitude: room), .init(duration: 0.4, amplitude: 0.3), .init(duration: 0.6, amplitude: room),
        .init(duration: 0.3, amplitude: 0.25), .init(duration: 0.12, amplitude: room), .init(duration: 0.3, amplitude: 0.35),
        .init(duration: 0.8, amplitude: room),
    ], to: url)
    let env = try await SilenceDetector.envelope(audio: url)
    // The recogniser left out the "um" and gave its time to "the".
    let words = [CleanUpInputs.Word(range: TimeRange(start: 1.0, end: 1.4), text: "Click"),
                 CleanUpInputs.Word(range: TimeRange(start: 2.0, end: 2.75), text: "the")]
    let report = CleanUp.plan(CleanUpInputs(duration: 3.5, words: words, envelope: env), edit: EditDocument())
    let um = try #require(report.applied.first { $0.kind == .filler }, "\(report)")
    let cut = try #require(um.cut)
    #expect(cut.start > 1.85 && cut.start <= 2.05, "\(cut)")
    #expect(cut.end > 2.25 && cut.end < 2.45, "\(cut)")
}

@Test func adaptiveSilenceFollowsANoisyRoom() async throws {
    let url = TestAudio.tempURL("m4a")
    defer { try? FileManager.default.removeItem(at: url) }
    // Room noise around -37 dBFS: the fixed -45 threshold hears no silence at all.
    let noise: Float = 0.02
    try await TestAudio.writeAAC([
        .init(duration: 1.0, amplitude: 0.3), .init(duration: 2.0, amplitude: noise), .init(duration: 1.0, amplitude: 0.3),
    ], to: url)
    #expect(try await SilenceDetector.silentRanges(audio: url, thresholdDB: -45, minDuration: 1.2).isEmpty)
    let adaptive = try await SilenceDetector.silentRanges(audio: url, adaptiveMargin: 7, minDuration: 1.2)
    #expect(adaptive.count == 1, "\(adaptive)")
    if let r = adaptive.first { #expect(abs(r.start - 1.0) < 0.1 && abs(r.end - 3.0) < 0.1, "\(r)") }
}
