import Foundation
import ReelbirdCore
import Testing
@testable import ReelbirdAI

// End-to-end tests of the `reelbird` binary (built alongside the tests by `swift test`).
// The CLI is an executable target, so it is exercised as a process: arguments in, exit code + output out.

private enum CLI {
    static var binary: URL? {
        var candidates: [URL] = []
        if let xctest = Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(".xctest") }) {
            candidates.append(xctest.bundleURL.deletingLastPathComponent().appendingPathComponent("reelbird"))
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(root.appendingPathComponent(".build/debug/reelbird"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    struct Result {
        var code: Int32
        var out: String
        var err: String
        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] }
    }

    static func run(_ args: [String], stdin: String? = nil, library: URL? = nil, demo: Bool = false,
                    interruptAfter: Double? = nil) throws -> Result {
        guard let binary else { throw CocoaError(.fileNoSuchFile) }
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        if let library { env["REELBIRD_LIBRARY"] = library.path }
        if demo { env["REELBIRD_DEMO_ENGINE"] = "1" }
        p.environment = env
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = inPipe
        try p.run()
        if let stdin { inPipe.fileHandleForWriting.write(Data(stdin.utf8)) }
        if let interruptAfter {
            Thread.sleep(forTimeInterval: interruptAfter)
            p.interrupt()
        }
        try inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(code: p.terminationStatus, out: String(decoding: out, as: UTF8.self), err: String(decoding: err, as: UTF8.self))
    }
}

private let binaryAvailable = CLI.binary != nil

/// A project bundle with a 30 s synthetic screen track and, optionally, a microphone file.
private func makeProject(in dir: URL, name: String = "Demo", microphone: URL? = nil, micStart: Double = 0.5) throws -> ProjectBundle {
    let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("\(name).reelbird"))
    var tracks = [TrackInfo(kind: .screen, directory: "screen", file: "screen/screen.mp4", codec: "hvc1",
                            pixelSize: PixelSize(width: 1920, height: 1080), duration: 30)]
    if let microphone {
        let micDir = bundle.directory(for: .microphone)
        try FileManager.default.createDirectory(at: micDir, withIntermediateDirectories: true)
        let dst = micDir.appendingPathComponent("microphone.\(microphone.pathExtension)")
        try FileManager.default.copyItem(at: microphone, to: dst)
        tracks.append(TrackInfo(kind: .microphone, directory: "microphone", file: "microphone/\(dst.lastPathComponent)",
                                codec: "aac", sampleRate: 44_100, channels: 1, duration: 10, startTime: micStart))
    }
    let manifest = ProjectManifest(title: name, appVersion: "test", status: .complete,
                                   capture: CaptureInfo(source: .synthetic(name: "test"), pixelSize: PixelSize(width: 1920, height: 1080),
                                                        scale: 2, frameRate: 60),
                                   clock: ClockInfo(originHostTime: 0), tracks: tracks, duration: 30)
    try bundle.writeManifest(manifest)
    return bundle
}

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("reelbird-cli-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

// MARK: - Argument parsing

@Test(.enabled(if: binaryAvailable)) func usageErrorsHaveExitCode64() throws {
    let help = try CLI.run([])
    #expect(help.code == 0 && help.out.contains("Commands:"))

    let unknownOption = try CLI.run(["edit", "x", "--bogus"])
    #expect(unknownOption.code == 64)
    #expect(unknownOption.err.contains("Unknown option '--bogus'"))

    let typo = try CLI.run(["lsit"])
    #expect(typo.code == 64 && typo.err.contains("Did you mean 'list'"))

    let missing = try CLI.run(["info"])
    #expect(missing.code == 64 && missing.err.contains("Missing PROJECT"))

    let missingValue = try CLI.run(["export", "x", "--height"])
    #expect(missingValue.code == 64 && missingValue.err.contains("--height needs a value"))

    let badNumber = try CLI.run(["record", "--fps", "fast"])
    #expect(badNumber.code == 64 && badNumber.err.contains("--fps expects a whole number"))

    let twoSources = try CLI.run(["record", "--display", "1", "--window", "2"])
    #expect(twoSources.code == 64)

    let commandHelp = try CLI.run(["edit", "--help"])
    #expect(commandHelp.code == 0 && commandHelp.out.contains("--set KEY=VALUE"))

    let jsonError = try CLI.run(["info", "nope-not-a-project", "--json"], library: try tempDir())
    #expect(jsonError.code == 66)
    #expect((jsonError.json?["error"] as? [String: Any])?["message"] as? String == "Project not found: nope-not-a-project")
}

@Test(.enabled(if: binaryAvailable)) func captureCommandsReportUnavailable() throws {
    let r = try CLI.run(["record", "--json", "--duration", "2"], library: try tempDir())
    #expect(r.code == 69)
    #expect(r.json?["ok"] as? Bool == false)
}

@Test(.enabled(if: binaryAvailable)) func recordStopsAfterDurationAndOnCtrlC() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let timed = try CLI.run(["record", "--duration", "0.6", "--json"], library: dir, demo: true)
    #expect(timed.code == 0, "\(timed.err)")
    let path = try #require(timed.json?["bundle"] as? String)
    let m = try ProjectBundle(url: URL(fileURLWithPath: path)).readManifest()
    #expect(m.status == .complete && m.duration >= 0.5)

    let out = dir.appendingPathComponent("interrupted").path
    let interrupted = try CLI.run(["record", "--out", out, "--mic", "none"], library: dir, demo: true, interruptAfter: 0.8)
    #expect(interrupted.code == 0, "\(interrupted.err)")
    #expect(interrupted.out.trimmingCharacters(in: .whitespacesAndNewlines) == out + ".reelbird")
    #expect(interrupted.err.contains("Stopping"))
    #expect(try ProjectBundle(url: URL(fileURLWithPath: out + ".reelbird")).readManifest().status == .complete)

    let sources = try CLI.run(["sources", "--json"], demo: true)
    #expect(sources.code == 0 && (sources.json?["displays"] as? [Any])?.count == 1)
}

