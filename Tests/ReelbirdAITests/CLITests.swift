import Foundation
import ReelbirdCore
import Testing
@testable import ReelbirdAI

// End-to-end tests of the `reelbird` binary (built alongside the tests by `swift test`).
// The CLI is an executable target, so it is exercised as a process: arguments in, exit code + output out.

private enum CLI {
    static var binary: URL? { CLIBinary.url }
}

/// The `reelbird` binary `swift test` built: in `$RB_SCRATCH/debug` when scripts/test.sh runs with a separate
/// build folder (relative paths are from the repo root), next to the test bundle, or in `.build/debug`.
/// Tests that need it fail (never skip) when it is missing: see `cliBinaryIsBuilt`.
enum CLIBinary {
    static var url: URL? {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var candidates: [URL] = []
        if let scratch = ProcessInfo.processInfo.environment["RB_SCRATCH"], !scratch.isEmpty {
            let dir = scratch.hasPrefix("/") ? URL(fileURLWithPath: scratch) : root.appendingPathComponent(scratch)
            candidates.append(dir.appendingPathComponent("debug/reelbird"))
            // The Xcode-style layout some toolchains use for a scratch folder.
            candidates.append(dir.appendingPathComponent("out/Products/Debug/reelbird"))
        }
        if let xctest = Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(".xctest") }) {
            candidates.append(xctest.bundleURL.deletingLastPathComponent().appendingPathComponent("reelbird"))
        }
        candidates.append(root.appendingPathComponent(".build/debug/reelbird"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

private extension CLI {

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

/// Fails loudly when the CLI tests can't find the binary, instead of every one of them being skipped.
@Test func cliBinaryIsBuilt() {
    #expect(CLIBinary.url != nil, "No reelbird binary in $RB_SCRATCH/debug, next to the tests or in .build/debug. Build it with scripts/build.sh.")
}

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

@Test func usageErrorsHaveExitCode64() throws {
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

@Test func captureCommandsReportUnavailable() throws {
    let r = try CLI.run(["record", "--json", "--duration", "2"], library: try tempDir())
    #expect(r.code == 69)
    #expect(r.json?["ok"] as? Bool == false)
}

@Test func recordStopsAfterDurationAndOnCtrlC() throws {
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

@Test func editSetsDottedKeysTrimAndCuts() throws {
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

@Test func editSetsCropByKeyAndFromTheDetectedToolbar() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let bundle = try makeProject(in: dir)

    // Dotted key: a partial crop reaches the far edges.
    let r = try CLI.run(["edit", bundle.url.path, "--set", "crop.y=0.08", "--json"])
    #expect(r.code == 0, "\(r.err)")
    #expect((r.json?["crop"] as? [String: Any])?["height"] as? Double == 0.92)
    #expect(try bundle.readEdit().crop == NormRect(x: 0, y: 0.08, width: 1, height: 0.92))
    let out = try CLI.run(["edit", bundle.url.path, "--set", "crop.y=1.5"])
    #expect(out.code == 65, "out of range is rejected: \(out.err)")
    #expect(try CLI.run(["edit", bundle.url.path, "--set", "crop=null"]).code == 0)
    #expect(try bundle.readEdit().crop == nil)

    // --crop-toolbar applies the detected toolbar (here from the cache, keyed by the screen file).
    try FileManager.default.createDirectory(at: bundle.directory(for: .screen), withIntermediateDirectories: true)
    try Data(repeating: 7, count: 4096).write(to: bundle.resolve("screen/screen.mp4"))
    try bundle.writeCropSuggestion(CropSuggestion(file: "screen/screen.mp4", fileSize: 4096, height: 1080, topPixels: 162, confidence: 0.92))
    let tb = try CLI.run(["edit", bundle.url.path, "--crop-toolbar", "--json"])
    #expect(tb.code == 0, "\(tb.err)")
    let crop = try #require(try bundle.readEdit().crop)
    #expect(abs(crop.y - 0.15) < 1e-9 && abs(crop.height - 0.85) < 1e-9 && crop.x == 0 && crop.width == 1)
    let info = try CLI.run(["info", bundle.url.path, "--json"])
    #expect(((info.json?["edit"] as? [String: Any])?["crop"] as? [String: Any])?["y"] as? Double == 0.15)
    #expect(try CLI.run(["edit", bundle.url.path, "--no-crop"]).code == 0)
    #expect(try bundle.readEdit().crop == nil)

    // No confident toolbar: a clear data error, edit unchanged.
    try bundle.writeCropSuggestion(CropSuggestion(file: "screen/screen.mp4", fileSize: 4096, height: 1080, topPixels: 0, confidence: 0))
    let none = try CLI.run(["edit", bundle.url.path, "--crop-toolbar"])
    #expect(none.code == 65 && none.err.contains("No browser toolbar"), "\(none.err)")
    #expect(try bundle.readEdit().crop == nil)
}

@Test func infoAndListFindProjects() throws {
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

@Test func silencesCommandFindsAndCutsGaps() async throws {
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

@Test func enhanceRendersTheVoiceStemAndInfoReportsIt() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let audio = dir.appendingPathComponent("tone.m4a")
    try await TestAudio.writeAAC([.init(duration: 1, amplitude: 0.3), .init(duration: 1, amplitude: 0), .init(duration: 1, amplitude: 0.3)], to: audio)
    let bundle = try makeProject(in: dir, microphone: audio)

    let before = try CLI.run(["info", bundle.url.path])
    #expect(before.out.contains("Enhance    medium, not rendered yet"), "\(before.out)")

    let r = try CLI.run(["enhance", bundle.url.path, "--strength", "strong", "--mix", "0.8", "--json"])
    #expect(r.code == 0, "\(r.err)")
    #expect(r.json?["strength"] as? String == "strong")
    #expect(r.json?["mix"] as? Double == 0.8)
    let file = try #require(r.json?["file"] as? String)
    #expect(FileManager.default.fileExists(atPath: file))
    let edit = try bundle.readEdit()
    #expect(edit.audio.enhance && edit.audio.enhanceStrength == .strong && edit.audio.enhanceMix == 0.8)

    let info = try CLI.run(["info", bundle.url.path, "--json"])
    #expect((info.json?["voiceStem"] as? [String: Any])?["status"] as? String == "ready", "\(info.out)")
    #expect(try CLI.run(["info", bundle.url.path]).out.contains("Enhance    strong, mix 80%, ready"))

    // Settings changed without rendering: out of date. Turned off: off.
    #expect(try CLI.run(["edit", bundle.url.path, "--set", "audio.enhanceStrength=light"]).code == 0)
    #expect(try CLI.run(["info", bundle.url.path]).out.contains("out of date"))
    let off = try CLI.run(["edit", bundle.url.path, "--set", "audio.enhance=false"])
    #expect(off.code == 0, "\(off.err)")
    #expect(try bundle.readEdit().audio.enhance == false)
    #expect(try CLI.run(["info", bundle.url.path]).out.contains("Enhance    off"))

    let bad = try CLI.run(["enhance", bundle.url.path, "--strength", "huge"])
    #expect(bad.code == 64)
}

@Test(.enabled(if: Transcriber.isAvailable)) func captionsCommandWritesVTT() async throws {
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

@Test func mcpLegacyHandshakeAndTools() throws {
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

@Test func mcpModernPerRequestMetadata() throws {
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

@Test func mcpRecordingSessions() throws {
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

// MARK: - export --out never replaces a file by accident

@Test func exportKeepsAnExistingOutFileUnlessForced() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let bundle = try makeProject(in: dir)
    let out = dir.appendingPathComponent("final.mp4")
    try Data("keep me".utf8).write(to: out)

    let refused = try CLI.run(["export", bundle.url.path, "--out", out.path], library: dir, demo: true)
    #expect(refused.code == 64, "\(refused.err)")
    #expect(refused.err.contains("already exists") && refused.err.contains("--force"))
    #expect(try String(contentsOf: out, encoding: .utf8) == "keep me")

    // --force gets past the check (the demo engine can't render, so it stops there instead).
    let forced = try CLI.run(["export", bundle.url.path, "--out", out.path, "--force"], library: dir, demo: true)
    #expect(!forced.err.contains("already exists"), "\(forced.err)")
    #expect(try CLI.run(["export", bundle.url.path, "--force"], library: dir, demo: true).err.contains("--force only applies with --out"))
    #expect(try CLI.run(["export", "--help"]).out.contains("--force"))

    let p = bundle.url.path, o = out.path
    let responses = try mcp([
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"export","arguments":{"project":"\#(p)","out":"\#(o)"}}}"#,
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"export","arguments":{"project":"\#(p)","out":"\#(o)","overwrite":true}}}"#,
        #"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#,
    ], library: dir, demo: true)
    let first = try #require(toolResult(responses["2"]))
    #expect(first["isError"] as? Bool == true)
    let text = ((first["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    #expect(text.contains("already exists"), "\(text)")
    let second = ((toolResult(responses["3"])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    #expect(!second.contains("already exists"), "\(second)")
    #expect(try String(contentsOf: out, encoding: .utf8) == "keep me")
    let tools = try #require(toolResult(responses["4"])?["tools"] as? [[String: Any]])
    for name in ["export", "stop_recording", "unshare"] {
        let t = tools.first { $0["name"] as? String == name }
        #expect((t?["annotations"] as? [String: Any])?["destructiveHint"] as? Bool == true, "\(name)")
    }
}

@Test func cameraPlacementFromTheCommandLineAndMCP() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let bundle = try makeProject(in: dir, name: "Camera Take")
    var m = try bundle.readManifest()
    m.tracks.append(TrackInfo(kind: .camera, directory: "camera", file: "camera/camera.mp4", codec: "h264",
                              pixelSize: PixelSize(width: 1280, height: 720), duration: 30))
    try bundle.writeManifest(m)
    // The recorder's log: the bubble starts in the bottom-right corner and is dragged to the top left at 12 s.
    let d = 200.0, inset = 0.025 * 1080
    let log = try EventLogWriter(url: bundle.eventsURL)
    log.append(.camera(0, frame: NormRect(x: (1920 - inset - d) / 1920, y: (1080 - inset - d) / 1080, width: d / 1920, height: d / 1080)))
    log.append(.camera(12, frame: NormRect(x: 0, y: 0, width: d / 1920, height: d / 1080)))
    log.close()

    let info = try CLI.run(["info", bundle.url.path])
    #expect(info.code == 0, "\(info.err)")
    // The first edit takes the live bubble's size (CameraPlacement.apply, WYSIWYG): 200 pt on a 1080 pt screen is
    // 18.5% of it, times the padded screen card (0.84 of the canvas at the default 8% padding) = 16%.
    #expect(info.out.contains("Camera     circle 16%, bottom right, 1 move (0:12)"), "\(info.out)")
    let infoJSON = try #require(try CLI.run(["info", bundle.url.path, "--json"]).json)
    let camera = try #require((infoJSON["edit"] as? [String: Any])?["camera"] as? [String: Any])
    #expect(camera["x"] as? Double == 1 && camera["y"] as? Double == 1)
    #expect((camera["moves"] as? [[String: Any]])?.first?["t"] as? Double == 12)

    // A free place: x and y; the move stays.
    let place = try CLI.run(["edit", bundle.url.path, "--set", "camera.x=0.5", "--set", "camera.y=0", "--set", "camera.shape=portrait"])
    #expect(place.code == 0, "\(place.err)")
    var edit = try bundle.readEdit()
    #expect(edit.camera.position == NormPoint(x: 0.5, y: 0) && edit.camera.moves.count == 1 && edit.camera.shape == .portrait)

    let badShape = try CLI.run(["edit", bundle.url.path, "--set", "camera.shape=hexagon"])
    #expect(badShape.code == 65)
    #expect(badShape.err.contains("circle, roundedSquare, portrait"), "\(badShape.err)")

    // Keep it in one place.
    #expect(try CLI.run(["edit", bundle.url.path, "--clear-camera-moves"]).code == 0)
    edit = try bundle.readEdit()
    #expect(edit.camera.moves.isEmpty && edit.camera.position == NormPoint(x: 0.5, y: 0))

    // A corner is a preset: it pins the bubble there.
    #expect(try CLI.run(["edit", bundle.url.path, "--set", "camera.corner=bottomLeft"]).code == 0)
    edit = try bundle.readEdit()
    #expect(edit.camera.x == nil && edit.camera.y == nil && edit.camera.position == NormPoint(x: 0, y: 1))
    #expect(try CLI.run(["info", bundle.url.path]).out.contains("Camera     portrait 16%, bottom left"))   // size kept from the live bubble

    // MCP: set a place and moves, then clear the moves (separate sessions: tool calls may run concurrently).
    let p = bundle.url.path
    let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#
    let set = try mcp([initialize,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"set_edit","arguments":{"project":"\#(p)","set":{"camera.x":0.25,"camera.y":0.75,"camera.moves":[{"t":3,"x":1,"y":0}]}}}}"#,
    ], library: dir)
    #expect(toolResult(set["2"])?["isError"] as? Bool == false)
    edit = try bundle.readEdit()
    #expect(edit.camera.position == NormPoint(x: 0.25, y: 0.75) && edit.camera.moves == [CameraLayout.Move(t: 3, x: 1, y: 0)])
    let clear = try mcp([initialize,
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"set_edit","arguments":{"project":"\#(p)","clear_camera_moves":true}}}"#,
    ], library: dir)
    #expect(toolResult(clear["3"])?["isError"] as? Bool == false)
    edit = try bundle.readEdit()
    #expect(edit.camera.position == NormPoint(x: 0.25, y: 0.75) && edit.camera.moves.isEmpty)
}

@Test func speedFromTheCommandLineAndMCP() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let bundle = try makeProject(in: dir, name: "Typing Take")
    // Ten seconds of typing from 5 s, a click at 20 s.
    let log = try EventLogWriter(url: bundle.eventsURL)
    log.append(.move(0, NormPoint(x: 0.5, y: 0.5)))
    for k in 0...50 { log.append(InputEvent(t: 5 + Double(k) * 0.2, type: .key, chars: "a")) }
    log.append(.down(20, NormPoint(x: 0.5, y: 0.5)))
    log.close()

    // Speed ranges by hand: 2× and 0.5×; 1 removes speed; out-of-range rates are usage errors.
    let r = try CLI.run(["edit", bundle.url.path, "--speed", "0:01-0:03@2", "--speed", "25-end@0.5x", "--json"])
    #expect(r.code == 0, "\(r.err)")
    let rJSON = try #require(r.json)
    #expect(rJSON["outputDuration"] as? Double == 34)
    var edit = try bundle.readEdit()
    #expect(edit.speed.segments.map(\.rate) == [2, 0.5])
    #expect(edit.speed.segments.last?.range == TimeRange(start: 25, end: 30))
    #expect(try CLI.run(["edit", bundle.url.path, "--speed", "1-3@9"]).code == 64)
    #expect(try CLI.run(["edit", bundle.url.path, "--speed", "1-3"]).code == 64)
    #expect(try CLI.run(["edit", bundle.url.path, "--speed", "2-3@1"]).code == 0)
    edit = try bundle.readEdit()
    #expect(edit.speed.segments.first?.range == TimeRange(start: 1, end: 2))
    let info = try CLI.run(["info", bundle.url.path])
    #expect(info.out.contains("Speed      2 parts: 2× 0:01–0:02, 0.5× 0:25–0:30"), "\(info.out)")
    let infoJSON = try #require(try CLI.run(["info", bundle.url.path, "--json"]).json)
    let speedJSON = try #require((infoJSON["edit"] as? [String: Any])?["speed"] as? [String: Any])
    #expect((speedJSON["segments"] as? [[String: Any]])?.count == 2)
    #expect(try CLI.run(["edit", bundle.url.path, "--clear-speed"]).code == 0)
    #expect(try bundle.readEdit().speed.segments.isEmpty)

    // Suggestions from the key presses: typing 5–15 s at 4× (no microphone, so no talking); idle (no input) before
    // the typing, between it and the click at 20 s, and after the click.
    let dry = try CLI.run(["speedup", bundle.url.path, "--json"])
    #expect(dry.code == 0, "\(dry.err)")
    let dryJSON = try #require(dry.json)
    let found = try #require(dryJSON["suggestions"] as? [[String: Any]])
    #expect(found.map { $0["kind"] as? String } == ["idle", "typing", "idle", "idle"], "\(found)")
    #expect(found[1]["rate"] as? Double == 4 && found[0]["rate"] as? Double == 8)
    #expect(try bundle.readEdit().speed.segments.isEmpty, "dry run leaves the edit alone")
    let applied = try CLI.run(["speedup", bundle.url.path, "--apply"])
    #expect(applied.code == 0 && applied.out.contains("Speed up 1 typing stretch and 3 idle stretches"), "\(applied.out)")
    edit = try bundle.readEdit()
    #expect(edit.speed.segments.map(\.source) == [.idle, .typing, .idle, .idle])
    #expect(try CLI.run(["info", bundle.url.path]).out.contains("4× typing 0:05–0:15"))

    // MCP: suggest (nothing left), set a speed range, keep fast sound.
    let p = bundle.url.path
    let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#
    let s = try mcp([initialize,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"suggest_speedups","arguments":{"project":"\#(p)"}}}"#,
    ], library: dir)
    let structured = toolResult(s["2"])?["structuredContent"] as? [String: Any]
    #expect(toolResult(s["2"])?["isError"] as? Bool == false)
    #expect((structured?["suggestions"] as? [Any])?.isEmpty == true, "\(String(describing: s["2"]))")
    let set = try mcp([initialize,
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"set_edit","arguments":{"project":"\#(p)","clear_speed":true,"speed":["0:02-0:04@1.5"],"set":{"speed.keepFastAudio":true}}}}"#,
    ], library: dir)
    #expect(toolResult(set["3"])?["isError"] as? Bool == false, "\(String(describing: set["3"]))")
    edit = try bundle.readEdit()
    #expect(edit.speed.segments.count == 1 && edit.speed.segments[0].rate == 1.5 && edit.speed.keepFastAudio)
}

