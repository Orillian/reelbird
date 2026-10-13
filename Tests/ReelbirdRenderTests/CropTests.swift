@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import Testing
import ReelbirdCore
@testable import ReelbirdRender

// Crop and browser-toolbar detection on synthetic recordings (real H.264 files, real Metal).

/// Luma (video range) of the synthetic browser's parts.
private enum BrowserY {
    static let tabs: UInt8 = 175, toolbar: UInt8 = 205, omnibox: UInt8 = 230, divider: UInt8 = 150
    static let page: UInt8 = 235, text: UInt8 = 40, image: UInt8 = 100
    /// Toolbar grey in RGB: (205 − 16) × 255 / 219 ≈ 220.
    static let toolbarRGB = (220, 220, 220)
}

/// A browser window: tab strip, toolbar with an address field, a divider line ending at row `toolbar`, then a
/// page (a still white margin of `margin` rows, then text and an image block that scroll). The address text
/// changes half-way through (a navigation). `still`: the page never moves. `noise`: every pixel changes.
private func browserScreen(toolbar t: Int, divider: Int, margin: Int, still: Bool = false, noise: Bool = false) -> Synthetic.Draw {
    { y, ys, uv, uvs, w, h, n in
        for r in 0..<(h / 2) { memset(uv + r * uvs, 128, w) }
        if noise {
            var seed = UInt32(truncatingIfNeeded: n &* 2_654_435_761 &+ 1)
            for r in 0..<h {
                let row = y + r * ys
                for c in stride(from: 0, to: w, by: 4) {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    memset(row + c, Int32(16 + (seed >> 24) % 220), min(4, w - c))
                }
            }
            return
        }
        let tabH = t * 2 / 5
        func fill(_ r0: Int, _ r1: Int, _ c0: Int, _ c1: Int, _ v: UInt8) {
            let c0 = max(0, c0), c1 = min(w, c1)
            guard c1 > c0 else { return }
            for r in max(0, r0)..<min(h, r1) { memset(y + r * ys + c0, Int32(v), c1 - c0) }
        }
        fill(0, tabH, 0, w, BrowserY.tabs)
        fill(tabH / 4, tabH, w / 10, w / 10 + w / 6, BrowserY.toolbar)          // active tab
        fill(tabH / 3, tabH * 2 / 3, w / 10 + w / 5, w / 10 + w / 5 + w / 12, 120) // other tab's title
        fill(tabH, t - divider, 0, w, BrowserY.toolbar)
        let o0 = tabH + (t - divider - tabH) / 5, o1 = t - divider - (t - divider - tabH) / 5
        fill(o0, o1, w / 4, w * 3 / 4, BrowserY.omnibox)
        let navigated = n >= 60
        fill((o0 + o1) / 2 - 3, (o0 + o1) / 2 + 3, w / 4 + 12, w / 4 + 12 + (navigated ? w / 5 : w / 8), 60) // address text
        fill(t - divider, t, 0, w, BrowserY.divider)
        fill(t, h, 0, w, BrowserY.page)
        // Page content below the still margin, scrolling 9 rows per frame.
        let top = t + margin
        let scroll = still ? 0 : n * 9
        var seed = UInt32(777)
        let period = 22
        var line = 0
        while true {
            let ry = top + line * period - scroll % (period * 40)
            line += 1
            if ry >= h { break }
            seed = seed &* 1_664_525 &+ 1_013_904_223
            if ry + 8 <= top { continue }
            let len = w / 3 + Int(seed >> 22) % (w / 2)
            fill(max(top, ry), ry + 8, w / 12, w / 12 + len, BrowserY.text)
        }
        let ix = still ? w / 2 : (w / 2 + n * 11) % (w - w / 5)
        fill(top + (h - top) / 3, top + (h - top) / 3 + (h - top) / 4, ix, ix + w / 5, BrowserY.image)
    }
}

private func browserBundle(width: Int, height: Int, scale: Double, toolbar: Int, divider: Int, margin: Int,
                           still: Bool = false, noise: Bool = false, seconds: Double = 4,
                           events: [InputEvent]? = nil, redCursor: Bool = false) async throws -> ProjectBundle {
    var o = Synthetic.Options()
    o.width = width; o.height = height; o.captureScale = scale; o.seconds = seconds; o.microphone = false
    o.screen = browserScreen(toolbar: toolbar, divider: divider, margin: margin, still: still, noise: noise)
    o.source = .window(id: 7, app: "Google Chrome", title: "Checkout")
    o.events = events
    o.redCursor = redCursor
    return try await Synthetic.makeBundle(o)
}

private func plainEdit(_ manifest: ProjectManifest) -> EditDocument {
    var e = EditDocument.initial(for: manifest)
    e.background.kind = .none
    e.background.motionBlur = false
    e.zoom.mode = .off
    e.cursor.visible = false
    e.camera.visible = false
    return e
}

