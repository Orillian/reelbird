import Foundation

/// Fuzzy matching for the editor's command menu: every query letter must appear in order, and matches that
/// start words, run together and come early score higher (the fzy scoring model). Case and accents are ignored;
/// spaces in the query are skipped, so "burn cap" finds "Burn In Captions".
public enum FuzzyMatch {
    public struct Result: Equatable, Sendable {
        /// Higher is better. An exact match scores `.infinity`.
        public var score: Double
        /// Matched character offsets in the text, for highlighting.
        public var positions: [Int]
    }

    static let gapLeading = -0.005
    static let gapTrailing = -0.005
    static let gapInner = -0.01
    static let consecutive = 1.0
    static let wordStart = 0.8
    static let capital = 0.7
    static let afterSeparator = 0.9
    /// Longer texts are only matched on their first characters (titles and keywords are short).
    static let maxLength = 160

    /// Matches `query` against `text`; `nil` when some query letter is missing. An empty query matches with score 0.
    public static func match(_ query: String, in text: String) -> Result? {
        let q = Array(fold(query).filter { !$0.isWhitespace })
        let original = Array(text.prefix(maxLength))
        let t = original.map { fold(String($0)).first ?? $0 }
        guard !q.isEmpty else { return Result(score: 0, positions: []) }
        let n = q.count, m = t.count
        guard n <= m else { return nil }
        // Quick reject: every letter in order.
        var k = 0
        for c in t where k < n && c == q[k] { k += 1 }
        guard k == n else { return nil }
        if n == m { return Result(score: .infinity, positions: Array(0..<m)) }

        // Bonus for a match at each text position.
        var bonus = [Double](repeating: 0, count: m)
        for j in 0..<m {
            let prev: Character? = j > 0 ? original[j - 1] : nil
            let cur = original[j]
            if prev == nil { bonus[j] = afterSeparator }
            else if let p = prev, p == "/" || p == "-" || p == "_" || p == "(" || p == "." || p == "…" { bonus[j] = afterSeparator }
            else if let p = prev, p.isWhitespace { bonus[j] = wordStart }
            else if let p = prev, p.isLowercase, cur.isUppercase { bonus[j] = capital }
        }

        // D[i][j]: best score with q[i] matched at t[j]. M[i][j]: best score for q[0...i] within t[0...j].
        let negInf = -Double.infinity
        var D = [[Double]](repeating: [Double](repeating: negInf, count: m), count: n)
        var M = D
        for i in 0..<n {
            var prevScore = negInf
            let gap = i == n - 1 ? gapTrailing : gapInner
            for j in 0..<m {
                if q[i] == t[j] {
                    var score = negInf
                    if i == 0 {
                        score = Double(j) * gapLeading + bonus[j]
                    } else if j > 0 {
                        score = max(M[i - 1][j - 1] + bonus[j], D[i - 1][j - 1] + consecutive)
                    }
                    D[i][j] = score
                    prevScore = max(score, prevScore + gap)
                } else {
                    prevScore += gap
                }
                M[i][j] = prevScore
            }
        }
        guard M[n - 1][m - 1] > negInf else { return nil }

        // Walk back for the matched positions.
        var positions = [Int](repeating: 0, count: n)
        var matchRequired = false
        var j = m - 1
        for i in stride(from: n - 1, through: 0, by: -1) {
            while j >= 0 {
                if D[i][j] != negInf, matchRequired || D[i][j] == M[i][j] {
                    matchRequired = i > 0 && j > 0 && M[i][j] == D[i - 1][j - 1] + consecutive
                    positions[i] = j
                    j -= 1
                    break
                }
                j -= 1
            }
        }
        return Result(score: M[n - 1][m - 1], positions: positions)
    }

    /// Orders `items` by how well `query` matches them; items that don't match are dropped. `fields` gives each
    /// item's searchable texts, primary first (a match in a later field, such as a keyword, counts a little less).
    /// `boost` lifts items (recently used commands) among similar matches. Ties keep the input order.
    /// An empty query returns everything, highest boost first.
    public static func rank<T>(_ items: [T], query: String, fields: (T) -> [String], boost: (T) -> Double = { _ in 0 }) -> [T] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var scored: [(score: Double, index: Int)] = []
        for (index, item) in items.enumerated() {
            if trimmed.isEmpty { scored.append((boost(item), index)); continue }
            var best = -Double.infinity
            for (f, text) in fields(item).enumerated() {
                guard let r = match(trimmed, in: text) else { continue }
                let s = r.score.isInfinite ? 1000 : r.score
                best = max(best, f == 0 ? s : s - 0.75)
            }
            if best > -.infinity { scored.append((best + boost(item), index)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return scored.map { items[$0.index] }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
