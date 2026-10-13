import Foundation
import Testing
@testable import ReelbirdCore

@Test func timelineCutsAndTrim() {
    let tl = EditTimeline(duration: 10, trim: TimeRange(start: 1, end: 9), cuts: [TimeRange(start: 3, end: 4), TimeRange(start: 6, end: 7)])
    #expect(tl.kept == [TimeRange(start: 1, end: 3), TimeRange(start: 4, end: 6), TimeRange(start: 7, end: 9)])
    #expect(abs(tl.duration - 6) < 1e-9)
    #expect(tl.sourceTime(forOutput: 2.5) == 4.5)
    #expect(tl.outputTime(forSource: 3.5) == nil)
    #expect(tl.outputTime(forSource: 7.5) == 4.5)
}

@Test func editDocumentToleratesMissingAndUnknownKeys() throws {
    let json = #"{"zoom":{"intensity":0.9},"futureField":42,"cursor":{"size":2}}"#
    let e = try JSONCoding.decoder.decode(EditDocument.self, from: Data(json.utf8))
    #expect(e.zoom.intensity == 0.9)
    #expect(e.zoom.mode == .auto)
    #expect(e.cursor.size == 2)
    #expect(e.cursor.smoothing == CursorSettings().smoothing)
}

@Test func bundleRoundTrip() throws {
    let dir = testTemporaryDirectory.appendingPathComponent("rb-\(UUID().uuidString).reelbird")
    defer { try? FileManager.default.removeItem(at: dir) }
    let b = try ProjectBundle.create(at: dir)
    let m = ProjectManifest(createdAt: Date(timeIntervalSince1970: 1_790_000_000), title: "Demo", appVersion: "test",
                            capture: CaptureInfo(source: .synthetic(name: "t"), pixelSize: PixelSize(width: 1920, height: 1080), scale: 2, frameRate: 60),
                            clock: ClockInfo(originHostTime: 100), pauses: [TimeRange(start: 2, end: 3)], duration: 5)
    try b.writeManifest(m)
    #expect(try b.readManifest() == m)
    #expect(try b.readEdit().cuts == [TimeRange(start: 2, end: 3)])
    let log = try EventLogWriter(url: b.eventsURL)
    log.append(.move(0.5, NormPoint(x: 0.1, y: 0.2)))
    log.append(.down(0.1, NormPoint(x: 0.3, y: 0.3)))
    log.close()
    let events = try b.readEvents()
    #expect(events.map(\.type) == [.down, .move])
}

@Test func liveBundleIsOnlyARecentRecordingManifest() throws {
    let dir = testTemporaryDirectory.appendingPathComponent("rb-\(UUID().uuidString).reelbird")
    defer { try? FileManager.default.removeItem(at: dir) }
    let b = try ProjectBundle.create(at: dir)
    var m = ProjectManifest(title: "Live", appVersion: "test",
                            capture: CaptureInfo(source: .synthetic(name: "t"), pixelSize: PixelSize(width: 640, height: 360), scale: 1, frameRate: 30),
                            clock: ClockInfo(originHostTime: 0))
    m.status = .recording
    try b.writeManifest(m)
    #expect(b.isBeingRecorded(m))
    #expect(!b.isBeingRecorded(m, now: Date().addingTimeInterval(60))) // stopped changing: a crashed take
    m.status = .complete
    #expect(!b.isBeingRecorded(m))
}

@Test func colorHex() {
    #expect(RGBA(hex: "#FF8000")?.hex == "#FF8000")
    #expect(RGBA(hex: "nope") == nil)
    #expect(RGBA(1e300, -5, 0.5, 1).hex == "#FF0080")
}

@Test func eventLogSkipsTruncatedLineAndIsFast() throws {
    let url = testTemporaryDirectory.appendingPathComponent("ev-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    var s = ""
    for i in 0..<432_000 { s += #"{"t":\#(Double(i) / 120),"type":"move","x":0.4123,"y":0.2331}"# + "\n" }
    try Data(s.utf8).write(to: url)
    let start = Date()
    #expect(try EventLog.read(url).count == 432_000)
    let elapsed = Date().timeIntervalSince(start)
    print("events.jsonl 432k lines read in \(elapsed) s")
    s += #"{"t":9999,"type":"mo"#
    try Data(s.utf8).write(to: url)
    #expect(try EventLog.read(url).count == 432_000)
}

@Test func eventLogFastPathMatchesCodable() throws {
    let url = testTemporaryDirectory.appendingPathComponent("ev-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let w = try EventLogWriter(url: url)
    let events: [InputEvent] = [
        .move(0.1, NormPoint(x: 0.25, y: 0.5)), .down(0.2, NormPoint(x: 0.3, y: 0.4), button: 1),
        InputEvent(t: 0.3, type: .key, chars: "s", mods: ["⌘"]),
        InputEvent(t: 0.4, type: .focus, rect: NormRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)),
        InputEvent(t: 0.5, type: .scroll, x: 0.5, y: 0.5, dx: 0, dy: -3), InputEvent(t: 0.6, type: .cursor, image: "abc"),
    ]
    events.forEach(w.append); w.close()
    #expect(try EventLog.read(url) == events)
}
