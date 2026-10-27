import Foundation

/// A word shown in a styled caption, on the recording timeline.
public struct CaptionWord: Hashable, Sendable {
    public var range: TimeRange
    public var text: String
    /// Worth a stronger look (a number, a name, a superlative). Used by Pop and Slam.
    public var emphasis: Bool
    public init(range: TimeRange, text: String, emphasis: Bool = false) {
        self.range = range; self.text = text; self.emphasis = emphasis
    }
}

/// Words that appear together: one breath of speech for the phrase styles, one or two words for One Word and
/// Slam. `range` is when the group is on screen (a little before its first word to a little after its last).
public struct CaptionGroup: Hashable, Sendable {
    public var words: [CaptionWord]
    public var range: TimeRange
    public init(words: [CaptionWord], range: TimeRange) { self.words = words; self.range = range }
}

/// Turns a word-timed transcript into caption groups. Pure and deterministic, so preview and export agree.
///
/// Phrase rules follow common caption practice: a new group at a pause of 0.5 s or more, at the end of a
/// sentence, or at 6 words or 2.5 s; at least 2 words and 0.5 s on screen where possible; never two groups at
/// once; a group lingers up to 0.6 s after its last word.
public enum CaptionGroups {
    public static let maxWords = 6
    public static let maxSpan = 2.5
    public static let pauseBreak = 0.5
    public static let linger = 0.6

    // MARK: Reading transcript.json

    private struct File: Decodable {
        struct Word: Decodable { var range: TimeRange; var text: String }
        struct Segment: Decodable {
            var range: TimeRange
            var text: String
            var words: [Word]?
            var hidden: Bool?
        }
        var segments: [Segment]
    }

    /// The words of a `transcript.json` (see `ReelbirdAI.Transcript`) in time order, leaving out segments hidden
    /// from captions. Segments without word timings have their words spread evenly over the segment.
    public static func words(transcriptJSON data: Data) -> [CaptionWord]? {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        var out: [CaptionWord] = []
        for seg in file.segments where seg.hidden != true {
            let timed = (seg.words ?? []).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            if !timed.isEmpty {
                out += timed.map { CaptionWord(range: $0.range, text: $0.text.trimmingCharacters(in: .whitespaces)) }
            } else {
                let parts = seg.text.split(whereSeparator: \.isWhitespace).map(String.init)
                guard !parts.isEmpty, seg.range.duration > 0 else { continue }
                let step = seg.range.duration / Double(parts.count)
                for (i, p) in parts.enumerated() {
                    let s = seg.range.start + Double(i) * step
                    out.append(CaptionWord(range: TimeRange(start: s, end: s + step), text: p))
                }
            }
        }
        out.sort { $0.range.start < $1.range.start }
        return markEmphasis(out)
    }

    // MARK: Grouping

    /// Groups for a style. `.none` and `.classic` (which draws sentence cues) get the phrase grouping.
    public static func groups(_ words: [CaptionWord], style: CaptionSettings.Style) -> [CaptionGroup] {
        guard !words.isEmpty else { return [] }
        return style.isWordAtATime ? timed(wordGroups(words), lead: 0.04, linger: 0.05, minShown: 0.25)
                                   : timed(phraseGroups(words), lead: 0.08, linger: linger, minShown: 0.5)
    }

    static func endsSentence(_ w: String) -> Bool {
        guard let last = w.trimmingCharacters(in: CharacterSet(charactersIn: "\"')]”’")).last else { return false }
        return ".?!…".contains(last)
    }

    static func phraseGroups(_ words: [CaptionWord]) -> [[CaptionWord]] {
        var groups: [[CaptionWord]] = []
        var cur: [CaptionWord] = []
        for (i, w) in words.enumerated() {
            cur.append(w)
            let next = i + 1 < words.count ? words[i + 1] : nil
            guard let next else { break }
            let gap = next.range.start - w.range.end
            let span = next.range.end - cur[0].range.start
            if endsSentence(w.text) || gap >= pauseBreak || (w.text.hasSuffix(",") && gap >= 0.25)
                || cur.count >= maxWords || span > maxSpan {
                groups.append(cur)
                cur = []
            }
        }
        if !cur.isEmpty { groups.append(cur) }
        // A lone word joins a neighbour when it fits, unless it stands alone after a long pause ("Wait.").
        var merged: [[CaptionWord]] = []
        for g in groups {
            if g.count == 1, let prev = merged.last, prev.count < maxWords, !endsSentence(prev.last!.text),
               g[0].range.start - prev.last!.range.end < pauseBreak {
                merged[merged.count - 1].append(g[0])
            } else {
                merged.append(g)
            }
        }
        return merged
    }

    /// One word per group; a short function word ("a", "the", "to") rides with the word after it.
    static func wordGroups(_ words: [CaptionWord]) -> [[CaptionWord]] {
        var groups: [[CaptionWord]] = []
        var carry: [CaptionWord] = []
        for (i, w) in words.enumerated() {
            carry.append(w)
            let short = w.text.count <= 3 && !endsSentence(w.text) && !w.text.hasSuffix(",")
            let next = i + 1 < words.count ? words[i + 1] : nil
            if carry.count == 1, short, let next, next.range.start - w.range.end < 0.3 { continue }
            groups.append(carry)
            carry = []
        }
        if !carry.isEmpty { groups.append(carry) }
        return groups
    }

