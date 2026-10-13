import Foundation
import ReelbirdCore

/// A JSON-RPC error returned to the MCP client.
struct RPCError: Error, Sendable {
    var code: Int
    var message: String
    var data: JSONValue?

    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
    /// MCP 2026-07-28 `UnsupportedProtocolVersionError`.
    static let unsupportedProtocolVersion = -32022
}

/// Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0).
///
/// Dual-era: serves the stateless 2026-07-28 revision (protocol version, client info and capabilities in every
/// request's `_meta`, `server/discover`, `resultType` on results) and the earlier `initialize` handshake
/// revisions (2024-11-05 … 2025-11-25). Requests are handled concurrently, so `stop_recording` works while an
/// export runs. Only JSON-RPC goes to stdout; diagnostics go to stderr.
final class MCPServer: Sendable {
    static let modernVersions = ["2026-07-28"]
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static var supportedVersions: [String] { modernVersions + legacyVersions }

    static let serverInfo: JSONValue = ["name": "reelbird", "title": "Reelbird", "version": .string(ReelbirdInfo.version)]
    static let instructions = """
    Reelbird records the Mac screen into .reelbird projects and edits them non-destructively. \
    Typical flow: list_sources → start_recording (returns session_id) → stop_recording → set_edit / generate_captions / suggest_story → export or share. \
    A project argument is a .reelbird path, a name from list_projects, or "latest".
    """

    let ops: Operations
    private let output = MCPOutput()
    private let state = MCPState()

    init(ops: Operations) { self.ops = ops }

    /// Serves until stdin closes, then stops any recordings still running (saving them) and returns.
    func run() async {
        await withTaskGroup(of: Void.self) { group in
            do {
                for try await line in FileHandle.standardInput.bytes.lines {
                    // Tool calls can take minutes (export, transcription), so they run concurrently;
                    // everything else is handled in order, which keeps the handshake ahead of later requests.
                    if line.contains("\"tools/call\"") {
                        group.addTask { await self.handle(line: line) }
                    } else {
                        await handle(line: line)
                    }
                }
            } catch {
                Console.err("reelbird mcp: stdin error: \(error.localizedDescription)")
            }
            await group.waitForAll()
        }
        for (id, session) in await state.takeAllSessions() {
            Console.err("reelbird mcp: client disconnected; saving recording \(id)…")
            _ = try? await session.control.stop()
        }
    }

    /// Handles one line and writes the response (if any). Exposed for tests.
    func handle(line: String) async {
        if let response = await response(to: line) { await output.send(response) }
    }

