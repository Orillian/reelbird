import Foundation
import ReelbirdCore
import Testing
@testable import ReelbirdAI

// MARK: - Fixtures

/// A hand-made transcript: two sentences, a long pause, then a long run-on sentence.
private func sampleTranscript() -> Transcript {
    func words(_ text: String, from start: Double, step: Double = 0.3) -> [Transcript.Word] {
        text.split(separator: " ").enumerated().map { i, w in
            Transcript.Word(range: TimeRange(start: start + Double(i) * step, end: start + Double(i) * step + step * 0.9), text: String(w))
        }
    }
    let a = words("Hello and welcome to Reelbird.", from: 0.5)
    let b = words("Today I will show you how to record your screen <fast> & easily.", from: 2.2)
    let c = words("First open the menu bar then pick the display you want to record and then press the big record button to begin capturing everything on screen right away", from: 8.0, step: 0.25)
    func seg(_ w: [Transcript.Word]) -> Transcript.Segment {
        Transcript.Segment(range: TimeRange(start: w.first!.range.start, end: w.last!.range.end), text: w.map(\.text).joined(separator: " "), words: w)
    }
    return Transcript(segments: [seg(a), seg(b), seg(c)], locale: "en-US")
}

// MARK: - Captions

@Test func webVTTFormatting() {
    let vtt = Captions.webVTT(sampleTranscript())
    #expect(vtt.hasPrefix("WEBVTT\n\n00:00:00.500 --> "))
    #expect(vtt.contains("&lt;fast&gt; &amp; easily."))
    #expect(!vtt.contains("<fast>"))
    let cues = Captions.cues(sampleTranscript())
    #expect(cues.count >= 4)
    for c in cues {
        #expect(c.lines.count <= 2, "too many lines: \(c.lines)")
        #expect(c.lines.allSatisfy { $0.count <= 42 }, "line too long: \(c.lines)")
        #expect(c.range.duration >= 1.0 - 1e-9 || c.range.end == cues.first(where: { $0.range.start > c.range.start })?.range.start)
        #expect(c.range.duration <= 6.0 + 0.3 + 1e-9)
    }
    // Cues are ordered and never overlap.
    for (a, b) in zip(cues, cues.dropFirst()) { #expect(a.range.end <= b.range.start + 1e-9) }
    // The first sentence is its own cue (sentence end), and the long sentence is split into several cues.
    #expect(cues[0].text == "Hello and welcome to Reelbird.")
    #expect(cues.filter { $0.range.start >= 8.0 }.count >= 2)
}

@Test func pauseStartsNewCue() {
    let w1 = Transcript.Word(range: TimeRange(start: 0, end: 0.4), text: "Okay")
    let w2 = Transcript.Word(range: TimeRange(start: 2.0, end: 2.4), text: "next")
    let t = Transcript(segments: [.init(range: TimeRange(start: 0, end: 2.4), text: "Okay next", words: [w1, w2])], locale: "en-US")
    let cues = Captions.cues(t)
    #expect(cues.map(\.text) == ["Okay", "next"])
    #expect(cues[0].range.end == 1.0)   // minimum duration, still before the next cue
}

@Test func srtFormatting() {
    let srt = Captions.srt(sampleTranscript())
    #expect(srt.hasPrefix("1\n00:00:00,500 --> 00:00:"))
    #expect(srt.contains("\n\n2\n"))
    #expect(srt.contains("<fast> & easily."))   // SRT is not escaped
    #expect(Captions.timestamp(3725.0456, separator: ",") == "01:02:05,046")
}

@Test func lineWrapIsBalanced() {
    let words = "This sentence is long enough that it has to wrap onto two lines".split(separator: " ").map(String.init)
    let lines = Captions.wrap(words, Captions.Options())
    #expect(lines.count == 2)
    #expect(abs(lines[0].count - lines[1].count) <= 12)
}

@Test func transcriptRemapsThroughEdits() {
    let t = sampleTranscript()
    let timeline = EditTimeline(duration: 30, trim: TimeRange(start: 2, end: 30), cuts: [TimeRange(start: 8, end: 10)])
    let r = t.remapped(to: timeline)
    #expect(!r.text.contains("Hello"))          // trimmed away
    #expect(r.allWords.first?.text == "Today")
    #expect(abs((r.allWords.first?.range.start ?? 0) - 0.2) < 1e-6)
    #expect(!r.allWords.contains { $0.text == "First" })   // at 8.0, inside the cut
}

// MARK: - Silence detection

@Test func silenceDetectionFindsKnownGaps() async throws {
    let url = TestAudio.tempURL("m4a")
    defer { try? FileManager.default.removeItem(at: url) }
    try await TestAudio.writeAAC([
        .init(duration: 1.0, amplitude: 0.25), .init(duration: 2.0, amplitude: 0),
        .init(duration: 1.5, amplitude: 0.25), .init(duration: 1.5, amplitude: 0),
        .init(duration: 1.0, amplitude: 0.25), .init(duration: 0.5, amplitude: 0),   // too short to count
        .init(duration: 1.0, amplitude: 0.25),
    ], to: url)

    let ranges = try SilenceDetector.silentRanges(audio: url, thresholdDB: -45, minDuration: 1.2)
    #expect(ranges.count == 2, "\(ranges)")
    if ranges.count == 2 {
        #expect(abs(ranges[0].start - 1.0) < 0.08 && abs(ranges[0].end - 3.0) < 0.08, "\(ranges[0])")
        #expect(abs(ranges[1].start - 4.5) < 0.08 && abs(ranges[1].end - 6.0) < 0.08, "\(ranges[1])")
    }
    let longOnly = try SilenceDetector.silentRanges(audio: url, minDuration: 1.8)
    #expect(longOnly.count == 1)

    let cuts = SilenceDetector.trimCuts(silences: ranges, padding: 0.15)
    #expect(cuts.count == 2)
    #expect(abs(cuts[0].start - (ranges[0].start + 0.15)) < 1e-9)
    #expect(abs(cuts[0].end - (ranges[0].end - 0.15)) < 1e-9)
}

@Test func trimCutsEdgesAndBlips() {
    let cuts = SilenceDetector.trimCuts(silences: [TimeRange(start: 0, end: 2), TimeRange(start: 5, end: 5.4), TimeRange(start: 9, end: 10)],
                                        padding: 0.15, minimumCut: 0.3, duration: 10)
    #expect(cuts == [TimeRange(start: 0, end: 1.85), TimeRange(start: 9.15, end: 10)])
    // A 60 ms blip inside silence doesn't split it.
    var levels = [Float](repeating: -80, count: 100)
    levels[50] = -10; levels[51] = -10; levels[52] = -10
    let r = SilenceDetector.silentRanges(levels: levels, windowDuration: 0.02, origin: 0, thresholdDB: -45, minDuration: 1.2)
    #expect(r.count == 1 && abs(r[0].duration - 2.0) < 1e-9)
}

@Test func silenceDetectorReportsMissingFile() {
    #expect(throws: SilenceDetectorError.self) {
        try SilenceDetector.silentRanges(audio: URL(fileURLWithPath: "/nonexistent/a.m4a"))
    }
}

