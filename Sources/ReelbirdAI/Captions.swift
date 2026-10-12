import Foundation
import ReelbirdCore

/// Readable caption cues from a timed transcript, as WebVTT or SRT.
///
/// Cues follow common broadcast guidance: at most `maxLines` lines of `maxLineLength` characters,
/// a new cue at every pause and sentence end where possible, lines broken at punctuation or
/// balanced, and each cue on screen for between `minDuration` and `maxDuration` seconds.
public enum Captions {
    public struct Options: Hashable, Sendable {
        public var maxLineLength: Int = 42
        public var maxLines: Int = 2
        /// Shortest time a cue stays on screen (extended into the following gap when possible).
        public var minDuration: Double = 1.0
        /// Longest cue; longer runs of speech are split.
        public var maxDuration: Double = 6.0
        /// A silence at least this long always starts a new cue.
        public var pauseThreshold: Double = 0.6
        /// Cues linger this long after the last word (never overlapping the next cue).
        public var linger: Double = 0.3
        public init(maxLineLength: Int = 42, maxLines: Int = 2, minDuration: Double = 1.0, maxDuration: Double = 6.0,
                    pauseThreshold: Double = 0.6, linger: Double = 0.3) {
            self.maxLineLength = maxLineLength; self.maxLines = maxLines; self.minDuration = minDuration
            self.maxDuration = maxDuration; self.pauseThreshold = pauseThreshold; self.linger = linger
        }
    }

    public struct Cue: Hashable, Sendable {
        public var range: TimeRange
        /// Display lines (already wrapped).
        public var lines: [String]
        public var text: String { lines.joined(separator: "\n") }
    }

    /// WebVTT document for a transcript.
    public static func webVTT(_ t: Transcript, maxLineLength: Int = 42) -> String {
        webVTT(cues: cues(t, options: Options(maxLineLength: maxLineLength)))
    }

    /// SubRip (.srt) document for a transcript.
    public static func srt(_ t: Transcript, maxLineLength: Int = 42) -> String {
        srt(cues: cues(t, options: Options(maxLineLength: maxLineLength)))
    }

    public static func webVTT(cues: [Cue]) -> String {
        var out = "WEBVTT\n"
        for c in cues {
            out += "\n\(timestamp(c.range.start, separator: ".")) --> \(timestamp(c.range.end, separator: "."))\n"
            out += c.lines.map(escapeVTT).joined(separator: "\n") + "\n"
        }
        return out
    }

    public static func srt(cues: [Cue]) -> String {
        var out = ""
        for (i, c) in cues.enumerated() {
            if i > 0 { out += "\n" }
            out += "\(i + 1)\n\(timestamp(c.range.start, separator: ",")) --> \(timestamp(c.range.end, separator: ","))\n"
            out += c.text + "\n"
        }
        return out
    }

    /// Splits a transcript into cues.
    public static func cues(_ t: Transcript, options o: Options = Options()) -> [Cue] {
        let capacity = o.maxLineLength * o.maxLines
        var groups: [[Transcript.Word]] = []

        for segment in t.segments {
            var current: [Transcript.Word] = []
            for word in segment.timedWords {
                let w = Transcript.Word(range: word.range, text: word.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                        confidence: word.confidence)
                guard !w.text.isEmpty else { continue }
                if let last = current.last {
                    let paused = w.range.start - last.range.end >= o.pauseThreshold
                    let candidate = current + [w]
                    let tooLong = !fits(candidate.map(\.text), o) || joinedLength(candidate) > capacity
                    let tooSlow = w.range.end - current[0].range.start > o.maxDuration
                    if paused {
                        groups.append(current); current = []
                    } else if tooLong || tooSlow {
                        // Prefer to break after punctuation in the second half of the cue.
                        let split = bestSplit(current)
                        groups.append(Array(current[..<split]))
                        current = Array(current[split...])
                    }
                }
                current.append(w)
                // End the cue at a sentence end once it has some substance; at a clause end once it is fairly full.
                let len = joinedLength(current)
                if let c = w.text.last {
                    if ".?!…".contains(c), len >= o.maxLineLength / 2 {
                        groups.append(current); current = []
                    } else if ",;:—".contains(c), Double(len) >= Double(capacity) * 0.7 {
                        groups.append(current); current = []
                    }
                }
            }
            if !current.isEmpty { groups.append(current) }
        }

        var cues: [Cue] = groups.compactMap { g in
            guard let f = g.first, let l = g.last else { return nil }
            return Cue(range: TimeRange(start: f.range.start, end: l.range.end), lines: wrap(g.map(\.text), o))
        }
        // Timing: linger, minimum duration, never overlap the next cue.
        for i in cues.indices {
            let nextStart = i + 1 < cues.count ? cues[i + 1].range.start : Double.infinity
            var end = max(cues[i].range.end + o.linger, cues[i].range.start + o.minDuration)
            end = min(end, nextStart)
            cues[i].range.end = max(end, cues[i].range.end)
            if i + 1 < cues.count, cues[i].range.end > nextStart { cues[i].range.end = nextStart }
        }
        return cues
    }

