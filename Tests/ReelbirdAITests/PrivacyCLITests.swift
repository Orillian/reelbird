import Foundation
import ReelbirdCore
import Testing
@testable import ReelbirdAI

// `reelbird blur`, `redact` and `annotate`, and the matching MCP tools, run as a process like CLITests.

private enum CLI {
    static var binary: URL? { CLIBinary.url }

    struct Result {
        var code: Int32
        var out: String
        var err: String
        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] }
    }

    static func run(_ args: [String], stdin: String? = nil, library: URL? = nil) throws -> Result {
        guard let binary else { throw CocoaError(.fileNoSuchFile) }
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        if let library { env["REELBIRD_LIBRARY"] = library.path }
        p.environment = env
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = inPipe
        try p.run()
        if let stdin { inPipe.fileHandleForWriting.write(Data(stdin.utf8)) }
        try inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(code: p.terminationStatus, out: String(decoding: out, as: UTF8.self), err: String(decoding: err, as: UTF8.self))
    }
}

private let binaryAvailable = CLI.binary != nil

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("reelbird-privacy-cli-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// A project whose screen track is `video` (or a placeholder) of the fixture's size.
private func makeProject(in dir: URL, name: String, video: URL? = nil, seconds: Double = 20) throws -> ProjectBundle {
    let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("\(name).reelbird"))
    let screenDir = bundle.directory(for: .screen)
    try FileManager.default.createDirectory(at: screenDir, withIntermediateDirectories: true)
    if let video { try FileManager.default.copyItem(at: video, to: screenDir.appendingPathComponent("screen.mp4")) }
    let size = PixelSize(width: SecretFixture.width, height: SecretFixture.height)
    let manifest = ProjectManifest(title: name, appVersion: "test", status: .complete,
                                   capture: CaptureInfo(source: .synthetic(name: "test"), pixelSize: size, scale: 2, frameRate: 30),
                                   clock: ClockInfo(originHostTime: 0),
                                   tracks: [TrackInfo(kind: .screen, directory: "screen", file: "screen/screen.mp4", codec: "avc1",
                                                      pixelSize: size, duration: seconds)],
                                   duration: seconds)
    try bundle.writeManifest(manifest)
    return bundle
}

@Test(.enabled(if: binaryAvailable)) func blurCommandAddsAnOverlay() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let bundle = try makeProject(in: dir, name: "Blur")
    let p = bundle.url.path

    let r = try CLI.run(["blur", p, "--rect", "0.1,0.2,0.3,0.05", "--from", "0:05", "--to", "0:12", "--json"])
    #expect(r.code == 0, "\(r.err)")
    let added = try #require(r.json?["added"] as? [String: Any])
    #expect(added["kind"] as? String == "blur" && added["start"] as? Double == 5 && added["end"] as? Double == 12)
    // Pixels of the screen video work too, and --pixelate.
    let px = try CLI.run(["blur", p, "--rect", "192,240,576,60", "--pixelate", "--strength", "0.8"])
    #expect(px.code == 0 && px.out.contains("Added pixelate"), "\(px.out) \(px.err)")
    let edit = try bundle.readEdit()
    #expect(edit.annotations.count == 2)
    let a = edit.annotations[0], b = edit.annotations[1]
    #expect(a.kind == .blur && a.blurStyle == .blur && a.rect == NormRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05))
    #expect(b.blurStyle == .pixelate && b.blurStrength == 0.8 && abs(b.rect.x - 0.1) < 1e-9 && abs(b.rect.width - 0.3) < 1e-9)
    #expect(b.range == TimeRange(start: 0, end: 20))

    // Mistakes are usage errors (exit 64) and change nothing.
    for args in [["blur", p], ["blur", p, "--rect", "1,2"], ["blur", p, "--rect", "0.1,0.1,0.2,0.2", "--from", "30"],
                 ["blur", p, "--rect", "0.1,0.1,0.2,0.2", "--strength", "3"], ["redact", p], ["annotate", p, "--add", "star", "--rect", "0,0,0.1,0.1"]] {
        let bad = try CLI.run(args)
        #expect(bad.code == 64, "\(args) → \(bad.code) \(bad.err)")
    }
    #expect(try bundle.readEdit().annotations.count == 2)
}

