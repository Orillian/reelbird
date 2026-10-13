import Foundation
import Testing
@testable import ReelbirdCore

@Test func markerEventsRoundTripThroughTheLog() throws {
    let url = testTemporaryDirectory.appendingPathComponent("rb-markers-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let w = try EventLogWriter(url: url)
    w.append(.move(0.5, NormPoint(x: 0.1, y: 0.2)))
    w.append(.marker(1.25))
    w.append(.marker(2.5, label: "Checkout"))
    w.append(.marker(3, label: "Say \"hi\" \\ there"))   // escapes: read through the Codable fallback
    w.close()
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains(#"{"t":1.25,"type":"marker"}"#))
    let events = try EventLog.read(url)
    let markers = events.filter { $0.type == .marker }
    #expect(markers.map(\.t) == [1.25, 2.5, 3])
    #expect(markers.map(\.label) == [nil, "Checkout", "Say \"hi\" \\ there"])

    // The fast parser reads the flat lines on its own.
    let line = Array(#"{"label":"Checkout","t":2.5,"type":"marker"}"#.utf8)
    let parsed = line.withUnsafeBufferPointer { FlatEventParser.parse($0) }
    #expect(parsed == .marker(2.5, label: "Checkout"))
}

@Test func markersResolveFromEventsUntilTheEditHasItsOwn() throws {
    let events: [InputEvent] = [.move(0.1, NormPoint(x: 0, y: 0)), .marker(4, label: "Second"), .marker(2), .marker(-1)]
    let fromLog = Markers.resolve(edit: nil, events: events)
    #expect(fromLog.map(\.t) == [0, 2, 4])
    // Numbered in log order (the log is time-sorted when read); `m1…` IDs are stable.
    #expect(Markers.fromEvents(events.sorted { $0.t < $1.t }).map(\.title) == ["Marker 1", "Marker 2", "Second"])

    var edit = EditDocument()
    #expect(Markers.resolve(edit: edit, events: events).count == 3)
    edit.markers = [Marker(id: "a", t: 9, title: "Mine")]
    #expect(Markers.resolve(edit: edit, events: events).map(\.title) == ["Mine"])
    edit.markers = []
    #expect(Markers.resolve(edit: edit, events: events).isEmpty, "deleting every marker sticks")

    #expect(Markers.label("   ", number: 4) == "Marker 4")
    #expect(Markers.label(String(repeating: "x", count: 300), number: 1).count == 120)
}

@Test func editMarkersDecodeLeniently() throws {
    let old = try JSONCoding.decoder.decode(EditDocument.self, from: Data(#"{"formatVersion":1,"chapters":[]}"#.utf8))
    #expect(old.markers == nil)
    let bad = try JSONCoding.decoder.decode(EditDocument.self, from: Data(#"{"markers":"oops","title":"T"}"#.utf8))
    #expect(bad.markers == nil && bad.title == "T", "a broken markers value never fails the document")
    var e = EditDocument()
    e.markers = [Marker(id: "m1", t: 1.5, title: "Intro")]
    let back = try JSONCoding.decoder.decode(EditDocument.self, from: JSONCoding.encoder.encode(e))
    #expect(back.markers == e.markers)
    // Absent stays absent when written, so the log keeps being the source.
    let plain = String(decoding: try JSONCoding.encoder.encode(EditDocument()), as: UTF8.self)
    #expect(!plain.contains("markers"))
}

@Test func markersBecomeChapters() {
    func m(_ t: Double, _ title: String) -> Marker { Marker(id: title, t: t, title: title) }
    // 60 s take, trimmed to 5…55, a pause cut 20…30.
    let tl = EditTimeline(duration: 60, trim: TimeRange(start: 5, end: 55), cuts: [TimeRange(start: 20, end: 30)])
    let chapters = Markers.chapters(from: [m(40, "Late"), m(12, "Setup"), m(25, "In the pause"), m(12.4, "Too close"),
                                           m(2, "Before the trim"), m(58, "After the end")], timeline: tl)
    // "Before the trim" moves to the trim start (output 0) and opens the list; "In the pause" moves to 30.
    #expect(chapters.map(\.title) == ["Before the trim", "Setup", "In the pause", "Late"])
    #expect(chapters.map(\.time) == [5, 12, 30, 40])

    // First marker well after the start: a Start chapter opens the list.
    let plain = EditTimeline(duration: 30, trim: nil, cuts: [])
    let c2 = Markers.chapters(from: [m(10, "Demo")], timeline: plain)
    #expect(c2 == [Chapter(time: 0, title: "Start"), Chapter(time: 10, title: "Demo")])
    // A marker in the first second becomes the first chapter at 0.
    #expect(Markers.chapters(from: [m(0.6, "Hello"), m(9, "Next")], timeline: plain).map(\.time) == [0, 9])
    #expect(Markers.chapters(from: [], timeline: plain).isEmpty)
    #expect(Markers.chapters(from: [m(31, "Past")], timeline: plain).isEmpty)
}
