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
        /// Left out of captions (the audio stays). Absent in files from before this existed.
        public var hidden: Bool?
        public init(range: TimeRange, text: String, words: [Word] = [], hidden: Bool? = nil) {
            self.range = range; self.text = text; self.words = words; self.hidden = hidden
        }
    }

    public var segments: [Segment]
    /// BCP 47 identifier of the recognised language, e.g. "en-US".
    public var locale: String

    public init(segments: [Segment], locale: String) {
        self.segments = segments; self.locale = locale
    }

    /// The segments shown as captions (hidden ones left out).
    public var captioned: Transcript { Transcript(segments: segments.filter { $0.hidden != true }, locale: locale) }

    /// Replaces the text of segment `index`, keeping its timing: when the word count is unchanged each new word
    /// takes the old word's time slot; otherwise the new words share the segment's span in proportion to length.
    public func replacingText(ofSegment index: Int, with newText: String) -> Transcript {
        guard segments.indices.contains(index) else { return self }
        var t = self
        let seg = segments[index]
        let tokens = newText.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return self }
        let old = seg.timedWords
        var words: [Word]
        if tokens.count == old.count {
            words = zip(old, tokens).map { Word(range: $0.range, text: $1, confidence: $0.confidence) }
        } else {
            let span = TimeRange(start: old.first?.range.start ?? seg.range.start, end: old.last?.range.end ?? seg.range.end)
            let total = Double(tokens.reduce(0) { $0 + $1.count + 1 })
            var at = span.start
            words = tokens.map { tok in
                let d = span.duration * Double(tok.count + 1) / max(1, total)
                defer { at += d }
                return Word(range: TimeRange(start: at, end: at + d), text: tok)
            }
        }
        t.segments[index] = Segment(range: seg.range, text: tokens.joined(separator: " "), words: words, hidden: seg.hidden)
        return t
    }

    /// Every other word equal to `old` (ignoring case and surrounding punctuation) becomes `new`, keeping its
    /// punctuation and timing. Returns the transcript and how many words changed.
    public func replacingWord(_ old: String, with new: String) -> (Transcript, Int) {
        func core(_ w: String) -> String { w.trimmingCharacters(in: .punctuationCharacters).lowercased() }
        let target = core(old)
        guard !target.isEmpty else { return (self, 0) }
        var t = self, n = 0
        for i in t.segments.indices {
            var seg = t.segments[i]
            var words = seg.timedWords
            var changed = false
            for j in words.indices where core(words[j].text) == target {
                let w = words[j].text
                let lead = w.prefix(while: { $0.isPunctuation }), trail = String(w.reversed().prefix(while: { $0.isPunctuation }).reversed())
                let replacement = String(lead) + new.trimmingCharacters(in: .punctuationCharacters) + trail
                if replacement != w { words[j].text = replacement; changed = true; n += 1 }
            }
            if changed {
                seg.words = words
                seg.text = words.map(\.text).joined(separator: " ")
                t.segments[i] = seg
            }
        }
        return (t, n)
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
                    words: seg.words.map { Word(range: s($0.range), text: $0.text, confidence: $0.confidence) }, hidden: seg.hidden)
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
                               text: words.map(\.text).joined(separator: " "), words: words, hidden: seg.hidden))
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