// MARK: - Transcription (runs only when the on-device speech model is available)

private let speechText = "Hello and welcome. Today I will show you how to record your screen. First, open the menu bar."

@Test(.enabled("on-device speech model available for en-US") {
    let a = await Transcriber.availability(for: Locale(identifier: "en-US"))
    if !a.canTranscribe { print("SKIP transcription test: \(a)") }
    return a.canTranscribe
})
func transcribesSpeechWithWordTimings() async throws {
    let aiff = TestAudio.tempURL("aiff")
    defer { try? FileManager.default.removeItem(at: aiff) }
    guard TestAudio.say(speechText, to: aiff) != nil else {
        print("SKIP: `say` could not synthesise speech")
        return
    }
    for path in [Transcriber.InputPath.automatic, .audioFile] {
        let t = try await Transcriber.transcribe(audio: aiff, locale: Locale(identifier: "en-US"), input: path, progress: nil)
        let text = t.text.lowercased()
        #expect(text.contains("welcome"), "\(path): \(t.text)")
        #expect(text.contains("record"), "\(path): \(t.text)")
        #expect(text.contains("screen"), "\(path): \(t.text)")
        let words = t.allWords
        #expect(words.count >= 15)
        for (a, b) in zip(words, words.dropFirst()) { #expect(a.range.start <= b.range.start) }
        #expect(words.allSatisfy { $0.range.end >= $0.range.start && $0.range.end < 15 })
        let vtt = Captions.webVTT(t)
        #expect(vtt.hasPrefix("WEBVTT"))
    }
}

@Test(.enabled("on-device speech model available for en-US") {
    await Transcriber.availability(for: Locale(identifier: "en-US")).canTranscribe
})
func transcribesAACInMP4() async throws {
    let m4a = TestAudio.tempURL("m4a")
    defer { try? FileManager.default.removeItem(at: m4a) }
    guard TestAudio.say("Recording your screen is easy.", to: m4a, extraArgs: ["--file-format=m4af", "--data-format=aac"]) != nil else {
        print("SKIP: `say` could not write AAC")
        return
    }
    let t = try await Transcriber.transcribe(audio: m4a, locale: Locale(identifier: "en-US"))
    #expect(t.text.lowercased().contains("screen"), "\(t.text)")
}

@Test func transcriberReportsMissingFile() async {
    await #expect(throws: TranscriberError.self) {
        _ = try await Transcriber.transcribe(audio: URL(fileURLWithPath: "/nonexistent/a.m4a"))
    }
}