    // MARK: - Layout

    static func joinedLength(_ words: [Transcript.Word]) -> Int {
        words.reduce(0) { $0 + $1.text.count } + max(0, words.count - 1)
    }

    /// Index to split `words` at (words[..<i] stay in the current cue).
    static func bestSplit(_ words: [Transcript.Word]) -> Int {
        guard words.count > 1 else { return words.count }
        let half = words.count / 2
        for i in stride(from: words.count - 1, through: max(1, half), by: -1) {
            if let c = words[i - 1].text.last, ",;:.?!—…".contains(c) { return i }
        }
        return words.count
    }

    /// Whether the words can be laid out in `maxLines` lines.
    static func fits(_ words: [String], _ o: Options) -> Bool {
        if words.count == 1 { return true }
        let lines = wrap(words, o)
        return lines.count <= o.maxLines && lines.allSatisfy { $0.count <= o.maxLineLength }
    }

    /// Wraps words into lines: one line when it fits, otherwise the most balanced break,
    /// preferring breaks after punctuation. Falls back to greedy filling for more than two lines.
    static func wrap(_ words: [String], _ o: Options) -> [String] {
        let full = words.joined(separator: " ")
        if full.count <= o.maxLineLength || words.count < 2 { return [full] }
        if o.maxLines >= 2 {
            var best: (score: Double, i: Int)?
            for i in 1..<words.count {
                let a = words[..<i].joined(separator: " "), b = words[i...].joined(separator: " ")
                guard a.count <= o.maxLineLength, b.count <= o.maxLineLength else { continue }
                var score = Double(abs(a.count - b.count))
                if let c = a.last, ",;:.?!—…".contains(c) { score -= Double(o.maxLineLength) / 3 }
                // Avoid leaving a short function word dangling at the end of the top line.
                if danglers.contains(words[i - 1].lowercased()) {
                    score += Double(o.maxLineLength) / 4
                }
                if best == nil || score < best!.score { best = (score, i) }
            }
            if let best {
                return [words[..<best.i].joined(separator: " "), words[best.i...].joined(separator: " ")]
            }
        }
        var lines: [String] = []
        var line = ""
        for w in words {
            if line.isEmpty { line = w } else if line.count + 1 + w.count <= o.maxLineLength { line += " " + w } else {
                lines.append(line); line = w
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    private static let danglers: Set<String> = ["a", "an", "the", "to", "of", "and", "or", "in", "on", "at", "for", "with", "i"]

    // MARK: - Formatting

    /// "HH:MM:SS.mmm" (WebVTT) or "HH:MM:SS,mmm" (SRT).
    static func timestamp(_ seconds: Double, separator: String) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        let h = ms / 3_600_000, m = (ms / 60_000) % 60, s = (ms / 1000) % 60, f = ms % 1000
        return String(format: "%02d:%02d:%02d", h, m, s) + separator + String(format: "%03d", f)
    }

    static func escapeVTT(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
