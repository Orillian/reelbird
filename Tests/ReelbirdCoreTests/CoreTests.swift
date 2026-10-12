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
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rb-\(UUID().uuidString).reelbird")
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

@Test func colorHex() {
    #expect(RGBA(hex: "#FF8000")?.hex == "#FF8000")
    #expect(RGBA(hex: "nope") == nil)
}