@Test(.enabled(if: binaryAvailable)) func annotateAddsListsAndRemoves() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let bundle = try makeProject(in: dir, name: "Notes")
    let p = bundle.url.path
    #expect(try CLI.run(["annotate", p]).out.contains("No overlays."))
    #expect(try CLI.run(["annotate", p, "--add", "arrow", "--arrow", "0.8,0.8,0.5,0.4", "--from", "1", "--to", "4", "--color", "#2F7DE1"]).code == 0)
    #expect(try CLI.run(["annotate", p, "--add", "text", "--text", "Click Save", "--rect", "0.5,0.3,0.1,0.05", "--size", "0.04"]).code == 0)
    #expect(try CLI.run(["annotate", p, "--add", "box", "--rect", "0.2,0.2,0.2,0.2"]).code == 0)
    #expect(try CLI.run(["annotate", p, "--add", "highlight", "--rect", "0.2,0.2,0.2,0.2"]).code == 0)
    let list = try CLI.run(["annotate", p, "--json"])
    let items = try #require(list.json?["annotations"] as? [[String: Any]])
    #expect(items.count == 4)
    let arrow = try #require(items.first { $0["kind"] as? String == "arrow" })
    #expect((arrow["head"] as? [String: Any])?["x"] as? Double == 0.5 && arrow["color"] as? String == "#2F7DE1")
    let edit = try bundle.readEdit()
    let text = try #require(edit.annotations.first { $0.kind == .text })
    #expect(text.text == "Click Save" && text.fontSize == 0.04 && text.rect.height > 0.04 && text.rect.width > 0.05)
    // An arrow without ends, and text without text, are usage errors.
    #expect(try CLI.run(["annotate", p, "--add", "arrow"]).code == 64)
    #expect(try CLI.run(["annotate", p, "--add", "text", "--rect", "0,0,0.1,0.1"]).code == 64)
    // Remove one by ID, then clear.
    let id = try #require(arrow["id"] as? String)
    let rm = try CLI.run(["annotate", p, "--remove", id, "--json"])
    #expect(rm.json?["removed"] as? Int == 1 && rm.json?["count"] as? Int == 3)
    #expect(try CLI.run(["annotate", p, "--remove", "nope"]).code != 0)
    #expect(try CLI.run(["annotate", p, "--clear"]).code == 0)
    #expect(try bundle.readEdit().annotations.isEmpty)
}

@Test(.enabled(if: binaryAvailable)) func redactFindsListsAndKeeps() async throws {
    let fx = try await SecretFixture.shared(seconds: 20)
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let bundle = try makeProject(in: dir, name: "Settings", video: fx.url, seconds: 20)
    let p = bundle.url.path

    let dry = try CLI.run(["redact", p, "--auto", "--dry-run", "--json"])
    #expect(dry.code == 0, "\(dry.err)")
    let found = try #require(dry.json?["detections"] as? [[String: Any]])
    #expect(Set(found.compactMap { $0["kind"] as? String }) == ["email", "apiKey", "card", "phone"], "\(found)")
    let untouched = try bundle.readEdit().annotations.isEmpty
    #expect(dry.json?["applied"] as? Bool == false && untouched)
    // Never the values themselves: only masked previews.
    for secret in ["jane.doe@example.com", "sk-proj-Ab3dEf9GhJk2LmN0pQr5StU8vWx1", "4242 4242 4242 4242", "4242424242424242", "415-555-0132"] {
        #expect(!dry.out.contains(secret) && !dry.err.contains(secret), "printed \(secret)")
    }
    let text = try CLI.run(["redact", p, "--auto"])
    #expect(text.out.contains("Nothing changed") && text.out.contains("•••• 4242"))

    // Keep one by its ID (stable from scan to scan), then the rest.
    let card = try #require(found.first { $0["kind"] as? String == "card" }?["id"] as? String)
    let one = try CLI.run(["redact", p, "--auto", "--keep", card, "--json"])
    #expect(one.json?["added"] as? Int == 1)
    let blur = try #require(try bundle.readEdit().annotations.first)
    #expect(blur.id == card && blur.kind == .blur && blur.detected == "card")
    let all = try CLI.run(["redact", p, "--auto", "--keep-all", "--pixelate", "--json"])
    #expect(all.json?["added"] as? Int == found.count - 1)
    #expect(try bundle.readEdit().annotations.count == found.count)
    #expect(try CLI.run(["redact", p, "--auto", "--keep", "s00000000"]).code != 0)
    #expect(try CLI.run(["redact", p, "--auto", "--keep-all", "--dry-run"]).code == 64)
    // Only the kinds asked for.
    let cards = try CLI.run(["redact", p, "--auto", "--kinds", "card", "--json"])
    #expect((cards.json?["detections"] as? [[String: Any]])?.count == 1)
}

