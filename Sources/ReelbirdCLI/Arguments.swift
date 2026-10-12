import Foundation
import ReelbirdCore

/// One `--option` a command accepts.
struct OptionSpec: Sendable {
    var name: String
    /// `nil` = boolean flag; otherwise the placeholder shown in help, e.g. "SECONDS".
    var value: String?
    var repeatable = false
    var help: String
    /// Accepted but left out of help (developer and test options).
    var hidden = false

    static func flag(_ name: String, _ help: String, hidden: Bool = false) -> OptionSpec {
        OptionSpec(name: name, value: nil, help: help, hidden: hidden)
    }
    static func value(_ name: String, _ placeholder: String, _ help: String, repeatable: Bool = false, hidden: Bool = false) -> OptionSpec {
        OptionSpec(name: name, value: placeholder, repeatable: repeatable, help: help, hidden: hidden)
    }
}

/// A command's grammar: positionals and options. Parsing is strict: unknown options are errors.
struct CommandSpec: Sendable {
    var name: String
    var summary: String
    /// Positional placeholders, e.g. ["PROJECT"]. A trailing "?" marks an optional one.
    var positionals: [String] = []
    var options: [OptionSpec] = []
    var discussion: String?

    static let globalOptions: [OptionSpec] = [
        .flag("json", "Print machine-readable JSON on stdout"),
        .value("library", "DIR", "Project library folder (default ~/Movies/Reelbird, or $REELBIRD_LIBRARY)"),
        .flag("help", "Show help"),
    ]

    var allOptions: [OptionSpec] { options + Self.globalOptions }

    var usage: String {
        var parts = ["reelbird", name]
        parts += positionals.map { $0.hasSuffix("?") ? "[\($0.dropLast())]" : $0 }
        if !options.isEmpty { parts.append("[options]") }
        return parts.joined(separator: " ")
    }

    var help: String {
        var s = "\(summary)\n\nUsage: \(usage)\n"
        if let discussion { s += "\n\(discussion)\n" }
        let rows = allOptions.filter { !$0.hidden }.map { o -> (String, String) in
            ("--\(o.name)" + (o.value.map { " \($0)" } ?? ""), o.help + (o.repeatable ? " (repeatable)" : ""))
        }
        let width = min(30, (rows.map(\.0.count).max() ?? 0) + 2)
        s += "\nOptions:\n"
        for (l, r) in rows { s += "  " + l.padding(toLength: max(width, l.count + 2), withPad: " ", startingAt: 0) + r + "\n" }
        return s
    }
}

/// Parsed command line for one command.
struct ParsedArguments: Sendable {
    var positionals: [String] = []
    var values: [String: [String]] = [:]
    var flags: Set<String> = []

    func has(_ flag: String) -> Bool { flags.contains(flag) }
    func value(_ name: String) -> String? { values[name]?.last }
    func all(_ name: String) -> [String] { values[name] ?? [] }

    func double(_ name: String) throws -> Double? {
        guard let v = value(name) else { return nil }
        guard let d = Double(v), d.isFinite else { throw CLIError.usage("--\(name) expects a number, got '\(v)'.") }
        return d
    }

    func int(_ name: String) throws -> Int? {
        guard let v = value(name) else { return nil }
        guard let i = Int(v) else { throw CLIError.usage("--\(name) expects a whole number, got '\(v)'.") }
        return i
    }

    /// `--name` / `--no-name` pair (nil if neither was given).
    func toggle(_ name: String) -> Bool? {
        if has(name) { return true }
        if has("no-\(name)") { return false }
        return nil
    }

    func positional(_ i: Int) -> String? { i < positionals.count ? positionals[i] : nil }
}

