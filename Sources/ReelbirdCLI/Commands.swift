import Foundation
import ReelbirdAI
import ReelbirdCore

/// Command table, help and dispatch.
enum CLI {
    static let commands: [CommandSpec] = [
        CommandSpec(name: "sources", summary: "List displays, windows, microphones and cameras."),
        CommandSpec(name: "record", summary: "Record the screen. Ctrl-C stops and saves.", options: [
            .value("display", "N|ID", "Display index (1 = main) or display ID"),
            .value("window", "ID", "Window ID from `reelbird sources`"),
            .value("area", "X,Y,W,H", "Rectangle in points, top-left origin"),
            .value("duration", "SECONDS", "Stop automatically after this long"),
            .value("fps", "N", "Frame rate (default 60)"),
            .value("quality", "high|max|compact", "Video quality (default high)"),
            .value("mic", "default|ID|none", "Microphone (default: system default)"),
            .flag("system-audio", "Record system audio (default)"),
            .flag("no-system-audio", "Don't record system audio"),
            .value("camera", "ID", "Also record this camera"),
            .flag("keystrokes", "Record key presses for a keystroke overlay"),
            .flag("share", "Upload while recording; the link works the moment you stop"),
            .value("out", "PATH", "Bundle path (default: a new project in the library)"),
            .flag("synthetic", "Record generated frames and tones instead of the screen", hidden: true),
            .value("synthetic-mic", "AUDIO", "With --synthetic: play this audio file as the microphone", hidden: true),
        ], discussion: "Prints the project path (and share link) when done."),
        CommandSpec(name: "info", summary: "Show a project's details.", positionals: ["PROJECT"]),
        CommandSpec(name: "list", summary: "List projects in the library, newest first.", options: [
            .value("limit", "N", "Show at most N projects"),
        ]),
        CommandSpec(name: "edit", summary: "Change a project's edit (edit.json). With no changes, prints it.",
                    positionals: ["PROJECT"], options: [
            .value("set", "KEY=VALUE", "Set a dotted key, e.g. zoom.intensity=0.7, background.kind=solid, background.colors=#1B1B1F", repeatable: true),
            .value("trim", "START-END", "Keep only this range (seconds or m:ss; END may be 'end'); 'none' clears"),
            .value("cut", "START-END", "Remove a range", repeatable: true),
            .flag("clear-cuts", "Remove all cuts first"),
            .flag("crop-toolbar", "Hide the browser toolbar (tabs, address and bookmarks bars), detected from the video"),
            .flag("no-crop", "Show the whole screen again"),
        ], discussion: "PROJECT is a .reelbird path, a name from `reelbird list`, or \"latest\". Crop by hand with --set crop.y=0.08 (normalized to the screen video; x, y, width, height)."),
        CommandSpec(name: "export", summary: "Render the edited video to a file.", positionals: ["PROJECT"], options: [
            .value("format", "mp4|hevc|prores|gif", "Output format (default mp4, H.264)"),
            .value("height", "PIXELS", "Output height, e.g. 1080 (default: source)"),
            .value("fps", "N", "Output frame rate (default: source)"),
            .value("out", "PATH", "Output file (default: the project's exports folder)"),
        ]),
        CommandSpec(name: "enhance", summary: "Clean up the voice (noise removal, leveling, de-essing); saves the settings and renders voice/.",
                    positionals: ["PROJECT"], options: [
            .value("strength", "light|medium|strong|max", "How much noise to remove (default: the project's, medium)"),
            .value("mix", "0-1", "Blend with the original: 0 = original, 1 = fully enhanced (default: the project's, 1)"),
        ], discussion: "Turn it off with `reelbird edit PROJECT --set audio.enhance=false`. The raw microphone is never changed."),
        CommandSpec(name: "captions", summary: "Transcribe on-device and write captions.vtt (updates edit.json).",
                    positionals: ["PROJECT"], options: [
            .value("locale", "ID", "Spoken language, e.g. en-US (default: your system language)"),
            .flag("srt", "Also write captions.srt"),
        ]),
        CommandSpec(name: "suggest", summary: "Suggest a title and chapters with Apple Intelligence (saved to edit.json).",
                    positionals: ["PROJECT"], options: [
            .flag("dry-run", "Print suggestions without saving them"),
            .value("locale", "ID", "Spoken language if a transcript has to be made first"),
        ]),
        CommandSpec(name: "silences", summary: "Find silent stretches; --apply cuts them.", positionals: ["PROJECT"], options: [
            .value("threshold", "DB", "Silence level in dBFS (default -45)"),
            .value("min", "SECONDS", "Shortest silence to report (default 1.2)"),
            .value("padding", "SECONDS", "Air kept next to speech when cutting (default 0.15)"),
            .flag("apply", "Add cuts for the silences to edit.json"),
        ]),
        CommandSpec(name: "share", summary: "Publish the project's link (or print it if already shared).", positionals: ["PROJECT"], options: [
            .flag("polished", "Render the current edit and replace the quick version (same link)"),
        ]),
        CommandSpec(name: "unshare", summary: "Delete the project's shared files and link.", positionals: ["PROJECT"]),
        CommandSpec(name: "config", summary: "Configure sharing: `config share …` or `config show`.", positionals: ["ACTION"]),
        CommandSpec(name: "recover", summary: "Rebuild a project left unfinished by a crash.", positionals: ["PROJECT"]),
        CommandSpec(name: "mcp", summary: "Run a Model Context Protocol server on stdin/stdout.",
                    discussion: "Add to an MCP client as: {\"command\": \"reelbird\", \"args\": [\"mcp\"]}"),
        CommandSpec(name: "help", summary: "Show help for a command.", positionals: ["COMMAND?"]),
        CommandSpec(name: "version", summary: "Print the version."),
    ]

