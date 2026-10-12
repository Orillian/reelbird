import Foundation
import ReelbirdCore

/// Process exit codes (BSD sysexits where one fits).
enum ExitCode: Int32, Sendable {
    case ok = 0
    /// The operation ran and failed.
    case failure = 1
    /// Bad command line (EX_USAGE).
    case usage = 64
    /// Bad input data, e.g. an invalid edit value (EX_DATAERR).
    case dataError = 65
    /// Project or file not found (EX_NOINPUT).
    case noInput = 66
    /// Feature not available on this Mac or in this build (EX_UNAVAILABLE).
    case unavailable = 69
    /// Interrupted before the work was saved.
    case interrupted = 130
}

/// An error with a message meant for people (and agents) and an exit code.
struct CLIError: Error, LocalizedError, Sendable {
    var message: String
    var code: ExitCode
    var hint: String?

    init(_ message: String, code: ExitCode = .failure, hint: String? = nil) {
        self.message = message; self.code = code; self.hint = hint
    }

    static func usage(_ message: String, hint: String? = nil) -> CLIError { CLIError(message, code: .usage, hint: hint) }

    var errorDescription: String? { message }

    /// Wraps any error: `CLIError`s pass through, others keep their localized description.
    static func wrap(_ error: any Error) -> CLIError {
        if let e = error as? CLIError { return e }
        if error is CancellationError { return CLIError("Cancelled.", code: .interrupted) }
        return CLIError(error.localizedDescription)
    }
}

/// The result of an operation: machine-readable JSON plus a short human summary.
struct Report: Sendable {
    var json: JSONValue
    var text: String
}

/// Writes to stdout/stderr. In `--json` mode stdout carries exactly one JSON document.
enum Console {
    static func out(_ s: String) {
        FileHandle.standardOutput.write(Data((s.hasSuffix("\n") ? s : s + "\n").utf8))
    }

    static func err(_ s: String) {
        FileHandle.standardError.write(Data((s.hasSuffix("\n") ? s : s + "\n").utf8))
    }

    /// Writes without a newline to stderr (progress lines).
    static func errInline(_ s: String) {
        FileHandle.standardError.write(Data(s.utf8))
    }

    static var stderrIsTerminal: Bool { isatty(STDERR_FILENO) == 1 }
    static var stdinIsTerminal: Bool { isatty(STDIN_FILENO) == 1 }

    static func print(_ report: Report, json: Bool) {
        if json { out(report.json.serialized(pretty: true)) } else if !report.text.isEmpty { out(report.text) }
    }

    static func print(_ error: CLIError, json: Bool) {
        if json {
            var e: [String: JSONValue] = ["message": .string(error.message), "exitCode": .int(Int(error.code.rawValue))]
            if let h = error.hint { e["hint"] = .string(h) }
            out(JSONValue.object(["ok": false, "error": .object(e)]).serialized(pretty: true))
        } else {
            err("reelbird: \(error.message)")
            if let h = error.hint { err(h) }
        }
    }
}

/// A throttled progress line on stderr ("Exporting… 42%").
final class ProgressLine: @unchecked Sendable {
    private let label: String
    private let lock = NSLock()
    private var lastPercent = -1
    private let interactive = Console.stderrIsTerminal

    init(_ label: String) { self.label = label }

    func update(_ fraction: Double) {
        let p = Int((min(1, max(0, fraction)) * 100).rounded(.down))
        lock.lock(); defer { lock.unlock() }
        if interactive {
            guard p != lastPercent else { return }
            lastPercent = p
            Console.errInline("\r\(label) \(p)%")
        } else {
            // Non-interactive: a line every 10%.
            guard p / 10 != lastPercent / 10 || lastPercent < 0 else { return }
            lastPercent = p
            Console.err("\(label) \(p)%")
        }
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        if interactive && lastPercent >= 0 { Console.errInline("\r\u{1B}[2K") }
    }
}

enum Format {
    /// "1:02:03", "2:05", or "0:07.5" for fractional times under 10 s.
    static func duration(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let total = Int(s.rounded(.down))
        let h = total / 3600, m = (total / 60) % 60, sec = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        if s < 10, (s * 10).rounded() != Double(total) * 10 { return String(format: "0:%04.1f", s) }
        return String(format: "%d:%02d", m, sec)
    }

    static func seconds(_ s: Double) -> String {
        s.rounded() == s ? String(Int(s)) : String(format: "%.2f", s).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }

    static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    /// Home-relative path for display.
    static func path(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
