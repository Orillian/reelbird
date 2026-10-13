import Foundation

/// What Find Sensitive Info looks for in recognised screen text.
public enum SensitiveKind: String, Codable, Hashable, Sendable, CaseIterable {
    case email, apiKey, card, phone, custom

    public var title: String {
        switch self {
        case .email: "Email"
        case .apiKey: "API key"
        case .card: "Card number"
        case .phone: "Phone number"
        case .custom: "Custom word"
        }
    }

    /// Short names for the command line (`--kinds email,key,card,phone,custom`).
    public init?(cliName: String) {
        switch cliName.lowercased() {
        case "email", "emails": self = .email
        case "key", "keys", "apikey", "token", "tokens": self = .apiKey
        case "card", "cards": self = .card
        case "phone", "phones": self = .phone
        case "custom", "word", "words": self = .custom
        default: return nil
        }
    }
}

/// One match in a line of text.
public struct SensitiveMatch: Hashable, Sendable {
    public var kind: SensitiveKind
    /// Where it is in the text that was searched.
    public var range: Range<String.Index>
    /// The matched text, normalised for comparing sightings (spaces removed; emails lowercased).
    public var value: String
}

/// Pattern matching for sensitive text: emails, API keys and tokens (known prefixes, `key = value` pairs and
/// high-entropy strings), card numbers (Luhn-checked), phone numbers and custom words. Pure and deterministic.
public enum SensitivePatterns {
    /// All matches in `text`, in order. A match inside a longer match of another kind is dropped (custom words
    /// are always kept).
    public static func matches(in text: String, kinds: Set<SensitiveKind> = Set(SensitiveKind.allCases),
                               customWords: [String] = []) -> [SensitiveMatch] {
        let ns = text as NSString
        var found: [(kind: SensitiveKind, range: NSRange, priority: Int)] = []
        func add(_ kind: SensitiveKind, _ r: NSRange, _ priority: Int) {
            guard r.location != NSNotFound, r.length > 0 else { return }
            found.append((kind, r, priority))
        }
        if kinds.contains(.apiKey) {
            for re in prefixedKeys { for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) { add(.apiKey, m.range, 0) } }
            for m in keyValue.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
                let r = m.range(at: 1)
                guard r.location != NSNotFound else { continue }
                let v = ns.substring(with: r)
                if isPlausibleSecretValue(v) { add(.apiKey, r, 1) }
            }
            for m in tokenRun.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if looksRandom(ns.substring(with: m.range)) { add(.apiKey, m.range, 4) }
            }
        }
        if kinds.contains(.card) {
            for m in cardRun.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let digits = ns.substring(with: m.range).filter(\.isNumber)
                if isCardNumber(digits) { add(.card, m.range, 1) }
            }
        }
        if kinds.contains(.email) {
            for m in email.matches(in: text, range: NSRange(location: 0, length: ns.length)) { add(.email, m.range, 2) }
        }
        if kinds.contains(.phone) {
            for m in phone.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if isPhoneNumber(ns.substring(with: m.range)) { add(.phone, m.range, 3) }
            }
        }
        if kinds.contains(.custom) {
            for word in customWords {
                let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
                guard w.count >= 2 else { continue }
                var search = NSRange(location: 0, length: ns.length)
                while search.length > 0 {
                    let r = ns.range(of: w, options: [.caseInsensitive, .diacriticInsensitive], range: search)
                    guard r.location != NSNotFound else { break }
                    add(.custom, r, -1)
                    let next = r.location + r.length
                    search = NSRange(location: next, length: ns.length - next)
                }
            }
        }
        // Drop matches inside another (non-custom) match that ranks higher or is longer, high-entropy runs that
        // overlap a better match (`GITHUB_TOKEN=ghp_…` is one key, not two), and exact duplicates.
        var kept: [(kind: SensitiveKind, range: NSRange, priority: Int)] = []
        for f in found.sorted(by: { ($0.priority, -$0.range.length, $0.range.location) < ($1.priority, -$1.range.length, $1.range.location) }) {
            if f.kind != .custom, kept.contains(where: { k in
                guard k.kind != .custom else { return false }
                let overlap = NSIntersectionRange(k.range, f.range).length
                return overlap == f.range.length || (f.priority == 4 && overlap > 0)
            }) { continue }
            if kept.contains(where: { $0.kind == f.kind && NSEqualRanges($0.range, f.range) }) { continue }
            kept.append(f)
        }
        return kept.sorted { ($0.range.location, $0.range.length) < ($1.range.location, $1.range.length) }.compactMap { f in
            guard let r = Range(f.range, in: text) else { return nil }
            return SensitiveMatch(kind: f.kind, range: r, value: normalize(String(text[r]), kind: f.kind))
        }
    }

    /// The matched text as compared between sightings.
    public static func normalize(_ s: String, kind: SensitiveKind) -> String {
        let compact = s.filter { !$0.isWhitespace }
        switch kind {
        case .email, .custom: return compact.lowercased()
        case .card, .phone: return compact.filter { $0.isNumber || $0 == "+" }
        case .apiKey: return compact
        }
    }

    /// A masked preview that is safe to show or log: `sk-p…F2`, `j…@example.com`, `•••• 4242`.
    public static func mask(_ value: String, kind: SensitiveKind) -> String {
        let chars = Array(value)
        switch kind {
        case .email:
            guard let at = chars.firstIndex(of: "@"), at > 0 else { return "…" }
            return "\(chars[0])…" + String(chars[at...])
        case .card:
            let digits = chars.filter(\.isNumber)
            return "•••• " + String(digits.suffix(4))
        case .phone:
            let digits = chars.filter(\.isNumber)
            return "••• " + String(digits.suffix(3))
        case .apiKey, .custom:
            if chars.count > 10 { return String(chars.prefix(4)) + "…" + String(chars.suffix(2)) }
            if chars.count > 3 { return String(chars.prefix(1)) + "…" + String(chars.suffix(1)) }
            return "…"
        }
    }

    // MARK: Checks

    /// The Luhn checksum over a string of digits.
    public static func luhnValid(_ digits: String) -> Bool {
        let d = digits.compactMap(\.wholeNumberValue)
        guard d.count == digits.count, d.count >= 2 else { return false }
        var sum = 0
        for (i, v) in d.reversed().enumerated() {
            if i % 2 == 1 { let x = v * 2; sum += x > 9 ? x - 9 : x } else { sum += v }
        }
        return sum % 10 == 0
    }

    /// 13–19 digits, a card network's first digit (2–6), not one repeated digit, and a valid Luhn checksum.
    public static func isCardNumber(_ digits: String) -> Bool {
        guard (13...19).contains(digits.count), let first = digits.first, "23456".contains(first),
              Set(digits).count > 1 else { return false }
        return luhnValid(digits)
    }

    /// 10–15 digits written with separators, or 8–15 after a leading "+". Not an IPv4 address or a card number.
    public static func isPhoneNumber(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        let digits = t.filter(\.isNumber)
        let plus = t.hasPrefix("+")
        guard plus ? (8...15).contains(digits.count) : (10...15).contains(digits.count) else { return false }
        let groups = t.split(whereSeparator: { !$0.isNumber })
        if !plus && groups.count < 2 { return false }
        // 192.168.100.200 or a dotted version number.
        if t.contains("."), !t.contains(" "), !t.contains("-"), groups.count >= 3, groups.allSatisfy({ $0.count <= 3 }) { return false }
        if isCardNumber(digits) { return false }
        // Dates: 2026-10-13, 13/10/2026, 10.13.26.
        let ns = t as NSString
        if datePattern.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) != nil { return false }
        return Set(digits).count > 2
    }

    /// Shannon entropy in bits per character.
    public static func entropy(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for c in s { counts[c, default: 0] += 1 }
        let n = Double(s.count)
        return counts.values.reduce(0) { acc, k in let p = Double(k) / n; return acc - p * log2(p) }
    }

    /// A long run that reads like a random token rather than a word or identifier: mixed letters and digits,
    /// frequent switches between lower case, upper case and digits, and high entropy. Pure hex counts from 32
    /// characters, except exactly 40 (a git commit hash).
    public static func looksRandom(_ s: String) -> Bool {
        let core = s.trimmingCharacters(in: CharacterSet(charactersIn: "-_=+/"))
        guard core.count >= 20 else { return false }
        let hasDigit = core.contains(where: \.isNumber), hasLetter = core.contains(where: \.isLetter)
        guard hasDigit, hasLetter else { return false }
        let hex = core.allSatisfy(\.isHexDigit)
        if hex {
            let lowerOrUpper = core.filter(\.isLetter)
            let oneCase = lowerOrUpper.allSatisfy(\.isLowercase) || lowerOrUpper.allSatisfy(\.isUppercase)
            return oneCase && core.count >= 32 && core.count != 40 && entropy(core) >= 3.3
        }
        // Switches between digits, upper and lower case (symbols such as "/" in a path don't count).
        func cls(_ c: Character) -> Int? { c.isNumber ? 0 : c.isUppercase ? 1 : c.isLowercase ? 2 : nil }
        var switches = 0
        var prev: Int?
        for c in core { guard let k = cls(c) else { continue }; if let p = prev, p != k { switches += 1 }; prev = k }
        return entropy(core) >= 3.6 && Double(switches) / Double(core.count) >= 0.3
    }

    /// A value after `password:` / `token =`: long enough, not a plain word, not a placeholder.
    static func isPlausibleSecretValue(_ v: String) -> Bool {
        guard v.count >= 8 else { return false }
        let lower = v.lowercased()
        if ["********", "xxxxxxxx", "password", "required", "optional", "undefined", "null", "none", "string"].contains(where: { lower.hasPrefix($0) }) {
            return false
        }
        if Set(v).count <= 2 { return false }
        let hasDigit = v.contains(where: \.isNumber)
        let hasSymbol = v.contains(where: { !$0.isLetter && !$0.isNumber })
        let mixedCase = v.contains(where: \.isUppercase) && v.contains(where: \.isLowercase)
        return hasDigit || hasSymbol || mixedCase
    }

    // MARK: Expressions

    private static func re(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
        // The patterns are constants; a typo is a programming error caught by the tests.
        try! NSRegularExpression(pattern: p, options: o)
    }

    /// Tokens with a known vendor prefix.
    static let prefixedKeys: [NSRegularExpression] = [
        re(#"(?<![A-Za-z0-9])sk-(?:proj-|ant-(?:api\d\d-)?|live-|test-|or-v1-)?[A-Za-z0-9_\-]{16,}"#),   // OpenAI, Anthropic, OpenRouter
        re(#"(?<![A-Za-z0-9])(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{10,}"#),                           // Stripe
        re(#"(?<![A-Za-z0-9])gh[pousr]_[A-Za-z0-9]{20,}"#),                                            // GitHub
        re(#"(?<![A-Za-z0-9])github_pat_[A-Za-z0-9_]{20,}"#),
        re(#"(?<![A-Za-z0-9])(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA)[A-Z0-9]{16}(?![A-Za-z0-9])"#),          // AWS access key IDs
        re(#"(?<![A-Za-z0-9])xox[abposr]-[A-Za-z0-9\-]{10,}"#),                                        // Slack
        re(#"(?<![A-Za-z0-9])AIza[0-9A-Za-z_\-]{30,}"#),                                               // Google
        re(#"(?<![A-Za-z0-9])glpat-[A-Za-z0-9_\-]{16,}"#),                                             // GitLab
        re(#"(?<![A-Za-z0-9])SG\.[A-Za-z0-9_\-]{16,}\.[A-Za-z0-9_\-]{16,}"#),                           // SendGrid
        re(#"(?<![A-Za-z0-9])hf_[A-Za-z0-9]{20,}"#),                                                   // Hugging Face
        re(#"(?<![A-Za-z0-9])npm_[A-Za-z0-9]{30,}"#),                                                  // npm
        re(#"(?<![A-Za-z0-9])shp(?:at|ss|ca|pa)_[A-Fa-f0-9]{20,}"#),                                   // Shopify
        re(#"(?<![A-Za-z0-9])dop_v1_[a-f0-9]{40,}"#),                                                  // DigitalOcean
        re(#"(?<![A-Za-z0-9])eyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#),       // JWT
        re(#"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
    ]

    /// `api_key: VALUE`, `token = VALUE`, `password VALUE`, `Bearer VALUE`.
    static let keyValue = re(#"\b(?:api[_ \-]?key|secret(?:[_ \-]?key)?|access[_ \-]?(?:key|token)|auth[_ \-]?token|token|password|passwd|pwd|bearer)\b["']?\s*[:=]?\s*["']?([A-Za-z0-9_\-+/=.!@#$%^&*]{8,})"#,
                             .caseInsensitive)

    /// Long runs of token characters.
    static let tokenRun = re(#"(?<![A-Za-z0-9_\-+/=])[A-Za-z0-9_\-+/=]{20,}(?![A-Za-z0-9_\-+/=])"#)

    /// 13–19 digits, optionally in groups split by single spaces or dashes.
    static let cardRun = re(#"(?<![\d])(?:\d[ \-]?){12,18}\d(?![\d])"#)

    static let email = re(#"[A-Za-z0-9._%+\-]+\s?@\s?[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,24}(?![A-Za-z])"#)

    static let datePattern = re(#"\d{4}[\-/.]\d{1,2}[\-/.]\d{1,2}|\d{1,2}[\-/.]\d{1,2}[\-/.]\d{2,4}"#)

    /// Candidate phone numbers (checked by `isPhoneNumber`).
    static let phone = re(#"(?<![\w+])\+?\(?\d[\d \-.()]{6,}\d(?![\d])"#)
}