    static let configShareSpec = CommandSpec(name: "config share", summary: "Save the S3-compatible bucket used for share links.", options: [
        .value("endpoint", "URL", "S3 endpoint, e.g. https://<account>.r2.cloudflarestorage.com"),
        .value("bucket", "NAME", "Bucket name"),
        .value("access-key", "ID", "Access key ID"),
        .value("public-base", "URL", "Public URL serving the bucket, e.g. https://pub-xxxx.r2.dev"),
        .value("region", "NAME", "Region (default auto)"),
        .value("prefix", "PREFIX", "Key prefix for shares (default r)"),
        .flag("secret-stdin", "Read the secret access key from stdin (otherwise prompts)"),
        .flag("test", "Test the connection before saving"),
    ], discussion: "The secret is stored in the Keychain and never printed.")
    static let configShowSpec = CommandSpec(name: "config show", summary: "Show the share destination (never the secret).")

    static var overview: String {
        var s = "reelbird \(ReelbirdInfo.version) — record, edit and share screen recordings from the command line.\n\nCommands:\n"
        let width = (commands.map(\.name.count).max() ?? 8) + 3
        for c in commands { s += "  " + c.name.padding(toLength: width, withPad: " ", startingAt: 0) + c.summary + "\n" }
        s += "\nEvery command accepts --json for machine-readable output. Run `reelbird help COMMAND` for details."
        return s
    }

    /// Runs the CLI and returns the exit code.
    static func run(_ argv: [String]) async -> Int32 {
        let json = argv.contains("--json")
        guard let name = argv.first, !name.hasPrefix("-") || ["--help", "-h", "--version"].contains(name) else {
            if argv.isEmpty { Console.out(overview); return ExitCode.ok.rawValue }
            Console.print(CLIError.usage("Expected a command first.", hint: "Run `reelbird help`."), json: json)
            return ExitCode.usage.rawValue
        }
        if name == "--help" || name == "-h" { Console.out(overview); return 0 }
        if name == "--version" || name == "version" {
            Console.print(Report(json: ["version": .string(ReelbirdInfo.version)], text: "reelbird \(ReelbirdInfo.version)"), json: json)
            return 0
        }
        do {
            let report = try await dispatch(name, Array(argv.dropFirst()))
            if let report { Console.print(report, json: json) }
            return ExitCode.ok.rawValue
        } catch {
            let e = CLIError.wrap(error)
            Console.print(e, json: json)
            return e.code.rawValue
        }
    }

