import Dispatch
import Foundation
import ReelbirdCore

/// `reelbird record`: start, show status on stderr, stop cleanly on Ctrl-C, --duration or when the recorder ends.
enum Recorder {
    static func params(from a: ParsedArguments) throws -> RecordParams {
        var p = RecordParams()
        let picked = ["display", "window", "area"].filter { a.value($0) != nil } + (a.has("synthetic") ? ["synthetic"] : [])
        guard picked.count <= 1 else { throw CLIError.usage("Choose one of --display, --window or --area.") }
        if let d = a.value("display") { p.selector = .display(d) }
        if let w = a.value("window") { p.selector = .window(w) }
        if let area = a.value("area") { p.selector = try parseArea(area) }
        if a.has("synthetic") { p.selector = .synthetic }
        if a.value("synthetic-mic") != nil, !a.has("synthetic") { throw CLIError.usage("--synthetic-mic needs --synthetic.") }
        p.duration = try a.double("duration")
        p.frameRate = try a.int("fps") ?? 60
        if let q = a.value("quality") {
            guard let quality = RecordingOptions.Quality(rawValue: q.lowercased()) else {
                throw CLIError.usage("Unknown quality '\(q)'. Use high, max or compact.")
            }
            p.quality = quality
        }
        p.microphone = a.value("mic") ?? "default"
        if a.has("system-audio") && a.has("no-system-audio") { throw CLIError.usage("Pass --system-audio or --no-system-audio, not both.") }
        p.systemAudio = a.toggle("system-audio") ?? true
        p.camera = a.value("camera")
        p.keystrokes = a.has("keystrokes")
        p.share = a.has("share")
        p.out = a.value("out")
        return p
    }

    static func parseArea(_ s: String) throws -> SourceSelector {
        let n = s.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard n.count == 4, let x = n[0], let y = n[1], let w = n[2], let h = n[3], w > 0, h > 0 else {
            throw CLIError.usage("--area expects X,Y,W,H in points, e.g. --area 0,0,1280,720.")
        }
        return .area(x: x, y: y, width: w, height: h, display: nil)
    }

    static func run(_ a: ParsedArguments, ops: Operations) async throws -> Report {
        let p = try params(from: a)
        let (options, url) = try await ops.makeOptions(p)
        let control = try await ops.engine.startRecording(options: options, bundleURL: url)
        Console.err("Recording to \(Format.path(url)). Press Ctrl-C to stop.")

        let (stops, trigger) = AsyncStream<String>.makeStream()
        let signals = SignalTrap { count in
            if count == 1 {
                trigger.yield("interrupt")
            } else {
                // Segments already on disk survive; `reelbird recover` rebuilds the project.
                Console.err("\nQuitting without finalising. Run `reelbird recover \"\(url.path)\"` to rebuild the project.")
                exit(ExitCode.interrupted.rawValue)
            }
        }
        defer { signals.cancel() }

        let timer = Task {
            guard let d = p.duration else { return }
            try? await Task.sleep(nanoseconds: UInt64(d * 1_000_000_000))
            if !Task.isCancelled { trigger.yield("duration") }
        }
        let watcher = Task {
            let interactive = Console.stderrIsTerminal
            var lastWarnings: [HealthWarning] = []
            var lastPrinted = -10.0
            for await s in control.status {
                if interactive {
                    let meter = String(repeating: "▮", count: Int((s.microphoneLevel * 5).rounded())).padding(toLength: 5, withPad: "▯", startingAt: 0)
                    var line = "\r\u{1B}[2K● \(s.phase == .paused ? "PAUSED" : "REC") \(Format.duration(s.elapsed))  mic \(meter)"
                    if s.droppedFrames > 0 { line += "  dropped \(s.droppedFrames)" }
                    if s.uploadBacklog > 0 { line += "  uploading \(s.uploadBacklog)" }
                    Console.errInline(line)
                } else if s.elapsed - lastPrinted >= 10 {
                    lastPrinted = s.elapsed
                    Console.err("recording \(Format.duration(s.elapsed))")
                }
                if s.warnings != lastWarnings {
                    for w in s.warnings where !lastWarnings.contains(w) { Console.err("\nWarning: \(w.message)") }
                    lastWarnings = s.warnings
                }
                if s.phase == .finished || s.phase == .failed { break }
            }
            trigger.yield("ended")
        }

        var reason = "ended"
        for await r in stops { reason = r; break }
        timer.cancel()
        if Console.stderrIsTerminal { Console.errInline("\r\u{1B}[2K") }
        Console.err(reason == "interrupt" ? "Stopping…" : "Finishing…")
        let bundle: ProjectBundle
        do { bundle = try await control.stop() } catch {
            watcher.cancel()
            throw CLIError("Recording stopped with an error: \(error.localizedDescription)",
                           hint: "The take may still be on disk; try `reelbird recover \"\(url.path)\"`.")
        }
        watcher.cancel()
        return ops.recordingFinished(bundle)
    }
}

/// Catches SIGINT/SIGTERM so the first Ctrl-C can stop a recording cleanly. Calls `handler` with the signal count.
final class SignalTrap: @unchecked Sendable {
    private let sources: [any DispatchSourceSignal]
    private let lock = NSLock()
    private var count = 0

    init(_ handler: @escaping @Sendable (Int) -> Void) {
        let queue = DispatchQueue(label: "reelbird.signals")
        var made: [any DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            made.append(s)
        }
        sources = made
        for s in sources {
            s.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.count += 1; let n = self.count; self.lock.unlock()
                handler(n)
            }
            s.resume()
        }
    }

    func cancel() {
        for s in sources { s.cancel() }
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }
}