// MARK: - edit / info / list

@Test(.enabled(if: binaryAvailable)) func editSetsDottedKeysTrimAndCuts() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let bundle = try makeProject(in: dir)

    let r = try CLI.run(["edit", bundle.url.path, "--set", "zoom.intensity=0.7", "--set", "background.kind=solid",
                         "--set", "background.colors=#112233,#445566", "--set", "title=2024 review",
                         "--set", "cursor.showKeystrokes=true", "--trim", "1.2-30", "--cut", "5-7", "--cut", "6.5-8", "--json"])
    #expect(r.code == 0, "\(r.err)")
    let json = try #require(r.json)
    #expect((json["zoom"] as? [String: Any])?["intensity"] as? Double == 0.7)
    #expect(json["outputDuration"] as? Double == 25.8)

    let edit = try bundle.readEdit()
    #expect(edit.zoom.intensity == 0.7)
    #expect(edit.background.kind == .solid)
    #expect(edit.background.colors.map(\.hex) == ["#112233", "#445566"])
    #expect(edit.title == "2024 review")
    #expect(edit.cursor.showKeystrokes)
    #expect(edit.trim == TimeRange(start: 1.2, end: 30))
    #expect(edit.cuts == [TimeRange(start: 5, end: 8)])   // overlapping cuts merge

    // Invalid enum value: data error listing the allowed values.
    let badEnum = try CLI.run(["edit", bundle.url.path, "--set", "zoom.mode=sideways"])
    #expect(badEnum.code == 65)
    #expect(badEnum.err.contains("auto, manual, off"), "\(badEnum.err)")

    // Typo in a key: rejected with a suggestion, file unchanged.
    let typo = try CLI.run(["edit", bundle.url.path, "--set", "zoom.intensty=1"])
    #expect(typo.code == 65)
    #expect(typo.err.contains("Did you mean 'zoom.intensity'"), "\(typo.err)")
    #expect(try bundle.readEdit().zoom.intensity == 0.7)

    // Wrong type.
    let wrongType = try CLI.run(["edit", bundle.url.path, "--set", "zoom.intensity=lots"])
    #expect(wrongType.code == 65)

    // Clearing trim and cuts.
    let clear = try CLI.run(["edit", bundle.url.path, "--trim", "none", "--clear-cuts"])
    #expect(clear.code == 0)
    #expect(try bundle.readEdit().trim == nil && bundle.readEdit().cuts.isEmpty)

    // Bad range.
    let badRange = try CLI.run(["edit", bundle.url.path, "--cut", "9-3"])
    #expect(badRange.code == 64)

    // Audio: auto level and boost.
    #expect(try bundle.readEdit().audio.autoLevel)
    let audio = try CLI.run(["edit", bundle.url.path, "--set", "audio.autoLevel=false", "--set", "audio.microphoneGainDB=4.5"])
    #expect(audio.code == 0, "\(audio.err)")
    #expect(try !bundle.readEdit().audio.autoLevel && bundle.readEdit().audio.microphoneGainDB == 4.5)
}