private func render(_ bundle: ProjectBundle, _ edit: EditDocument, at t: Double, width: Int = 640) async throws -> Pixels {
    let manifest = try bundle.readManifest()
    let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: edit)
    let sources = try await MediaSources.load(bundle: bundle, manifest: manifest)
    return Pixels(try await Thumbnailer.render(plan: plan, sources: sources, at: t, maxWidth: width))
}

private func count(_ px: Pixels, where match: ((r: Int, g: Int, b: Int)) -> Bool) -> Int {
    var n = 0
    for y in 0..<px.height { for x in 0..<px.width where match(px[x, y]) { n += 1 } }
    return n
}

// MARK: Detector

@Test(arguments: [
    // Retina window: 91 pt toolbar (2 px divider) over a page whose top 40 px stay white.
    (1920, 1080, 2.0, 182, 2, 40),
    // 1x window: 88 px toolbar (1 px divider), page content right under it.
    (1280, 800, 1.0, 88, 1, 0),
])
func detectorFindsTheToolbarBand(_ c: (Int, Int, Double, Int, Int, Int)) async throws {
    let bundle = try await browserBundle(width: c.0, height: c.1, scale: c.2, toolbar: c.3, divider: c.4, margin: c.5)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    let d = try await ToolbarDetector.detect(url: try #require(bundle.mediaURL(for: .screen, in: manifest)), captureScale: c.2)
    #expect(abs(d.topPixels - c.3) <= 2, "found \(d.topPixels) px, toolbar is \(c.3) px (\(d))")
    #expect(d.confidence >= CropSuggestion.goodConfidence, "\(d)")
    #expect(d.height == c.1)
}

@Test func detectorRejectsAStillRecording() async throws {
    let bundle = try await browserBundle(width: 1280, height: 800, scale: 1, toolbar: 88, divider: 1, margin: 0, still: true)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let d = try await ToolbarDetector.detect(url: try #require(bundle.mediaURL(for: .screen, in: try bundle.readManifest())), captureScale: 1)
    #expect(d.topPixels == 0 && d.confidence == 0, "\(d)")
}

@Test func detectorRejectsARecordingThatChangesEverywhere() async throws {
    let bundle = try await browserBundle(width: 1280, height: 800, scale: 1, toolbar: 88, divider: 1, margin: 0, noise: true, seconds: 2)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let d = try await ToolbarDetector.detect(url: try #require(bundle.mediaURL(for: .screen, in: try bundle.readManifest())), captureScale: 1)
    #expect(d.topPixels == 0 && d.confidence == 0, "\(d)")
}

@Test func suggestionIsCachedPerScreenFile() async throws {
    let bundle = try await browserBundle(width: 1280, height: 800, scale: 1, toolbar: 88, divider: 1, margin: 0)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let s = try #require(await ToolbarDetector.suggestion(bundle: bundle))
    #expect(s.isConfident && abs(s.topPixels - 88) <= 2)
    #expect(FileManager.default.fileExists(atPath: bundle.cropSuggestionURL.path))
    let manifest = try bundle.readManifest()
    #expect(bundle.readCropSuggestion(manifest: manifest) == s)
    // A different screen file (size) invalidates the cache.
    var stale = s
    stale.fileSize += 1
    try bundle.writeCropSuggestion(stale)
    #expect(bundle.readCropSuggestion(manifest: manifest) == nil)
    let crop = try #require(s.crop)
    #expect(abs(crop.y - Double(s.topPixels) / 800) < 1e-9 && crop.height == 1 - crop.y)
}

// MARK: Render

@Test func cropRemovesTheToolbarAndSetsTheCanvas() async throws {
    let bundle = try await browserBundle(width: 1280, height: 800, scale: 1, toolbar: 88, divider: 1, margin: 24, seconds: 2)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    var edit = plainEdit(manifest)
    // Browser chrome: the tab strip (RGB 185) and toolbar (220) greys.
    func isChrome(_ p: (r: Int, g: Int, b: Int)) -> Bool { (180...225).contains(p.r) && abs(p.g - p.r) <= 3 && abs(p.b - p.r) <= 3 }
    /// Rows that are mostly chrome grey.
    func chromeRows(_ px: Pixels) -> Int {
        (0..<px.height).filter { y in (0..<px.width).filter { isChrome(px[$0, y]) }.count > px.width / 2 }.count
    }

    let full = try await render(bundle, edit, at: 1)
    #expect(full.width == 640 && full.height == 400)
    #expect(chromeRows(full) >= 20, "uncropped frame shows the toolbar (\(chromeRows(full)) rows)")

    edit.crop = NormRect(x: 0, y: 88.0 / 800, width: 1, height: 712.0 / 800)
    let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: edit)
    #expect(plan.sourceSize == PixelSize(width: 1280, height: 712) && plan.canvasSize == PixelSize(width: 1280, height: 712))
    let cropped = try await render(bundle, edit, at: 1)
    #expect(cropped.width == 640 && cropped.height == 356)
    #expect(chromeRows(cropped) == 0, "chrome rows left in the cropped frame: \(chromeRows(cropped))")
    let divider = count(cropped) { (150...162).contains($0.r) && abs($0.g - $0.r) <= 3 }
    #expect(divider < 100, "divider grey left: \(divider) px")
    // The first rows are the page's white margin, not the tab strip or divider.
    for x in [5, 320, 635] { #expect(cropped.near(x, 1, (255, 255, 255), tol: 6), "top row at \(x): \(cropped[x, 1])") }

    // Posters (library, share) use the saved edit, crop included.
    try bundle.writeEdit(edit)
    let poster = try await Thumbnailer.poster(bundle: bundle, at: 1, maxWidth: 640)
    #expect(poster.width == 640 && poster.height == 356)
}

@Test func croppedExportHasTheCroppedSize() async throws {
    let bundle = try await browserBundle(width: 1280, height: 800, scale: 1, toolbar: 88, divider: 1, margin: 24, seconds: 1)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    var edit = plainEdit(try bundle.readManifest())
    edit.crop = NormRect(x: 0, y: 0.11, width: 1, height: 0.89)
    let url = try await Exporter.export(bundle: bundle, edit: edit, options: ExportOptions(format: .mp4H264)) { _ in }
    defer { try? FileManager.default.removeItem(at: url) }
    let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
    let size = try await track.load(.naturalSize)
    #expect(Int(size.width) == 1280 && Int(size.height) == 712, "\(size)")
}

@Test func cursorOutsideTheCropIsNotDrawn() async throws {
    func redPixels(pointer: NormPoint) async throws -> Int {
        let bundle = try await browserBundle(width: 1280, height: 800, scale: 1, toolbar: 88, divider: 1, margin: 24, seconds: 1.5,
                                             events: [.move(0, pointer)], redCursor: true)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        var edit = plainEdit(try bundle.readManifest())
        edit.cursor.visible = true
        edit.cursor.size = 1
        edit.crop = NormRect(x: 0, y: 0.11, width: 1, height: 0.89)
        let px = try await render(bundle, edit, at: 0.5)
        return count(px) { $0.r > 200 && $0.g < 60 && $0.b < 60 }
    }
    let inToolbar = try await redPixels(pointer: NormPoint(x: 0.5, y: 0.05))
    #expect(inToolbar == 0, "cursor in the cropped-off toolbar drew \(inToolbar) red px")
    let onPage = try await redPixels(pointer: NormPoint(x: 0.5, y: 0.5))
    #expect(onPage > 100, "cursor on the page drew \(onPage) red px")
    // Right at the crop edge it is fading, not gone.
    let atEdge = try await redPixels(pointer: NormPoint(x: 0.5, y: 0.112))
    #expect(atEdge > 0)
}

@Test func autoZoomIgnoresClicksInTheCroppedOffArea() async throws {
    // Clicks in the toolbar (y = 0.05) and, later, on the page (y = 0.6).
    var events: [InputEvent] = [.move(0, NormPoint(x: 0.5, y: 0.5))]
    for (i, t) in [1.0, 1.6, 2.2].enumerated() { events += [.move(t - 0.2, NormPoint(x: 0.3 + 0.05 * Double(i), y: 0.05)), .down(t, NormPoint(x: 0.3 + 0.05 * Double(i), y: 0.05))] }
    for t in [7.0, 7.5] { events += [.move(t - 0.2, NormPoint(x: 0.7, y: 0.6)), .down(t, NormPoint(x: 0.7, y: 0.6))] }
    let bundle = try await browserBundle(width: 640, height: 400, scale: 1, toolbar: 44, divider: 1, margin: 0, seconds: 12, events: events)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    var edit = EditDocument.initial(for: manifest)
    edit.zoom.mode = .auto

    let uncropped = try RenderPlan(bundle: bundle, manifest: manifest, edit: edit)
    #expect(uncropped.regions.contains { $0.range.contains(1.6) }, "without a crop the toolbar clicks zoom")

    edit.crop = NormRect(x: 0, y: 0.11, width: 1, height: 0.89)
    let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: edit)
    #expect(!plan.regions.contains { $0.range.overlaps(TimeRange(start: 0, end: 4)) }, "\(plan.regions)")
    let page = try #require(plan.regions.first { $0.range.contains(7.2) })
    // Focus is stored in full-screen coordinates; the camera works in the crop's.
    let focus = try #require(page.focus)
    #expect(abs(focus.y - 0.6) < 0.15, "\(focus)")
    let (scale, centre) = plan.camera.transform(at: 7.3)
    #expect(scale > 1.2)
    #expect(abs(centre.y - plan.crop.toView(focus).y) < 0.08, "camera centre \(centre) vs focus \(plan.crop.toView(focus))")
}