@Test func zoomsTurnedOffAndInstantFromTheCommandLineAndMCP() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let bundle = try makeProject(in: dir, name: "Zoom Take")
    var edit = EditDocument()
    edit.zoom.mode = .auto
    edit.zoom.regions = [ZoomRegion(id: "auto-1", range: TimeRange(start: 2, end: 4), scale: 1.8, source: .auto),
                         ZoomRegion(id: "mine", range: TimeRange(start: 8, end: 10), scale: 2)]
    try bundle.writeEdit(edit)

    // By id: turned off (and kept as yours, so replanning never brings it back) and instant.
    let r = try CLI.run(["edit", bundle.url.path, "--set", "zoom.regions.auto-1.enabled=false", "--set", "zoom.regions.mine.instant=true"])
    #expect(r.code == 0, "\(r.err)")
    edit = try bundle.readEdit()
    #expect(edit.zoom.regions.first { $0.id == "auto-1" }.map { !$0.enabled && $0.source == .user } == true)
    #expect(edit.zoom.regions.first { $0.id == "mine" }?.instant == true)
    let json = try #require(try CLI.run(["edit", bundle.url.path, "--json"]).json)
    let regions = try #require((json["zoom"] as? [String: Any])?["regions"] as? [[String: Any]])
    #expect(regions.contains { $0["id"] as? String == "auto-1" && $0["enabled"] as? Bool == false })

    // Every zoom at once, and a clear error for an unknown id.
    #expect(try CLI.run(["edit", bundle.url.path, "--set", "zoom.regions.*.enabled=true"]).code == 0)
    #expect(try bundle.readEdit().zoom.regions.allSatisfy { $0.enabled })
    let bad = try CLI.run(["edit", bundle.url.path, "--set", "zoom.regions.nope.enabled=false"])
    #expect(bad.code == 65 && bad.err.contains("no item in zoom.regions has the id 'nope'") && bad.err.contains("auto-1"), "\(bad.err)")
    // Index paths still work.
    #expect(try CLI.run(["edit", bundle.url.path, "--set", "zoom.regions.1.scale=2.5"]).code == 0)
    #expect(try bundle.readEdit().zoom.regions[1].scale == 2.5)

    // MCP set_edit takes the same keys.
    let p = bundle.url.path
    let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#
    let set = try mcp([initialize,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"set_edit","arguments":{"project":"\#(p)","set":{"zoom.regions.*.instant":true,"zoom.regions.mine.enabled":false}}}}"#,
    ], library: dir)
    #expect(toolResult(set["2"])?["isError"] as? Bool == false)
    edit = try bundle.readEdit()
    #expect(edit.zoom.regions.allSatisfy { $0.instant } && edit.zoom.regions.first { $0.id == "mine" }?.enabled == false)
}