@Test(.enabled(if: binaryAvailable)) func infoAndListFindProjects() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = try makeProject(in: dir, name: "Alpha Take")
    _ = try makeProject(in: dir, name: "Beta Take")

    let info = try CLI.run(["info", "alpha", "--json"], library: dir)   // unique name prefix
    #expect(info.code == 0, "\(info.err)")
    #expect(info.json?["id"] as? String == (try a.readManifest().id))
    #expect(info.json?["duration"] as? Double == 30)

    let human = try CLI.run(["info", a.url.path])
    #expect(human.code == 0 && human.out.contains("Synthetic (test), 1920×1080 @ 60 fps"))

    // The cached voice measurement shows up once analysis.json exists.
    try a.writeAnalysis(AudioAnalysis(microphone: TrackLoudness(file: "microphone/microphone.m4a", fileSize: 1, integratedLUFS: -27.04,
                                                                peakDBFS: -8.2, duration: 30)))
    let voice = try CLI.run(["info", a.url.path])
    #expect(voice.out.contains("Voice      -27.0 LUFS, peak -8.2 dBFS, auto level +11.0 dB"), "\(voice.out)")
    let voiceJSON = try CLI.run(["info", a.url.path, "--json"])
    #expect((voiceJSON.json?["voiceLoudness"] as? [String: Any])?["autoLevelGainDB"] as? Double == 11.04)

    let ambiguous = try CLI.run(["info", "take"], library: dir)
    #expect(ambiguous.code != 0)

    let list = try CLI.run(["list", "--json"], library: dir)
    #expect(list.code == 0)
    #expect((list.json?["projects"] as? [[String: Any]])?.count == 2)
}

// MARK: - AI commands on real audio

@Test(.enabled(if: binaryAvailable)) func silencesCommandFindsAndCutsGaps() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let audio = dir.appendingPathComponent("tone.m4a")
    try await TestAudio.writeAAC([.init(duration: 1, amplitude: 0.3), .init(duration: 2, amplitude: 0), .init(duration: 1, amplitude: 0.3)], to: audio)
    let bundle = try makeProject(in: dir, microphone: audio, micStart: 0.5)

    let r = try CLI.run(["silences", bundle.url.path, "--apply", "--json"])
    #expect(r.code == 0, "\(r.err)")
    let silences = try #require(r.json?["silences"] as? [[String: Double]])
    #expect(silences.count == 1)
    #expect(abs((silences.first?["start"] ?? 0) - 1.5) < 0.1)   // shifted by the track's startTime
    let cuts = try bundle.readEdit().cuts
    #expect(cuts.count == 1 && abs(cuts[0].start - 1.65) < 0.1)
}