// MARK: - Story suggestions

@Test func chunkingRespectsBudget() {
    let lines = (0..<400).map { StorySuggester.Line(time: Double($0 * 9), text: "This is sentence number \($0) about recording the screen and editing zoom.") }
    let budget = StorySuggester.chunkCharacterBudget(contextSize: 4096)
    let chunks = StorySuggester.chunk(lines, budget: budget)
    #expect(chunks.count > 1)
    #expect(chunks.flatMap { $0 } == lines)
    for c in chunks { #expect(c.map(\.rendered).joined(separator: "\n").count <= budget) }
}

@Test func finalizeSnapsAndCleans() {
    let t = Transcript(segments: [0.5, 20, 25, 60].map { .init(range: TimeRange(start: $0, end: $0 + 4), text: "Line at \($0)") }, locale: "en-US")
    let draft = StorySuggester.Draft(title: "\"Recording with Reelbird.\"", chapters: [
        (time: 58, title: "Recording"), (time: 1.0, title: "Intro"), (time: 22, title: "Close"), (time: 26, title: "Too close"), (time: 999, title: "Past end"),
    ])
    let r = StorySuggester.finalize(draft: draft, transcript: t)
    #expect(r.title == "Recording with Reelbird")
    #expect(r.chapters.map(\.time) == [0, 20, 60])
    #expect(r.chapters.map(\.title) == ["Intro", "Close", "Recording"])
}

@Test(.enabled("Apple Intelligence available") {
    if !StorySuggester.isAvailable { print("SKIP story test: \(StorySuggester.unavailableReason ?? "")") }
    return StorySuggester.isAvailable
})
func suggestsTitleAndChapters() async throws {
    let script: [(Double, String)] = [
        (0, "Hi, in this video I'll show you how to set up Reelbird and record your first screen recording."),
        (12, "First, download the app and drag it to your Applications folder."),
        (40, "When you open it, macOS asks for screen recording permission. Click Open System Settings and turn it on."),
        (95, "Now pick a display from the menu bar and press record. A three second countdown starts."),
        (150, "While recording, Reelbird tracks your clicks so it can zoom in automatically later."),
        (210, "When you're done, press stop. The editor opens with auto zoom already applied."),
        (260, "You can change the background, the padding and the zoom intensity on the right."),
        (320, "Finally, click share to upload it to your own bucket and copy the link. Thanks for watching."),
    ]
    let t = Transcript(segments: script.map { .init(range: TimeRange(start: $0.0, end: $0.0 + 8), text: $0.1) }, locale: "en-US")
    let r = try await StorySuggester.suggest(transcript: t)
    print("Suggested title: \(r.title); chapters: \(r.chapters.map { "\(Int($0.time))s \($0.title)" })")
    #expect(!r.title.isEmpty && r.title.count <= 80)
    #expect(r.chapters.first?.time == 0)
    #expect(r.chapters.count >= 2)
    let starts = Set(t.segments.map(\.range.start))
    #expect(r.chapters.allSatisfy { starts.contains($0.time) })
    #expect(zip(r.chapters, r.chapters.dropFirst()).allSatisfy { $0.time < $1.time })
}

@Test(.enabled("Apple Intelligence available") { StorySuggester.isAvailable })
func suggestsForLongTranscriptInChunks() async throws {
    let topics = ["installing the app", "granting permissions", "choosing a display", "recording with the camera",
                  "editing auto zoom", "changing the background", "adding captions", "exporting a GIF", "sharing a link"]
    var segments: [Transcript.Segment] = []
    var t = 0.0
    for topic in topics {
        for i in 0..<14 {
            segments.append(.init(range: TimeRange(start: t, end: t + 7),
                                  text: "Now we are \(topic). Step \(i + 1) of \(topic) is shown on screen, and I explain each option in detail as I click through it."))
            t += 8
        }
    }
    let transcript = Transcript(segments: segments, locale: "en-US")
    #expect(StorySuggester.chunk(StorySuggester.timestampedLines(transcript), budget: StorySuggester.chunkCharacterBudget(contextSize: 4096)).count > 1)
    let r = try await StorySuggester.suggest(transcript: transcript)
    print("Long suggestion: \(r.title); \(r.chapters.count) chapters")
    #expect(!r.title.isEmpty)
    #expect(r.chapters.count >= 2 && r.chapters.first?.time == 0)
}