enum ArgumentParser {
    /// Parses `args` (after the command name) against `spec`.
    static func parse(_ args: [String], spec: CommandSpec) throws -> ParsedArguments {
        var result = ParsedArguments()
        let options = Dictionary(spec.allOptions.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var i = 0
        var onlyPositionals = false
        while i < args.count {
            let arg = args[i]
            i += 1
            if onlyPositionals || !arg.hasPrefix("-") || arg == "-" || Double(arg) != nil {
                result.positionals.append(arg)
                continue
            }
            if arg == "--" { onlyPositionals = true; continue }
            if arg == "-h" { result.flags.insert("help"); continue }
            guard arg.hasPrefix("--") else {
                throw CLIError.usage("Unknown option '\(arg)'. Options use two dashes, e.g. --json.", hint: "See: reelbird \(spec.name) --help")
            }
            var name = String(arg.dropFirst(2))
            var inline: String?
            if let eq = name.firstIndex(of: "=") {
                inline = String(name[name.index(after: eq)...])
                name = String(name[..<eq])
            }
            guard let opt = options[name] else {
                let suggestion = closest(name, among: Array(options.keys)).map { " Did you mean --\($0)?" } ?? ""
                throw CLIError.usage("Unknown option '--\(name)' for '\(spec.name)'.\(suggestion)", hint: "See: reelbird \(spec.name) --help")
            }
            if opt.value == nil {
                if inline != nil { throw CLIError.usage("--\(name) is a flag and takes no value.") }
                result.flags.insert(name)
                continue
            }
            let value: String
            if let inline {
                value = inline
            } else {
                guard i < args.count else { throw CLIError.usage("--\(name) needs a value (\(opt.value ?? "VALUE")).") }
                value = args[i]
                i += 1
            }
            if !opt.repeatable, result.values[name] != nil {
                throw CLIError.usage("--\(name) was given more than once.")
            }
            result.values[name, default: []].append(value)
        }
        if result.has("help") { return result }
        let required = spec.positionals.filter { !$0.hasSuffix("?") }.count
        if result.positionals.count < required {
            let missing = spec.positionals[result.positionals.count]
            throw CLIError.usage("Missing \(missing).", hint: "Usage: \(spec.usage)")
        }
        if result.positionals.count > spec.positionals.count {
            throw CLIError.usage("Unexpected argument '\(result.positionals[spec.positionals.count])'.", hint: "Usage: \(spec.usage)")
        }
        return result
    }

    /// The closest candidate by edit distance, if reasonably close.
    static func closest(_ word: String, among candidates: [String]) -> String? {
        let scored = candidates.map { ($0, editDistance(word.lowercased(), $0.lowercased())) }.min { $0.1 < $1.1 }
        guard let (best, d) = scored, d <= max(2, word.count / 3) else { return nil }
        return best
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

/// Parsers for time values: "90", "1:30", "1:02:03.5".
enum TimeParsing {
    static func seconds(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (i, p) in parts.enumerated() {
            guard let v = Double(p), v >= 0, v.isFinite else { return nil }
            if i < parts.count - 1, v.rounded() != v { return nil }
            total = total * 60 + v
        }
        return total
    }

    /// "START-END" where END may be "end" (resolved to `duration`).
    static func range(_ s: String, duration: Double?) throws -> TimeRange {
        let parts = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let start = seconds(parts[0]) else {
            throw CLIError.usage("Invalid time range '\(s)'. Use START-END in seconds or m:ss, e.g. 1.2-30 or 0:05-1:20.")
        }
        let end: Double
        if parts[1].isEmpty || parts[1].lowercased() == "end" {
            guard let duration else { throw CLIError.usage("'\(s)': the end of the recording isn't known.") }
            end = duration
        } else {
            guard let e = seconds(parts[1]) else {
                throw CLIError.usage("Invalid time range '\(s)'. Use START-END in seconds or m:ss, e.g. 1.2-30 or 0:05-1:20.")
            }
            end = e
        }
        guard end > start else { throw CLIError.usage("Time range '\(s)' ends before it starts.") }
        return TimeRange(start: start, end: end)
    }
}