    /// The response for one incoming line, or nil for notifications.
    func response(to line: String) async -> JSONValue? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let message = try? JSONValue.parse(text) else {
            return errorResponse(id: .null, RPCError(code: RPCError.parseError, message: "Parse error: not valid JSON."))
        }
        guard case .object(let o) = message else {
            return errorResponse(id: .null, RPCError(code: RPCError.invalidRequest, message: "Invalid request: expected a JSON-RPC object (batches are not supported)."))
        }
        let id = o["id"]
        guard o["jsonrpc"] == "2.0", case .string(let method)? = o["method"] else {
            if id != nil, o["result"] != nil || o["error"] != nil { return nil }   // a response to us; we send no requests
            return errorResponse(id: id ?? .null, RPCError(code: RPCError.invalidRequest, message: "Invalid request: needs \"jsonrpc\": \"2.0\" and a method."))
        }
        guard let id else { return nil }   // notification (initialized, cancelled, …)
        switch id {
        case .string, .int: break
        default: return errorResponse(id: .null, RPCError(code: RPCError.invalidRequest, message: "Invalid request: id must be a string or integer."))
        }
        let params: [String: JSONValue]
        switch o["params"] {
        case nil, .null?: params = [:]
        case .object(let p)?: params = p
        default: return errorResponse(id: id, RPCError(code: RPCError.invalidParams, message: "params must be an object."))
        }
        do {
            let result = try await respond(method: method, params: params)
            return ["jsonrpc": "2.0", "id": id, "result": result]
        } catch let e as RPCError {
            return errorResponse(id: id, e)
        } catch {
            return errorResponse(id: id, RPCError(code: RPCError.internalError, message: error.localizedDescription))
        }
    }

    private func errorResponse(id: JSONValue, _ e: RPCError) -> JSONValue {
        var err: [String: JSONValue] = ["code": .int(e.code), "message": .string(e.message)]
        if let d = e.data { err["data"] = d }
        return ["jsonrpc": "2.0", "id": id, "error": .object(err)]
    }

    private func respond(method: String, params: [String: JSONValue]) async throws -> JSONValue {
        let meta = params["_meta"]?.objectValue
        var modern = false
        if let v = meta?["io.modelcontextprotocol/protocolVersion"] {
            guard case .string(let version) = v else {
                throw RPCError(code: RPCError.invalidParams, message: "_meta io.modelcontextprotocol/protocolVersion must be a string.")
            }
            guard Self.modernVersions.contains(version) else {
                throw RPCError(code: RPCError.unsupportedProtocolVersion, message: "Unsupported protocol version",
                               data: ["supported": .array(Self.supportedVersions.map(JSONValue.string)), "requested": .string(version)])
            }
            guard meta?["io.modelcontextprotocol/clientCapabilities"]?.objectValue != nil else {
                throw RPCError(code: RPCError.invalidParams, message: "Missing _meta io.modelcontextprotocol/clientCapabilities.")
            }
            modern = true
        } else if method == "initialize" {
            return try await initialize(params)
        } else if !["ping", "server/discover"].contains(method), await state.legacyVersion == nil {
            throw RPCError(code: RPCError.invalidParams,
                           message: "Missing _meta io.modelcontextprotocol/protocolVersion. Send it on every request (protocol 2026-07-28), or call initialize first (2025-11-25 and earlier).",
                           data: ["supported": .array(Self.supportedVersions.map(JSONValue.string))])
        }

        var result: [String: JSONValue]
        switch method {
        case "server/discover":
            result = [
                "supportedVersions": .array(Self.supportedVersions.map(JSONValue.string)),
                "capabilities": ["tools": [:]],
                "instructions": .string(Self.instructions),
            ]
            modern = true
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": MCPTools.definitions]
        case "tools/call":
            result = try await callTool(params, progressToken: meta?["progressToken"])
        default:
            throw RPCError(code: RPCError.methodNotFound, message: "Method not found: \(method)")
        }
        if modern {
            result["resultType"] = "complete"
            result["_meta"] = ["io.modelcontextprotocol/serverInfo": Self.serverInfo]
        }
        return .object(result)
    }

    private func initialize(_ params: [String: JSONValue]) async throws -> JSONValue {
        let requested = params["protocolVersion"]?.stringValue
        let version = requested.flatMap { Self.legacyVersions.contains($0) ? $0 : nil } ?? Self.legacyVersions[0]
        await state.setLegacyVersion(version)
        return [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": Self.serverInfo,
            "instructions": .string(Self.instructions),
        ]
    }

    // MARK: - Tools

    private func callTool(_ params: [String: JSONValue], progressToken: JSONValue?) async throws -> [String: JSONValue] {
        guard case .string(let name)? = params["name"] else {
            throw RPCError(code: RPCError.invalidParams, message: "tools/call needs a tool name.")
        }
        guard MCPTools.names.contains(name) else {
            throw RPCError(code: RPCError.invalidParams, message: "Unknown tool: \(name)")
        }
        let args: [String: JSONValue]
        switch params["arguments"] {
        case nil, .null?: args = [:]
        case .object(let a)?: args = a
        default: throw RPCError(code: RPCError.invalidParams, message: "Tool arguments must be an object.")
        }
        let progress = makeProgress(progressToken)
        do {
            let report = try await runTool(name, ToolArguments(args), progress: progress)
            return ["content": [["type": "text", "text": .string(report.text)]], "structuredContent": report.json, "isError": false]
        } catch {
            let e = CLIError.wrap(error)
            let text = e.hint.map { "\(e.message)\n\($0)" } ?? e.message
            return ["content": [["type": "text", "text": .string(text)]], "isError": true]
        }
    }

    private func makeProgress(_ token: JSONValue?) -> @Sendable (Double) -> Void {
        guard let token, token.stringValue != nil || token.intValue != nil else { return { _ in } }
        let throttle = PercentThrottle()
        let output = self.output
        return { fraction in
            guard let p = throttle.next(fraction) else { return }
            let note: JSONValue = ["jsonrpc": "2.0", "method": "notifications/progress",
                                   "params": ["progressToken": token, "progress": .int(p), "total": 100]]
            Task { await output.send(note) }
        }
    }

    private func runTool(_ name: String, _ a: ToolArguments, progress: @escaping @Sendable (Double) -> Void) async throws -> Report {
        switch name {
        case "list_sources":
            return try await ops.sources()
        case "start_recording":
            return try await startRecording(a)
        case "stop_recording":
            return try await stopRecording(a)
        case "list_projects":
            return ops.list(limit: try a.int("limit"))
        case "project_info":
            return try ops.info(try a.requiredString("project"))
        case "set_edit":
            var sets: [EditSetter.Assignment] = []
            if let s = a.raw["set"] {
                guard case .object(let o) = s else { throw CLIError.usage("'set' must be an object of dotted keys to values.") }
                sets = o.keys.sorted().map { EditSetter.Assignment(path: $0, value: .json(o[$0]!)) }
            }
            var cuts: [String] = []
            if let c = a.raw["cuts"] {
                guard case .array(let items) = c, items.allSatisfy({ $0.stringValue != nil }) else {
                    throw CLIError.usage("'cuts' must be a list of \"START-END\" strings.")
                }
                cuts = items.compactMap(\.stringValue)
            }
            let project = try a.requiredString("project")
            let crop: Operations.CropChange? = try a.bool("crop_toolbar") == true ? .set(try await ops.toolbarCrop(project)) : nil
            return try ops.edit(project, sets: sets, trim: try a.string("trim"), cuts: cuts,
                                clearCuts: try a.bool("clear_cuts") ?? false, crop: crop)
        case "export":
            var req = ExportRequest()
            if let f = try a.string("format") {
                guard let fmt = ExportFormat(rawValue: f) else { throw CLIError.usage("format must be one of mp4, hevc, prores, gif.") }
                req.format = fmt
            }
            req.height = try a.int("height")
            req.frameRate = try a.int("fps")
            if let h = req.height, !(16...8640).contains(h) { throw CLIError.usage("height must be between 16 and 8640.") }
            if let f = req.frameRate, !(1...240).contains(f) { throw CLIError.usage("fps must be between 1 and 240.") }
            req.destination = try a.string("out").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            req.overwrite = try a.bool("overwrite") ?? false
            return try await ops.export(try a.requiredString("project"), request: req, progress: progress)
        case "generate_captions":
            return try await ops.captions(try a.requiredString("project"), locale: try a.string("locale"), srt: try a.bool("srt") ?? false, progress: progress)
        case "suggest_story":
            return try await ops.suggest(try a.requiredString("project"), apply: try a.bool("apply") ?? true, locale: try a.string("locale"))
        case "enhance_voice":
            var strength: EnhanceStrength?
            if let v = try a.string("strength") {
                guard let st = EnhanceStrength(rawValue: v.lowercased()) else { throw CLIError.usage("strength must be light, medium, strong or max.") }
                strength = st
            }
            let mix = try a.double("mix")
            if let mix, !(0...1).contains(mix) { throw CLIError.usage("mix must be between 0 and 1.") }
            return try await ops.enhance(try a.requiredString("project"), strength: strength, mix: mix, progress: progress)
        case "detect_silences":
            return try ops.silences(try a.requiredString("project"), thresholdDB: try a.double("threshold_db") ?? -45,
                                    minDuration: try a.double("min_duration") ?? 1.2, padding: 0.15, apply: try a.bool("apply") ?? false)
        case "share":
            return try await ops.share(try a.requiredString("project"), polished: try a.bool("polished") ?? false, progress: progress)
        case "unshare":
            return try await ops.unshare(try a.requiredString("project"))
        default:
            throw CLIError("Unknown tool \(name).")
        }
    }

    private func startRecording(_ a: ToolArguments) async throws -> Report {
        var p = RecordParams()
        let picked = ["display", "window", "area"].filter { a.raw[$0] != nil }
        guard picked.count <= 1 else { throw CLIError.usage("Give only one of display, window or area.") }
        if let d = try a.string("display") { p.selector = .display(d) }
        if let w = try a.string("window") { p.selector = .window(w) }
        if let area = a.raw["area"] {
            if case .string(let s) = area { p.selector = try Recorder.parseArea(s) } else if case .object(let o) = area,
                let x = o["x"]?.doubleValue, let y = o["y"]?.doubleValue, let w = o["width"]?.doubleValue, let h = o["height"]?.doubleValue,
                w > 0, h > 0 {
                p.selector = .area(x: x, y: y, width: w, height: h, display: nil)
            } else {
                throw CLIError.usage("area must be {x, y, width, height} in points.")
            }
        }
        p.duration = try a.double("duration")
        p.frameRate = try a.int("fps") ?? 60
        if let q = try a.string("quality") {
            guard let quality = RecordingOptions.Quality(rawValue: q) else { throw CLIError.usage("quality must be high, max or compact.") }
            p.quality = quality
        }
        p.microphone = try a.string("microphone") ?? "default"
        p.systemAudio = try a.bool("system_audio") ?? true
        p.camera = try a.string("camera")
        p.keystrokes = try a.bool("keystrokes") ?? false
        p.share = try a.bool("share") ?? false
        p.out = try a.string("out")

        let (options, url) = try await ops.makeOptions(p)
        let control = try await ops.engine.startRecording(options: options, bundleURL: url)
        let id = "rec_" + ShortID.make(length: 12)
        await state.add(id, MCPState.Session(control: control, bundleURL: url))
        if let d = p.duration {
            let state = self.state, ops = self.ops
            Task {
                try? await Task.sleep(nanoseconds: UInt64(d * 1_000_000_000))
                guard let session = await state.take(id) else { return }
                let result: Result<Report, CLIError>
                do {
                    let bundle = try await session.control.stop()
                    result = .success(ops.recordingFinished(bundle, issues: await session.control.trackIssues))
                } catch { result = .failure(CLIError.wrap(error)) }
                await state.finish(id, result)
            }
        }
        var text = "Recording started (session \(id)) into \(url.path)."
        text += p.duration.map { " It stops by itself after \(Format.seconds($0)) s; call stop_recording to get the result." } ?? " Call stop_recording with this session_id to finish."
        return Report(json: ["session_id": .string(id), "bundle": .string(url.path), "duration": JSONValue(p.duration)], text: text)
    }

    private func stopRecording(_ a: ToolArguments) async throws -> Report {
        let id = try a.requiredString("session_id")
        if let finished = await state.takeFinished(id) { return try finished.get() }
        guard let session = await state.take(id) else {
            throw CLIError("No recording with session_id \(id). It may have been stopped already; use list_projects to find it.")
        }
        if try a.bool("discard") ?? false {
            await session.control.discard()
            return Report(json: ["session_id": .string(id), "discarded": true], text: "Recording \(id) discarded.")
        }
        let bundle = try await session.control.stop()
        return ops.recordingFinished(bundle, issues: await session.control.trackIssues)
    }
}