@Test(.enabled(if: binaryAvailable && Transcriber.isAvailable)) func captionsCommandWritesVTT() async throws {
    guard await Transcriber.availability(for: Locale(identifier: "en-US")).canTranscribe else {
        print("SKIP captions CLI test: no en-US speech model")
        return
    }
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    guard let speech = TestAudio.say("Welcome to the captions test. This sentence should become a caption.",
                                     to: dir.appendingPathComponent("speech.m4a"), extraArgs: ["--file-format=m4af", "--data-format=aac"]) else {
        print("SKIP: say unavailable"); return
    }
    let bundle = try makeProject(in: dir, microphone: speech, micStart: 2.0)
    let r = try CLI.run(["captions", bundle.url.path, "--locale", "en-US", "--srt", "--json"])
    #expect(r.code == 0, "\(r.err)")
    let vtt = try String(contentsOf: bundle.captionsURL, encoding: .utf8)
    #expect(vtt.hasPrefix("WEBVTT\n\n00:00:02"), "\(vtt)")   // on the recording timeline
    #expect(vtt.lowercased().contains("caption"))
    #expect(try bundle.readEdit().captions.file == "captions.vtt")
    #expect(FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("transcript.json").path))
    #expect(FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("captions.srt").path))
}

// MARK: - MCP

private func mcp(_ messages: [String], library: URL? = nil, demo: Bool = false) throws -> [String: [String: Any]] {
    let r = try CLI.run(["mcp"], stdin: messages.joined(separator: "\n") + "\n", library: library, demo: demo)
    var byID: [String: [String: Any]] = [:]
    for line in r.out.split(separator: "\n") {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            Issue.record("stdout carried a non-JSON line: \(line)")
            continue
        }
        let id = obj["id"].flatMap { $0 is NSNull ? nil : "\($0)" } ?? "null"
        byID[id] = obj
    }
    return byID
}

private func toolResult(_ response: [String: Any]?) -> [String: Any]? { response?["result"] as? [String: Any] }
private func errorCode(_ response: [String: Any]?) -> Int? { (response?["error"] as? [String: Any])?["code"] as? Int }

@Test(.enabled(if: binaryAvailable)) func mcpLegacyHandshakeAndTools() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let bundle = try makeProject(in: dir, name: "Agent Take")
    let p = bundle.url.path
    let responses = try mcp([
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"project_info","arguments":{"project":"\#(p)"}}}"#,
        #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"set_edit","arguments":{"project":"\#(p)","set":{"zoom.intensity":0.9,"background.kind":"solid"},"cuts":["1-2"]}}}"#,
        #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}"#,
        #"{"jsonrpc":"2.0","id":6,"method":"resources/list"}"#,
        #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"start_recording","arguments":{"duration":1}}}"#,
        #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"project_info","arguments":{}}}"#,
        #"{"jsonrpc":"2.0","id":9,"method":"ping"}"#,
        #"{not json"#,
    ], library: dir)

    let initResult = try #require(toolResult(responses["1"]))
    #expect(initResult["protocolVersion"] as? String == "2025-06-18")
    #expect((initResult["serverInfo"] as? [String: Any])?["name"] as? String == "reelbird")
    #expect(initResult["resultType"] == nil)   // legacy results carry no resultType

    let tools = try #require(toolResult(responses["2"])?["tools"] as? [[String: Any]])
    let names = tools.compactMap { $0["name"] as? String }
    for required in ["list_sources", "start_recording", "stop_recording", "list_projects", "project_info", "set_edit",
                     "export", "generate_captions", "share", "unshare"] {
        #expect(names.contains(required), "missing tool \(required)")
    }
    for t in tools {
        let schema = t["inputSchema"] as? [String: Any]
        #expect(schema?["type"] as? String == "object", "\(t["name"] ?? "?") schema")
        if let req = schema?["required"] as? [String], let props = schema?["properties"] as? [String: Any] {
            #expect(req.allSatisfy { props[$0] != nil })
        }
    }

    let info = try #require(toolResult(responses["3"]))
    #expect(info["isError"] as? Bool == false)
    #expect((info["structuredContent"] as? [String: Any])?["id"] as? String == (try bundle.readManifest().id))

    #expect(toolResult(responses["4"])?["isError"] as? Bool == false)
    let edit = try bundle.readEdit()
    #expect(edit.zoom.intensity == 0.9 && edit.background.kind == .solid && edit.cuts == [TimeRange(start: 1, end: 2)])

    #expect(errorCode(responses["5"]) == -32602)
    #expect(errorCode(responses["6"]) == -32601)
    #expect(toolResult(responses["7"])?["isError"] as? Bool == true)   // capture not wired in: a tool error, not a crash
    #expect(toolResult(responses["8"])?["isError"] as? Bool == true)   // missing argument is a tool error
    #expect(toolResult(responses["9"]) != nil)
    #expect(errorCode(responses["null"]) == -32700)
}

