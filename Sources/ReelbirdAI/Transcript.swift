import Foundation
import ReelbirdCore

/// A timed transcript. Times are seconds; which timeline they are on depends on the producer
/// (`Transcriber` returns times relative to the audio file; shift by the track's `startTime`
/// to put them on the recording timeline).
public struct Transcript: Codable, Hashable, Sendable {
    /// One recognised word (or token) with its time range. Punctuation stays attached ("screen.").
    public struct Word: Codable, Hashable, Sendable {
        public var range: TimeRange
        public var text: String
        /// Recogniser confidence 0...1, when reported.
        public var confidence: Double?
        public init(range: TimeRange, text: String, confidence: Double? = nil) {
            self.range = range; self.text = text; self.confidence = confidence
        }
    }

    /// A phrase or sentence as returned by the recogniser.
    public struct Segment: Codable, Hashable, Sendable {
        public var range: TimeRange
        public var text: String
        /// Word timings. May be empty if the recogniser did not report them.
        public var words: [Word]
        public init(range: TimeRange, text: String, words: [Word] = []) {
            self.range = range; self.text = text; self.words = words
        }
    }

    public var segments: [Segment]
    /// BCP 47 identifier of the recognised language, e.g. "en-US".
    public var locale: String

    public init(segments: [Segment], locale: String) {
        self.segments = segments; self.locale = locale
    }

    /// The whole transcript as plain text.
    public var text: String {
        segments.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Every word in order. Segments without word timings contribute words spread evenly over the segment.
    public var allWords: [Word] { segments.flatMap(\.timedWords) }

    public var isEmpty: Bool { segments.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    /// End time of the last segment.
    public var duration: Double { segments.map(\.range.end).max() ?? 0 }

    /// Every time moved by `offset` seconds (e.g. a track's `startTime`, to land on the recording timeline).
    public func shifted(by offset: Double) -> Transcript {
        guard offset != 0 else { return self }
        func s(_ r: TimeRange) -> TimeRange { TimeRange(start: r.start + offset, end: r.end + offset) }
        return Transcript(segments: segments.map { seg in
            Segment(range: s(seg.range), text: seg.text,
                    words: seg.words.map { Word(range: s($0.range), text: $0.text, confidence: $0.confidence) })
        }, locale: locale)
    }

    /// Maps recording-timeline times onto an edited output timeline: words inside cuts or outside
    /// the trim are dropped, the rest move to their output time. Segments left empty are removed.
    public func remapped(to timeline: EditTimeline) -> Transcript {
        var out: [Segment] = []
        for seg in segments {
            var words: [Word] = []
            for w in seg.timedWords {
                // Keep a word if its midpoint survives the edit.
                let mid = (w.range.start + w.range.end) / 2
                guard let m = timeline.outputTime(forSource: mid) else { continue }
                let start = timeline.outputTime(forSource: w.range.start) ?? max(0, m - w.range.duration / 2)
                let end = timeline.outputTime(forSource: min(w.range.end, w.range.end - 1e-6)) ?? (m + w.range.duration / 2)
                words.append(Word(range: TimeRange(start: start, end: max(start, end)), text: w.text, confidence: w.confidence))
            }
            guard let first = words.first, let last = words.last else { continue }
            out.append(Segment(range: TimeRange(start: first.range.start, end: last.range.end),
                               text: words.map(\.text).joined(separator: " "), words: words))
        }
        return Transcript(segments: out, locale: locale)
    }
}

extension Transcript.Segment {
    /// Word timings, or words spread evenly across the segment (weighted by length) if none were reported.
    public var timedWords: [Transcript.Word] {
        if !words.isEmpty { return words }
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let total = Double(tokens.reduce(0) { $0 + $1.count + 1 })
        var t = range.start
        return tokens.map { tok in
            let d = range.duration * Double(tok.count + 1) / total
            defer { t += d }
            return Transcript.Word(range: TimeRange(start: t, end: t + d), text: tok)
        }
    }
}