/// Serialises writes to stdout so concurrent responses never interleave.
private actor MCPOutput {
    func send(_ message: JSONValue) {
        FileHandle.standardOutput.write(Data((message.serialized() + "\n").utf8))
    }
}

/// Connection-scoped state: the legacy handshake version and running recordings (keyed by explicit session IDs).
actor MCPState {
    struct Session: Sendable {
        var control: any RecordingControl
        var bundleURL: URL
    }

    private(set) var legacyVersion: String?
    private var sessions: [String: Session] = [:]
    private var finished: [String: Result<Report, CLIError>] = [:]

    func setLegacyVersion(_ v: String) { legacyVersion = v }
    func add(_ id: String, _ s: Session) { sessions[id] = s }
    func take(_ id: String) -> Session? { sessions.removeValue(forKey: id) }
    func finish(_ id: String, _ r: Result<Report, CLIError>) { finished[id] = r }
    func takeFinished(_ id: String) -> Result<Report, CLIError>? { finished.removeValue(forKey: id) }
    func takeAllSessions() -> [(String, Session)] {
        defer { sessions = [:] }
        return sessions.map { ($0.key, $0.value) }
    }
}

/// Emits whole percentages, each at most once.
private final class PercentThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1
    func next(_ fraction: Double) -> Int? {
        let p = Int((min(1, max(0, fraction)) * 100).rounded(.down))
        lock.lock(); defer { lock.unlock() }
        guard p > last else { return nil }
        last = p
        return p
    }
}

