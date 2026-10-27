import CoreGraphics
import ImageIO
import Foundation
import Testing
import ReelbirdCore
@testable import ReelbirdRender

/// A bundle with captions: "Click the big button now." spoken from 0.5 s to 2.0 s.
private func captionedBundle() async throws -> ProjectBundle {
    let bundle = try await Synthetic.makeBundle()
    let words: [(String, Double, Double)] = [("Click", 0.5, 0.8), ("the", 0.8, 0.95), ("big", 0.95, 1.2), ("button", 1.2, 1.6), ("now.", 1.6, 2.0)]
    let segment: [String: Any] = [
        "range": ["start": 0.5, "end": 2.0], "text": "Click the big button now.",
        "words": words.map { ["range": ["start": $0.1, "end": $0.2], "text": $0.0] },
    ]
    let json = try JSONSerialization.data(withJSONObject: ["locale": "en-US", "segments": [segment]])
    try json.write(to: bundle.transcriptURL)
    try "WEBVTT\n\n00:00:00.500 --> 00:00:02.000\nClick the big button now.\n".write(to: bundle.captionsURL, atomically: true, encoding: .utf8)
    return bundle
}

private func edit(_ bundle: ProjectBundle, _ style: CaptionSettings.Style, palette: CaptionSettings.Palette = .night,
                  position: CaptionSettings.Position = .bottom) throws -> EditDocument {
    var e = EditDocument.initial(for: try bundle.readManifest())
    e.background.kind = .solid
    e.background.colors = [RGBA(hex: "#2050A0")!]
    e.background.padding = 0.1
    e.background.shadow = 0
    e.background.motionBlur = false
    e.zoom.mode = .off
    e.cursor.visible = false
    e.camera.visible = false
    e.captions.file = "captions.vtt"
    e.captions.style = style
    e.captions.palette = palette
    e.captions.position = position
    return e
}

private func frame(_ bundle: ProjectBundle, _ e: EditDocument, at t: Double) async throws -> Pixels {
    let manifest = try bundle.readManifest()
    let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: e)
    let sources = try await MediaSources.load(bundle: bundle, manifest: manifest)
    return Pixels(try await Thumbnailer.render(plan: plan, sources: sources, at: t, maxWidth: 960))
}

/// Pixels in a region close to a colour.
private func count(_ px: Pixels, _ c: (Int, Int, Int), ys: Range<Int>, tol: Int = 30) -> Int {
    var n = 0
    for y in ys { for x in 0..<px.width where px.near(x, y, c, tol: tol) { n += 1 } }
    return n
}

private let yellow = (0xFF, 0xD2, 0x3F)

/// Pixels that differ between two frames, in rows `ys`.
private func diff(_ a: Pixels, _ b: Pixels, ys: Range<Int> = 0..<540) -> Int {
    var n = 0
    for y in ys { for x in 0..<a.width { let p = a[x, y], q = b[x, y]; if abs(p.r - q.r) + abs(p.g - q.g) + abs(p.b - q.b) > 30 { n += 1 } } }
    return n
}

@Test func everyStyleDrawsAndNoneDoesNot() async throws {
    let bundle = try await captionedBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    var plain = try edit(bundle, .none)
    plain.captions.file = nil
    let reference = try await frame(bundle, plain, at: 1.3)
    #expect(diff(try await frame(bundle, try edit(bundle, .none), at: 1.3), reference) == 0)
    for style in CaptionSettings.Style.allCases where style != .none {
        let n = diff(try await frame(bundle, try edit(bundle, style), at: 1.3), reference)
        #expect(n > 800, "\(style) changed only \(n) pixels")
    }
}

@Test func highlightAndMarkerUseTheAccent() async throws {
    let bundle = try await captionedBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    // 1.3 s is inside "button": the spoken word is yellow (Highlight) or on a yellow box (Marker).
    for style in [CaptionSettings.Style.highlight, .marker] {
        let px = try await frame(bundle, try edit(bundle, style), at: 1.3)
        #expect(count(px, yellow, ys: 400..<540) > (style == .marker ? 300 : 40), "\(style)")
    }
    // Before any word is spoken nothing is highlighted yet.
    let early = try await frame(bundle, try edit(bundle, .highlight), at: 0.45)
    #expect(count(early, yellow, ys: 400..<540) < 10)
}

@Test func positionsPlaceTheCaption() async throws {
    let bundle = try await captionedBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    var plain = try edit(bundle, .none)
    plain.captions.file = nil
    let reference = try await frame(bundle, plain, at: 1.3)
    let top = try await frame(bundle, try edit(bundle, .classic, position: .top), at: 1.3)
    #expect(diff(top, reference, ys: 0..<100) > 500 && diff(top, reference, ys: 440..<540) == 0)
    let bottom = try await frame(bundle, try edit(bundle, .classic, position: .bottom), at: 1.3)
    #expect(diff(bottom, reference, ys: 0..<100) == 0 && diff(bottom, reference, ys: 440..<540) > 500)
    // With wide padding below the card, Auto puts the caption under the video, clear of the screen.
    var roomy = try edit(bundle, .classic, position: .auto)
    roomy.background.padding = 0.2
    plain.background.padding = 0.2
    let roomyRef = try await frame(bundle, plain, at: 1.3)
    let below = try await frame(bundle, roomy, at: 1.3)
    #expect(diff(below, roomyRef, ys: 0..<540) > 500)
    // The card spans rows 54...486 at 10% padding; at 20% it ends at 432 (540 × 0.8).
    #expect(diff(below, roomyRef, ys: 0..<433) == 0, "Auto covered the video")
}

@Test func slamLandsBiggerThenSettles() async throws {
    let bundle = try await captionedBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    var plain = try edit(bundle, .none)
    plain.captions.file = nil
    let e = try edit(bundle, .slam)
    // "button" starts at 1.2 s; its group appears 0.04 s earlier and lands over 0.12 s.
    let landing = diff(try await frame(bundle, e, at: 1.26), try await frame(bundle, plain, at: 1.26))
    let settled = diff(try await frame(bundle, e, at: 1.5), try await frame(bundle, plain, at: 1.5))
    #expect(landing > settled, "landing \(landing) vs settled \(settled)")
}

/// Design review: `RB_CAPTION_FRAMES=/some/dir scripts/test.sh --filter captionFramesForReview` writes a frame
/// of every style and palette to PNGs. Does nothing otherwise.
@Test func captionFramesForReview() async throws {
    guard let dir = ProcessInfo.processInfo.environment["RB_CAPTION_FRAMES"] else { return }
    let out = URL(fileURLWithPath: dir, isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let bundle = try await captionedBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    let sources = try await MediaSources.load(bundle: bundle, manifest: manifest)
    for style in CaptionSettings.Style.allCases where style != .none {
        for palette in CaptionSettings.Palette.allCases where palette == .night || style == .marker || style == .highlight {
            for t in [1.25, 1.65] {
                var e = try edit(bundle, style, palette: palette)
                e.background.padding = 0.06
                let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: e)
                let img = try await Thumbnailer.render(plan: plan, sources: sources, at: t, maxWidth: 1280)
                let url = out.appendingPathComponent("\(style.rawValue)-\(palette.rawValue)-\(t).png")
                guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(dest, img, nil)
                CGImageDestinationFinalize(dest)
            }
        }
    }
}
