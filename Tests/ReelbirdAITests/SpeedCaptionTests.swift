import Foundation
import ReelbirdCore
import Testing
@testable import ReelbirdAI

/// Captions (transcript, WebVTT) follow speed segments: words keep their order and land at their output time.
@Test func captionsAreRetimedThroughSpeedSegments() {
    let words = [("One", 1.0), ("two", 2.0), ("three", 3.0), ("four", 5.0), ("five", 7.0), ("six", 9.0)].map {
        Transcript.Word(range: TimeRange(start: $0.1, end: $0.1 + 0.4), text: $0.0)
    }
    let t = Transcript(segments: [Transcript.Segment(range: TimeRange(start: 1, end: 9.4), text: words.map(\.text).joined(separator: " "), words: words)],
                       locale: "en-US")
    // 2× over 2–4 s, cut 4.8–5.5 ("four" goes), 0.5× over 6.5–8.
    var speed = SpeedSettings()
    speed.set(TimeRange(start: 2, end: 4), rate: 2)
    speed.set(TimeRange(start: 6.5, end: 8), rate: 0.5)
    let timeline = EditTimeline(duration: 10, trim: nil, cuts: [TimeRange(start: 4.8, end: 5.5)], speed: speed)
    let r = t.remapped(to: timeline)
    #expect(r.allWords.map(\.text) == ["One", "two", "three", "five", "six"])
    for w in r.allWords {
        let source = words.first { $0.text == w.text }!
        #expect(abs(w.range.start - timeline.outputTime(forSource: source.range.start)!) < 1e-9, "\(w.text)")
    }
    // "two" plays at 2× (0.2 s long), "five" at 0.5× (0.8 s long).
    #expect(abs(r.allWords[1].range.duration - 0.2) < 1e-4)
    #expect(abs(r.allWords[3].range.duration - 0.8) < 1e-4)
    #expect(abs(r.allWords[3].range.start - 5.8) < 1e-9)
    let vtt = Captions.webVTT(r)
    #expect(vtt.contains("00:00:01.000 --> "), "\(vtt)")
    #expect(!vtt.contains("four"))
}
