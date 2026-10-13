import Foundation
import ReelbirdCore
import Testing

// `reelbird markers`, markers in `info`, and the MCP marker tools, run against the built `reelbird` binary.

private var reelbirdBinary: URL? { CLIBinary.url }

/// Runs `reelbird args…` and returns (exit code, stdout).
private func reelbird(_ args: [String], library: URL) throws -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = try #require(reelbirdBinary)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["REELBIRD_LIBRARY"] = library.path
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func json(_ s: String) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] }

private func scratch() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("reelbird-markers-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// A 30 s project with three markers logged while recording and a pause cut 8–12 s.
private func projectWithMarkers(in dir: URL) throws -> ProjectBundle {
    let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("Marked.reelbird"))
    let manifest = ProjectManifest(title: "Marked", appVersion: "test", status: .complete,
                                   capture: CaptureInfo(source: .synthetic(name: "test"), pixelSize: PixelSize(width: 1920, height: 1080),
                                                        scale: 2, frameRate: 60),
                                   clock: ClockInfo(originHostTime: 0),
                                   tracks: [TrackInfo(kind: .screen, directory: "screen", file: "screen/screen.mp4", codec: "hvc1",
                                                      pixelSize: PixelSize(width: 1920, height: 1080), duration: 30)],
                                   pauses: [TimeRange(start: 8, end: 12)], duration: 30)
    try bundle.writeManifest(manifest)
    let log = try EventLogWriter(url: bundle.eventsURL)
    log.append(.move(0.5, NormPoint(x: 0.5, y: 0.5)))
    log.append(.marker(5))
    log.append(.marker(10, label: "Paused here"))
    log.append(.marker(20, label: "Checkout"))
    log.close()
    return bundle
}

@Test func markersCommandListsAndMakesChapters() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let bundle = try projectWithMarkers(in: dir)

    let list = try reelbird(["markers", bundle.url.path, "--json"], library: dir)
    #expect(list.code == 0, "\(list.out)")
    let markers = try #require(json(list.out)?["markers"] as? [[String: Any]])
    #expect(markers.compactMap { $0["title"] as? String } == ["Marker 1", "Paused here", "Checkout"])
    #expect(markers.compactMap { $0["t"] as? Double } == [5, 10, 20])
    #expect(markers[1]["outputTime"] is NSNull, "a marker in the pause has no place in the edited video")
    #expect(markers[2]["outputTime"] as? Double == 16)
    #expect(!FileManager.default.fileExists(atPath: bundle.editURL.path), "listing writes nothing")

    let text = try reelbird(["markers", "latest"], library: dir)
    #expect(text.out.contains("Checkout") && text.out.contains("cut"))

    let info = try reelbird(["info", bundle.url.path, "--json"], library: dir)
    #expect((json(info.out)?["markers"] as? [Any])?.count == 3)
    #expect(try reelbird(["info", bundle.url.path], library: dir).out.contains("Markers"))

    let made = try reelbird(["markers", bundle.url.path, "--as-chapters", "--json"], library: dir)
    #expect(made.code == 0)
    let chapters = try bundle.readEdit().chapters
    #expect(chapters == [Chapter(time: 0, title: "Start"), Chapter(time: 5, title: "Marker 1"),
                         Chapter(time: 12, title: "Paused here"), Chapter(time: 20, title: "Checkout")])
    #expect((json(made.out)?["chapters"] as? [Any])?.count == 4)
}

@Test func markersAsChaptersNeedsMarkers() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let bundle = try projectWithMarkers(in: dir)
    try FileManager.default.removeItem(at: bundle.eventsURL)
    let r = try reelbird(["markers", bundle.url.path, "--as-chapters"], library: dir)
    #expect(r.code == 65)
    #expect(try reelbird(["markers", bundle.url.path], library: dir).code == 0)
}

/// MCP: add_marker during a running recording (demo engine), then list_markers on the saved project.
@Test func mcpAddAndListMarkers() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let meta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#

    let p = Process()
    p.executableURL = try #require(reelbirdBinary)
    p.arguments = ["mcp"]
    var env = ProcessInfo.processInfo.environment
    env["REELBIRD_LIBRARY"] = dir.path
    env["REELBIRD_DEMO_ENGINE"] = "1"
    p.environment = env
    let input = Pipe(), output = Pipe()
    p.standardInput = input
    p.standardOutput = output
    p.standardError = Pipe()
    try p.run()
    let reader = output.fileHandleForReading
    var buffer = Data()
    /// Sends one request and waits for the response with that id.
    func call(_ id: Int, _ name: String, _ args: String) throws -> [String: Any] {
        input.fileHandleForWriting.write(Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(name)","arguments":\#(args),\#(meta)}}"#.utf8 + [0x0A]))
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<nl]
                buffer.removeSubrange(...nl)
                if let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], obj["id"] as? Int == id {
                    return try #require(obj["result"] as? [String: Any])
                }
                continue
            }
            let chunk = reader.availableData
            if chunk.isEmpty { throw CocoaError(.fileReadUnknown) }
            buffer.append(chunk)
        }
    }

    let start = try call(1, "start_recording", "{}")
    let sid = try #require((start["structuredContent"] as? [String: Any])?["session_id"] as? String)
    let bundlePath = try #require((start["structuredContent"] as? [String: Any])?["bundle"] as? String)
    let first = try call(2, "add_marker", #"{"session_id":"\#(sid)"}"#)
    #expect(first["isError"] as? Bool == false)
    #expect((first["structuredContent"] as? [String: Any])?["title"] as? String == "Marker 1")
    Thread.sleep(forTimeInterval: 1.2)   // markers under a second apart merge into one chapter
    let second = try call(3, "add_marker", #"{"session_id":"\#(sid)","label":"Login works"}"#)
    #expect((second["structuredContent"] as? [String: Any])?["number"] as? Int == 2)
    let live = try call(4, "list_markers", #"{"project":"\#(bundlePath)"}"#)
    #expect(((live["structuredContent"] as? [String: Any])?["markers"] as? [Any])?.count == 2, "markers are readable mid-take")
    let unknown = try call(5, "add_marker", #"{"session_id":"rec_nope"}"#)
    #expect(unknown["isError"] as? Bool == true)
    let stop = try call(6, "stop_recording", #"{"session_id":"\#(sid)"}"#)
    #expect(stop["isError"] as? Bool == false)
    let after = try call(7, "add_marker", #"{"session_id":"\#(sid)"}"#)
    #expect(after["isError"] as? Bool == true, "no markers once the recording stopped")
    let listed = try call(8, "list_markers", #"{"project":"\#(bundlePath)","as_chapters":true}"#)
    let titles = ((listed["structuredContent"] as? [String: Any])?["markers"] as? [[String: Any]])?.compactMap { $0["title"] as? String }
    #expect(titles == ["Marker 1", "Login works"])
    try input.fileHandleForWriting.close()
    p.waitUntilExit()
    #expect(try ProjectBundle(url: URL(fileURLWithPath: bundlePath)).readEdit().chapters.map(\.title).suffix(2) == ["Marker 1", "Login works"])
}