/// Typed access to tool arguments; type errors become tool errors the model can correct.
struct ToolArguments: Sendable {
    let raw: [String: JSONValue]
    init(_ raw: [String: JSONValue]) { self.raw = raw }

    private func typeError(_ key: String, _ expected: String) -> CLIError {
        CLIError.usage("Argument '\(key)' must be \(expected).")
    }
    func string(_ key: String) throws -> String? {
        guard let v = raw[key], !v.isNull else { return nil }
        guard let s = v.stringValue else { throw typeError(key, "a string") }
        return s
    }
    func requiredString(_ key: String) throws -> String {
        guard let s = try string(key), !s.isEmpty else { throw CLIError.usage("Missing required argument '\(key)'.") }
        return s
    }
    func bool(_ key: String) throws -> Bool? {
        guard let v = raw[key], !v.isNull else { return nil }
        guard let b = v.boolValue else { throw typeError(key, "true or false") }
        return b
    }
    func int(_ key: String) throws -> Int? {
        guard let v = raw[key], !v.isNull else { return nil }
        guard let i = v.intValue else { throw typeError(key, "a whole number") }
        return i
    }
    func double(_ key: String) throws -> Double? {
        guard let v = raw[key], !v.isNull else { return nil }
        guard let d = v.doubleValue else { throw typeError(key, "a number") }
        return d
    }
}