    static func dispatch(_ name: String, _ rest: [String]) async throws -> Report? {
        guard var spec = commands.first(where: { $0.name == name }) else {
            let s = ArgumentParser.closest(name, among: commands.map(\.name)).map { " Did you mean '\($0)'?" } ?? ""
            throw CLIError.usage("Unknown command '\(name)'.\(s)", hint: "Run `reelbird help` for the list.")
        }
        var args = rest
        if name == "config" {
            switch rest.first {
            case "share": spec = configShareSpec; args = Array(rest.dropFirst())
            case "show": spec = configShowSpec; args = Array(rest.dropFirst())
            case nil, "--help", "-h": return Report(json: [:], text: spec.help + "\n" + configShareSpec.help + "\n" + configShowSpec.help)
            case let other?: throw CLIError.usage("Unknown config action '\(other)'. Use `config share` or `config show`.")
            }
        }
        let a = try ArgumentParser.parse(args, spec: spec)
        if a.has("help") { return Report(json: ["help": .string(spec.help)], text: spec.help) }
        let syntheticMic = a.value("synthetic-mic").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let ops = Operations(engine: EngineFactory.make(syntheticMicrophone: syntheticMic), locator: ProjectLocator(libraryPath: a.value("library")))
        let project = a.positional(0) ?? ""

        switch spec.name {
        case "help":
            guard let target = a.positional(0) else { return Report(json: [:], text: overview) }
            if target == "config" { return Report(json: [:], text: configShareSpec.help + "\n" + configShowSpec.help) }
            guard let c = commands.first(where: { $0.name == target }) else { throw CLIError.usage("Unknown command '\(target)'.") }
            return Report(json: ["help": .string(c.help)], text: c.help)
        case "sources": return try await ops.sources()
        case "record": return try await Recorder.run(a, ops: ops)
        case "info": return try ops.info(project)
        case "list":
            if let l = try a.int("limit"), l < 0 { throw CLIError.usage("--limit must be 0 or more.") }
            return ops.list(limit: try a.int("limit"))
        case "edit":
            let sets = try a.all("set").map(EditSetter.assignment)
            if a.has("crop-toolbar") && a.has("no-crop") { throw CLIError.usage("Use either --crop-toolbar or --no-crop.") }
            var crop: Operations.CropChange?
            if a.has("crop-toolbar") { crop = .set(try await ops.toolbarCrop(project)) }
            if a.has("no-crop") { crop = .clear }
            return try ops.edit(project, sets: sets, trim: a.value("trim"), cuts: a.all("cut"), clearCuts: a.has("clear-cuts"), crop: crop)
        case "export":
            var req = ExportRequest()
            if let f = a.value("format") {
                guard let fmt = ExportFormat(rawValue: f.lowercased()) else {
                    throw CLIError.usage("Unknown format '\(f)'. Use mp4, hevc, prores or gif.")
                }
                req.format = fmt
            }
            req.height = try a.int("height")
            req.frameRate = try a.int("fps")
            if let h = req.height, !(16...8640).contains(h) { throw CLIError.usage("--height must be between 16 and 8640.") }
            if let f = req.frameRate, !(1...240).contains(f) { throw CLIError.usage("--fps must be between 1 and 240.") }
            req.destination = a.value("out").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            let bar = ProgressLine("Exporting…")
            defer { bar.finish() }
            return try await ops.export(project, request: req, progress: { bar.update($0) })
        case "enhance":
            var strength: EnhanceStrength?
            if let v = a.value("strength") {
                guard let st = EnhanceStrength(rawValue: v.lowercased()) else {
                    throw CLIError.usage("Unknown strength '\(v)'. Use light, medium, strong or max.")
                }
                strength = st
            }
            let mix = try a.double("mix")
            if let mix, !(0...1).contains(mix) { throw CLIError.usage("--mix must be between 0 and 1.") }
            let bar = ProgressLine("Enhancing voice…")
            defer { bar.finish() }
            return try await ops.enhance(project, strength: strength, mix: mix, progress: { bar.update($0) })
        case "captions":
            let bar = ProgressLine("Transcribing…")
            defer { bar.finish() }
            return try await ops.captions(project, locale: a.value("locale"), srt: a.has("srt"), progress: { bar.update($0) })
        case "suggest":
            return try await ops.suggest(project, apply: !a.has("dry-run"), locale: a.value("locale"))
        case "silences":
            let min = try a.double("min") ?? 1.2
            let padding = try a.double("padding") ?? 0.15
            guard min > 0, padding >= 0 else { throw CLIError.usage("--min must be positive and --padding 0 or more.") }
            return try ops.silences(project, thresholdDB: try a.double("threshold") ?? -45, minDuration: min, padding: padding, apply: a.has("apply"))
        case "share":
            let bar = ProgressLine("Uploading…")
            defer { bar.finish() }
            return try await ops.share(project, polished: a.has("polished"), progress: { bar.update($0) })
        case "unshare": return try await ops.unshare(project)
        case "recover": return try await ops.recover(project)
        case "config show": return ops.configShow()
        case "config share": return try await configShare(a, ops: ops)
        case "mcp":
            await MCPServer(ops: ops).run()
            return nil
        default:
            throw CLIError.usage("Unknown command '\(spec.name)'.")
        }
    }

    static func configShare(_ a: ParsedArguments, ops: Operations) async throws -> Report {
        var missing: [String] = []
        for k in ["endpoint", "bucket", "access-key", "public-base"] where a.value(k) == nil { missing.append("--\(k)") }
        guard missing.isEmpty else { throw CLIError.usage("Missing \(missing.joined(separator: ", ")).", hint: "See: reelbird config share --help") }
        let d = ShareDestination(endpoint: a.value("endpoint")!, bucket: a.value("bucket")!, region: a.value("region") ?? "auto",
                                 accessKeyID: a.value("access-key")!, publicBaseURL: a.value("public-base")!, prefix: a.value("prefix") ?? "r")
        let secret: String
        if a.has("secret-stdin") {
            secret = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        } else if Console.stdinIsTerminal {
            guard let p = getpass("Secret access key: ") else { throw CLIError("Couldn't read the secret.") }
            secret = String(cString: p).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            throw CLIError.usage("Pass --secret-stdin to read the secret access key from stdin.")
        }
        return try await ops.configShare(d, secret: secret, test: a.has("test"))
    }
}
