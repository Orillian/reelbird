import Foundation
import Testing
@testable import ReelbirdCore

private func decodeEdit(_ json: String) throws -> EditDocument {
    try JSONCoding.decoder.decode(EditDocument.self, from: Data(json.utf8))
}

@Test func cropDecodingIsTolerant() throws {
    #expect(try decodeEdit("{}").crop == nil)
    #expect(try decodeEdit(#"{"crop": null}"#).crop == nil)
    // A partial crop reaches the far edges: {"y": 0.08} hides the top 8%.
    #expect(try decodeEdit(#"{"crop": {"y": 0.08}}"#).crop == NormRect(x: 0, y: 0.08, width: 1, height: 0.92))
    #expect(try decodeEdit(#"{"crop": {"x": 0.1, "width": 0.5}}"#).crop == NormRect(x: 0.1, y: 0, width: 0.5, height: 1))
    // Out of range values are clamped inside the screen, with a 5% minimum side.
    let clamped = try #require(try decodeEdit(#"{"crop": {"x": -0.2, "y": 0.5, "width": 3, "height": 0.001}}"#).crop)
    #expect(clamped == NormRect(x: 0, y: 0.5, width: 1, height: 0.05))
    // Garbage or a whole-screen crop means no crop, and never breaks the document.
    for bad in [#""crop""#, "42", "[1,2]", #"{"x": "a"}"#, #"{"x": 0, "y": 0, "width": 1, "height": 1}"#] {
        let e = try decodeEdit(#"{"crop": \#(bad), "title": "Still loads"}"#)
        #expect(e.crop == nil, "\(bad)")
        #expect(e.title == "Still loads")
    }
    // Round trip; no key when there's no crop.
    var e = EditDocument()
    e.crop = NormRect(x: 0, y: 0.1, width: 1, height: 0.9)
    let data = try JSONCoding.encoder.encode(e)
    #expect(try JSONCoding.decoder.decode(EditDocument.self, from: data).crop == e.crop)
    #expect(!String(decoding: try JSONCoding.encoder.encode(EditDocument()), as: UTF8.self).contains("\"crop\""))
}

@Test func cropSpaceMapsBothWays() {
    let s = CropSpace(NormRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4))
    let p = NormPoint(x: 0.35, y: 0.4)
    let v = s.toView(p)
    #expect(abs(v.x - 0.5) < 1e-12 && abs(v.y - 0.5) < 1e-12)
    let back = s.toSource(v)
    #expect(abs(back.x - p.x) < 1e-12 && abs(back.y - p.y) < 1e-12)
    #expect(s.pixelSize(of: PixelSize(width: 1920, height: 1080)) == PixelSize(width: 960, height: 432))
    #expect(CropSpace(nil).isIdentity && CropSpace(.full).isIdentity)
    #expect(!s.contains(NormPoint(x: 0.5, y: 0.1)) && s.contains(p))
    // Focus rects outside the crop are dropped; overlapping ones are clipped.
    let events = s.viewEvents([
        InputEvent(t: 0, type: .focus, rect: NormRect(x: 0.2, y: 0.0, width: 0.2, height: 0.05)),
        InputEvent(t: 1, type: .focus, rect: NormRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
    ])
    #expect(events[0].rect == nil)
    let r = try? #require(events[1].rect)
    #expect(r.map { abs($0.y) < 1e-12 && abs($0.height - 0.25) < 1e-12 && abs($0.width - 0.4) < 1e-12 } == true)
}

@Test func autoZoomPlansInsideTheCrop() {
    let crop = NormRect(x: 0, y: 0.12, width: 1, height: 0.88)
    var events: [InputEvent] = []
    // Toolbar clicks at y = 0.05, then page clicks at y = 0.6.
    for t in [1.0, 1.5, 2.0] { events.append(.down(t, NormPoint(x: 0.4, y: 0.05))) }
    for t in [8.0, 8.5] { events.append(.down(t, NormPoint(x: 0.7, y: 0.6))) }
    let all = AutoZoomPlanner.plan(events: events, duration: 14, intensity: 0.5)
    #expect(all.contains { $0.range.contains(1.5) })
    let cropped = AutoZoomPlanner.plan(events: events, duration: 14, intensity: 0.5, crop: crop)
    #expect(!cropped.contains { $0.range.contains(1.5) }, "\(cropped)")
    let page = cropped.first { $0.range.contains(8.2) }
    #expect(page != nil)
    // Focus comes back in full-screen coordinates.
    if let f = page?.focus { #expect(abs(f.y - 0.6) < 0.1 && abs(f.x - 0.7) < 0.1, "\(f)") }
    // User regions survive a merge inside a crop.
    let user = ZoomRegion(range: TimeRange(start: 4, end: 6), scale: 2, focus: NormPoint(x: 0.5, y: 0.5), source: .user)
    let merged = AutoZoomPlanner.merged(existing: [user], events: events, duration: 14, intensity: 0.5, crop: crop)
    #expect(merged.contains(user))
}

@Test func browserWindowsAreRecognised() {
    for app in ["Google Chrome", "Safari", "Arc", "Microsoft Edge", "Firefox", "Brave Browser", "Dia", "Opera", "Vivaldi",
                "Firefox Developer Edition", "Chromium", "Safari Technology Preview"] {
        #expect(CaptureSource.window(id: 1, app: app, title: "x").browserAppName == app, "\(app)")
    }
    for app in ["Xcode", "Archive Utility", "Search Helper", "Finder", "Slack"] {
        #expect(CaptureSource.window(id: 1, app: app, title: "x").browserAppName == nil, "\(app)")
    }
    #expect(CaptureSource.display(id: 1, name: "Chrome Display").browserAppName == nil)
}

@Test func cropSuggestionCacheChecksTheScreenFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rb-crop-\(UUID().uuidString).reelbird")
    let b = try ProjectBundle.create(at: dir)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: b.directory(for: .screen), withIntermediateDirectories: true)
    try Data(repeating: 1, count: 1000).write(to: b.resolve("screen/screen.mp4"))
    let m = ProjectManifest(title: "t", appVersion: "test", capture: CaptureInfo(source: .synthetic(name: "t"), pixelSize: PixelSize(width: 1000, height: 800),
                                                                                 scale: 2, frameRate: 30),
                            clock: ClockInfo(originHostTime: 0),
                            tracks: [TrackInfo(kind: .screen, directory: "screen", file: "screen/screen.mp4", codec: "h264")])
    let s = CropSuggestion(file: "screen/screen.mp4", fileSize: 1000, height: 800, topPixels: 100, confidence: 0.9)
    try b.writeCropSuggestion(s)
    #expect(b.readCropSuggestion(manifest: m) == s)
    #expect(s.isConfident && s.crop == NormRect(x: 0, y: 0.125, width: 1, height: 0.875))
    try Data(repeating: 1, count: 1001).write(to: b.resolve("screen/screen.mp4"))
    #expect(b.readCropSuggestion(manifest: m) == nil)
    #expect(!CropSuggestion(file: "f", fileSize: 1, height: 800, topPixels: 100, confidence: 0.4).isConfident)
    #expect(CropSuggestion(file: "f", fileSize: 1, height: 800, topPixels: 0, confidence: 0).crop == nil)
}