@Test func cameraLayoutsAndZoomedSizeFromTheCommandLineAndMCP() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let bundle = try makeProject(in: dir, name: "Layout Take")
    let p = bundle.url.path
    // No camera: no layouts.
    let none = try CLI.run(["edit", p, "--layout", "split@1-3"])
    #expect(none.code == 65 && none.err.contains("no camera"), "\(none.err)")
    var m = try bundle.readManifest()
    m.tracks.append(TrackInfo(kind: .camera, directory: "camera", file: "camera/camera.mp4", codec: "h264",
                              pixelSize: PixelSize(width: 1280, height: 720), duration: 30))
    try bundle.writeManifest(m)

    let set = try CLI.run(["edit", p, "--layout", "split@0:05-0:12", "--layout", "camera@8-10", "--layout", "screen@20-end",
                           "--set", "camera.sizeWhileZoomed=0.55", "--set", "camera.smartFraming=false"])
    #expect(set.code == 0, "\(set.err)")
    var edit = try bundle.readEdit()
    #expect(edit.layouts.map(\.kind) == [.split, .fullCamera, .split, .screenOnly], "camera@8-10 splits the split")
    #expect(edit.layouts.map(\.range) == [TimeRange(start: 5, end: 8), TimeRange(start: 8, end: 10), TimeRange(start: 10, end: 12),
                                          TimeRange(start: 20, end: 30)])
    #expect(edit.camera.sizeWhileZoomed == 0.55 && !edit.camera.smartFraming && edit.camera.shrinkWhenZoomed)

    let info = try CLI.run(["info", p])
    #expect(info.out.contains("during zooms 55% size"), "\(info.out)")
    #expect(info.out.contains("Layouts    split 0:05–0:08, camera 0:08–0:10, split 0:10–0:12, screen 0:20–0:30"), "\(info.out)")
    let json = try #require(try CLI.run(["info", p, "--json"]).json)
    let e = try #require(json["edit"] as? [String: Any])
    let cam = try #require(e["camera"] as? [String: Any])
    #expect(cam["sizeWhileZoomed"] as? Double == 0.55 && cam["smartFraming"] as? Bool == false && cam["shrinkWhenZoomed"] as? Bool == true)
    let layouts = try #require(e["layouts"] as? [[String: Any]])
    #expect(layouts.first?["kind"] as? String == "split" && layouts.first?["start"] as? Double == 5)

    // Bad input: an unknown kind, a size out of range, a layout past the end.
    let bad = try CLI.run(["edit", p, "--layout", "pip@1-2"])
    #expect(bad.code == 64 && bad.err.contains("camera, split, screen or bubble"), "\(bad.err)")
    let tooSmall = try CLI.run(["edit", p, "--set", "camera.sizeWhileZoomed=0.1"])
    #expect(tooSmall.code == 65, "\(tooSmall.err)")
    #expect(try CLI.run(["edit", p, "--layout", "camera@40-45"]).code == 64)

    // Bubble clears a range; --clear-layouts clears all.
    #expect(try CLI.run(["edit", p, "--layout", "bubble@0-15"]).code == 0)
    #expect(try bundle.readEdit().layouts.map(\.kind) == [.screenOnly])

    // MCP: layouts and the zoomed size in one call.
    let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#
    let r = try mcp([initialize,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"set_edit","arguments":{"project":"\#(p)","clear_layouts":true,"layouts":["camera@1-4"],"set":{"camera.shrinkWhenZoomed":false}}}}"#,
    ], library: dir)
    #expect(toolResult(r["2"])?["isError"] as? Bool == false)
    edit = try bundle.readEdit()
    #expect(edit.layouts.map(\.kind) == [.fullCamera] && edit.layouts[0].range == TimeRange(start: 1, end: 4))
    #expect(!edit.camera.shrinkWhenZoomed)
}