    /// On-screen ranges: in slightly before the first word, out after the last word plus `linger`, never over
    /// the next group, and at least `minShown` when there is room.
    static func timed(_ groups: [[CaptionWord]], lead: Double, linger: Double, minShown: Double) -> [CaptionGroup] {
        var out: [CaptionGroup] = []
        for (i, g) in groups.enumerated() {
            let start = max(0, g[0].range.start - lead)
            let nextIn = i + 1 < groups.count ? max(0, groups[i + 1][0].range.start - lead) : Double.infinity
            var end = min(nextIn - 0.02, g[g.count - 1].range.end + linger)
            end = max(end, min(nextIn - 0.02, start + minShown))
            out.append(CaptionGroup(words: g, range: TimeRange(start: start, end: max(start + 0.05, end))))
        }
        return out
    }

    /// Index of the group on screen at `t`, if any. `starts` is `groups.map(\.range.start)`.
    public static func index(at t: Double, groups: [CaptionGroup], starts: [Double]) -> Int? {
        var lo = 0, hi = starts.count
        while lo < hi { let m = (lo + hi) / 2; if starts[m] <= t { lo = m + 1 } else { hi = m } }
        let i = lo - 1
        return i >= 0 && groups[i].range.contains(t) ? i : nil
    }

    // MARK: Emphasis

    private static let superlatives: Set<String> = [
        "best", "worst", "fastest", "easiest", "only", "never", "always", "every", "everything", "nothing", "free",
        "instantly", "huge", "biggest", "new", "first", "last", "no", "zero", "all",
    ]

    /// Marks numbers and prices, names in the middle of a sentence, and a few strong words. At most about 30%
    /// of words' sentences get one, so emphasis keeps its meaning: numbers win over names, names over the rest.
    static func markEmphasis(_ words: [CaptionWord]) -> [CaptionWord] {
        var out = words
        var scored: [(i: Int, score: Int)] = []
        for (i, w) in words.enumerated() {
            let core = w.text.trimmingCharacters(in: .punctuationCharacters)
            guard !core.isEmpty else { continue }
            let prevEnds = i == 0 || endsSentence(words[i - 1].text)
            var score = 0
            if core.rangeOfCharacter(from: .decimalDigits) != nil || "$€£%".contains(where: w.text.contains) { score = 3 }
            else if !prevEnds, let f = core.first, f.isUppercase, core != "I", !core.hasPrefix("I'"), !core.hasPrefix("I’") { score = 2 }
            else if superlatives.contains(core.lowercased()) { score = 1 }
            if score > 0 { scored.append((i, score)) }
        }
        let budget = max(1, Int((Double(words.count) * 0.3 / 3).rounded(.up)))
        for s in scored.sorted(by: { $0.score != $1.score ? $0.score > $1.score : $0.i < $1.i }).prefix(budget) {
            out[s.i].emphasis = true
        }
        return out
    }
}

// MARK: Palettes

extension CaptionSettings.Palette {
    /// Caption text colour.
    public var text: RGBA {
        switch self {
        case .paper: RGBA(0x14 / 255.0, 0x14 / 255.0, 0x14 / 255.0)
        default: RGBA(1, 1, 1)
        }
    }
    /// The pill behind the words (`nil` for Bare, which draws a soft shadow instead).
    public var backing: RGBA? {
        switch self {
        case .night: RGBA(0, 0, 0, 0.72)
        case .reelbird: RGBA(0x14 / 255.0, 0x11 / 255.0, 0x0F / 255.0, 0.80)
        case .mint: RGBA(0x0D / 255.0, 0x1A / 255.0, 0x16 / 255.0, 0.78)
        case .paper: RGBA(1, 1, 1, 0.92)
        case .bare: nil
        }
    }
    /// The highlight colour: the spoken word (Highlight), the marker box, emphasis words.
    public var accent: RGBA {
        switch self {
        case .night, .bare: RGBA(hex: "#FFD23F")!
        case .reelbird: RGBA(hex: "#FF5A36")!
        case .mint: RGBA(hex: "#3DDC97")!
        case .paper: RGBA(hex: "#2563EB")!
        }
    }
    /// Text on the accent colour (Marker's box). Ink wherever it reads (12.8:1 on yellow, 5.9:1 on orange, 10.4:1
    /// on mint); white on Paper's blue (5.2:1, where ink would be 3.6:1).
    public var onAccent: RGBA {
        self == .paper ? RGBA(1, 1, 1) : RGBA(0x14 / 255.0, 0x14 / 255.0, 0x14 / 255.0)
    }
    public var title: String {
        switch self {
        case .night: "Night"
        case .reelbird: "Reelbird"
        case .mint: "Mint"
        case .paper: "Paper"
        case .bare: "Bare"
        }
    }
}

extension CaptionSettings.Style {
    public var title: String {
        switch self {
        case .none: "None"
        case .classic: "Classic"
        case .highlight: "Highlight"
        case .marker: "Marker"
        case .pop: "Pop"
        case .oneWord: "One Word"
        case .slam: "Slam"
        }
    }
    /// Single words are harder to follow than lines of 6–12 words (deaf and hard-of-hearing viewers' preference),
    /// so these are offered as social-clip looks, not defaults.
    public var isSocial: Bool { self == .pop || self == .oneWord || self == .slam }
}

extension CaptionSettings.Position {
    public var title: String {
        switch self {
        case .auto: "Auto"
        case .bottom: "Bottom"
        case .belowVideo: "Below video"
        case .top: "Top"
        }
    }
}