private func mcp(_ messages: [String], library: URL) throws -> [String: [String: Any]] {
    let r = try CLI.run(["mcp"], stdin: messages.joined(separator: "\n") + "\n", library: library)
    var byID: [String: [String: Any]] = [:]
    for line in r.out.split(separator: "\n") {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
        byID[obj["id"].map { "\($0)" } ?? "null"] = obj
    }
    return byID
}

@Test(.enabled(if: binaryAvailable)) func mcpRedactsBeforeSharing() async throws {
    let fx = try await SecretFixture.shared(seconds: 20)
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let bundle = try makeProject(in: dir, name: "Agent", video: fx.url, seconds: 20)
    let p = bundle.url.path
    let r = try mcp([
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"blur_region","arguments":{"project":"\#(p)","rect":{"x":0.1,"y":0.1,"width":0.2,"height":0.05},"from":"0:02","to":6,"style":"pixelate"}}}"#,
        #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"add_annotation","arguments":{"project":"\#(p)","kind":"arrow","tail":{"x":0.9,"y":0.9},"head":{"x":0.5,"y":0.5}}}}"#,
        #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"add_annotation","arguments":{"project":"\#(p)","kind":"text","text":"Hello","rect":{"x":0.1,"y":0.8,"width":0.1,"height":0.05}}}}"#,
        #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"blur_region","arguments":{"project":"\#(p)"}}}"#,
    ], library: dir)
    let names = ((r["2"]?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
    for t in ["blur_region", "find_sensitive_info", "list_annotations", "add_annotation", "remove_annotations"] {
        #expect(names.contains(t), "missing \(t)")
    }
    for id in ["3", "4", "5"] {
        #expect((r[id]?["result"] as? [String: Any])?["isError"] as? Bool == false, "call \(id): \(r[id] ?? [:])")
    }
    #expect((r["6"]?["result"] as? [String: Any])?["isError"] as? Bool == true)
    let edit = try bundle.readEdit()
    // Tool calls run concurrently; none of their edits is lost.
    #expect(edit.annotations.count == 3 && Set(edit.annotations.map(\.kind)) == [.blur, .arrow, .text])
    let pix = edit.annotations.first { $0.kind == .blur }
    #expect(pix?.blurStyle == .pixelate && pix?.range == TimeRange(start: 2, end: 6))

    // Find, then keep all; then list and remove.
    let r2 = try mcp([
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"find_sensitive_info","arguments":{"project":"\#(p)","kinds":["email","card"]}}}"#,
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"find_sensitive_info","arguments":{"project":"\#(p)","keep_all":true}}}"#,
    ], library: dir)
    let dry = (r2["2"]?["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
    #expect((dry?["detections"] as? [[String: Any]])?.count == 2 && dry?["applied"] as? Bool == false)
    let kept = (r2["3"]?["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
    #expect(kept?["added"] as? Int == 4, "\(kept ?? [:])")
    let r4 = try mcp([
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
        #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_annotations","arguments":{"project":"\#(p)"}}}"#,
    ], library: dir)
    let listed = ((r4["4"]?["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["annotations"] as? [[String: Any]]
    #expect(listed?.count == 7)
    let r3 = try mcp([
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"remove_annotations","arguments":{"project":"\#(p)","all":true}}}"#,
    ], library: dir)
    #expect((((r3["2"]?["result"] as? [String: Any])?["structuredContent"]) as? [String: Any])?["removed"] as? Int == 7)
}