@Test(.enabled(if: binaryAvailable)) func mcpModernPerRequestMetadata() throws {
    let meta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/clientInfo":{"name":"t","version":"1"}}"#
    let responses = try mcp([
        #"{"jsonrpc":"2.0","id":"d","method":"server/discover","params":{\#(meta)}}"#,
        #"{"jsonrpc":"2.0","id":"l","method":"tools/list","params":{\#(meta)}}"#,
        #"{"jsonrpc":"2.0","id":"c","method":"tools/call","params":{"name":"list_projects","arguments":{"limit":5},\#(meta)}}"#,
        #"{"jsonrpc":"2.0","id":"v","method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"1900-01-01","io.modelcontextprotocol/clientCapabilities":{}}}}"#,
        #"{"jsonrpc":"2.0","id":"m","method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#,
        #"{"jsonrpc":"2.0","id":"n","method":"tools/list"}"#,
    ], library: try tempDir())

    let discover = try #require(toolResult(responses["d"]))
    #expect(discover["resultType"] as? String == "complete")
    #expect((discover["supportedVersions"] as? [String])?.first == "2026-07-28")
    #expect(((discover["_meta"] as? [String: Any])?["io.modelcontextprotocol/serverInfo"] as? [String: Any])?["name"] as? String == "reelbird")

    let list = try #require(toolResult(responses["l"]))
    #expect(list["resultType"] as? String == "complete")
    #expect((list["tools"] as? [Any])?.isEmpty == false)

    let call = try #require(toolResult(responses["c"]))
    #expect(call["resultType"] as? String == "complete" && call["isError"] as? Bool == false)

    #expect(errorCode(responses["v"]) == -32022)
    let data = (responses["v"]?["error"] as? [String: Any])?["data"] as? [String: Any]
    #expect(data?["requested"] as? String == "1900-01-01")
    #expect((data?["supported"] as? [String])?.contains("2026-07-28") == true)

    #expect(errorCode(responses["m"]) == -32602)   // missing clientCapabilities
    #expect(errorCode(responses["n"]) == -32602)   // no _meta and no initialize
}

@Test(.enabled(if: binaryAvailable)) func mcpRecordingSessions() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let meta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#
    // Two recordings: one stopped explicitly, one left running when stdin closes (must still be saved).
    let r = try CLI.run(["mcp"], stdin: [
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"start_recording","arguments":{"microphone":"none"},\#(meta)}}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"start_recording","arguments":{"display":"1"},\#(meta)}}"#,
    ].joined(separator: "\n") + "\n", library: dir, demo: true)
    let lines = r.out.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    let sessions = lines.compactMap { (($0["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["session_id"] as? String }
    #expect(sessions.count == 2, "\(r.out) \(r.err)")
    #expect(r.err.contains("saving recording"))
    let saved = ProjectLibrary(root: dir).list()
    #expect(saved.count == 2)
    #expect(saved.allSatisfy { (try? $0.readManifest().status) == .complete })

    // start → stop in one connection; stop waits for the start response because the client sends it after.
    let dir2 = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir2) }
    let start = try mcp([#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"start_recording","arguments":{"duration":0.3},\#(meta)}}"#],
                        library: dir2, demo: true)
    let sid = try #require((toolResult(start["1"])?["structuredContent"] as? [String: Any])?["session_id"] as? String)
    #expect(sid.hasPrefix("rec_"))
    let stopUnknown = try mcp([#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"stop_recording","arguments":{"session_id":"rec_nope"},\#(meta)}}"#],
                              library: dir2, demo: true)
    #expect(toolResult(stopUnknown["2"])?["isError"] as? Bool == true)
}
