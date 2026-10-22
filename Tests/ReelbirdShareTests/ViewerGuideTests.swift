import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import JavaScriptCore
import ReelbirdCore
import Testing
import UniformTypeIdentifiers
@testable import ReelbirdShare

// MARK: - Guide, click-through and copy text on the viewer page

/// Steps and a text layer that sit on brand/media/hero.mp4 (1920×1080, 8 s): a task list where a task
/// is ticked off, then the list is shared and its link copied.
enum ViewerFixture {
    static let steps: [ViewerMeta.Guide.Step] = [
        .init(id: "c350", n: 1, t: 0.35, kind: "click", text: #"Click next to "Fix flaky checkout test""#,
              note: "Tick off the flaky test first, so the list stays current.", section: "Finish a task",
              image: "steps.1/01.jpg", w: 1600, h: 900, x: 0.3198, y: 0.3875,
              box: NormRect(x: 0.3328, y: 0.3796, width: 0.0814, height: 0.0157)),
        .init(id: "c2500", n: 2, t: 2.5, kind: "click", text: #"Click "Share""#,
              note: "Then open the share sheet from the toolbar.", section: "Share the list",
              image: "steps.1/02.jpg", w: 1600, h: 900, x: 0.7355, y: 0.1447,
              box: NormRect(x: 0.7166, y: 0.1318, width: 0.0378, height: 0.0258)),
        .init(id: "c4000", n: 3, t: 4.0, kind: "click", text: #"Click "Copy link""#,
              note: "Anyone with the link can view the list.",
              image: "steps.1/03.jpg", w: 1600, h: 900, x: 0.8329, y: 0.3514,
              box: NormRect(x: 0.8038, y: 0.3385, width: 0.0581, height: 0.0258)),
        .init(id: "k5850", n: 4, t: 5.85, kind: "key", text: "Press Esc",
              note: "That closes the popover. The link stays on your clipboard.",
              image: "steps.1/04.jpg", w: 1600, h: 900, keys: "Esc"),
        .init(id: "c7200", n: 5, t: 7.2, kind: "click", text: #"Click "Book offsite venue""#, section: "Next up",
              image: "steps.1/05.jpg", w: 1600, h: 900, x: 0.3663, y: 0.6558,
              box: NormRect(x: 0.3328, y: 0.6467, width: 0.0669, height: 0.0182)),
    ]
    /// Video times of the frames the step images are taken from.
    static let imageTimes: [Double] = [0.2, 2.3, 3.6, 5.6, 7.0]

    typealias L = TextLayer.Line

    /// The zoomed-out window: menu bar, toolbar, sidebar and the 13 tasks with their tags and dates.
    static func overview(open: Int, popover: Bool) -> [L] {
        var lines: [L] = [
            L(text: "Tasks", x: 0.1323, y: 0.0853, w: 0.0218, h: 0.0129), L(text: "File", x: 0.1613, y: 0.0853, w: 0.0145, h: 0.0129),
            L(text: "Edit", x: 0.1831, y: 0.0853, w: 0.0160, h: 0.0129), L(text: "View", x: 0.2043, y: 0.0853, w: 0.0202, h: 0.0129),
            L(text: "Window", x: 0.2278, y: 0.0853, w: 0.0342, h: 0.0129), L(text: "Help", x: 0.2645, y: 0.0853, w: 0.0203, h: 0.0129),
            L(text: "Mon 12 Oct 9:41", x: 0.8125, y: 0.0852, w: 0.0567, h: 0.0157),
            L(text: "Inbox", x: 0.3067, y: 0.1525, w: 0.0247, h: 0.0155), L(text: "Share", x: 0.7209, y: 0.1550, w: 0.0218, h: 0.0129),
            L(text: "New Task", x: 0.7754, y: 0.1546, w: 0.0342, h: 0.0133),
            L(text: "Search", x: 0.1924, y: 0.1883, w: 0.0257, h: 0.0165),
            L(text: "Inbox", x: 0.1930, y: 0.2274, w: 0.0236, h: 0.0129), L(text: "12", x: 0.2776, y: 0.2274, w: 0.0087, h: 0.0129),
            L(text: "Today", x: 0.1930, y: 0.2556, w: 0.0250, h: 0.0158), L(text: "Upcoming", x: 0.1930, y: 0.2818, w: 0.0383, h: 0.0184),
            L(text: "Completed", x: 0.1930, y: 0.3101, w: 0.0410, h: 0.0158), L(text: "PROJECTS", x: 0.1831, y: 0.3463, w: 0.0349, h: 0.0129),
            L(text: "Website relaunch", x: 0.1904, y: 0.3747, w: 0.0640, h: 0.0133), L(text: "Mobile app", x: 0.1904, y: 0.4028, w: 0.0436, h: 0.0158),
            L(text: "Q4 planning", x: 0.1904, y: 0.4315, w: 0.0465, h: 0.0157), L(text: "Hiring", x: 0.1904, y: 0.4580, w: 0.0268, h: 0.0160),
            L(text: "Maya Rivera", x: 0.1948, y: 0.8500, w: 0.0451, h: 0.0157),
            L(text: "Inbox", x: 0.3110, y: 0.2145, w: 0.0392, h: 0.0207),
            L(text: "Monday, 12 October · \(open) open", x: 0.3125, y: 0.2454, w: 0.1003, h: 0.0157),
        ]
        let tasks: [(String, Double, String, Double, String, Double)] = [
            ("Record the launch demo for Friday", 0.1235, "Website", 0.0276, "Fri", 0.0116),
            ("Review onboarding copy", 0.0887, "Website", 0.0276, "10:00", 0.0218),
            ("Fix flaky checkout test", 0.0814, "Mobile", 0.0233, "11:30", 0.0189),
            ("Draft Q4 roadmap one-pager", 0.1047, "Planning", 0.0305, "13:00", 0.0203),
            ("Interview: product designer", 0.0990, "Hiring", 0.0203, "15:00", 0.0203),
            ("Send weekly update", 0.0727, "Planning", 0.0305, "17:00", 0.0203),
            ("Update pricing page screenshots", 0.1193, "Website", 0.0276, "Tomorrow", 0.0364),
            ("Triage crash reports", 0.0728, "Mobile", 0.0233, "Tomorrow", 0.0364),
            ("Book offsite venue", 0.0669, "Planning", 0.0305, "Fri", 0.0116),
            ("Reference checks", 0.0655, "Hiring", 0.0203, "Fri", 0.0116),
            ("Archive old experiments", 0.0874, "Mobile", 0.0233, "Next week", 0.0350),
            ("Plan launch livestream", 0.0802, "Website", 0.0276, "Next week", 0.0350),
            ("Renew design tool licences", 0.0974, "Planning", 0.0305, "Oct 30", 0.0233),
        ]
        for (i, t) in tasks.enumerated() {
            let c = 0.2972 + 0.04468 * Double(i)
            lines.append(L(text: t.0, x: 0.3328, y: c - 0.0085, w: t.1, h: 0.0170))
            if popover && i == 0 { continue } // the popover covers this row's tag and date
            lines.append(L(text: t.2, x: 0.7213 - t.3 / 2, y: c - 0.0065, w: t.3, h: 0.0129))
            lines.append(L(text: t.4, x: 0.8092 - t.5, y: c - 0.0065, w: t.5, h: 0.0129))
        }
        if popover {
            lines += [
                L(text: "Share “Today”", x: 0.6497, y: 0.1963, w: 0.0538, h: 0.0157),
                L(text: "Anyone with the link can view", x: 0.6497, y: 0.2194, w: 0.0945, h: 0.0131),
                L(text: "tasks.app/s/7Hk2pQx9", x: 0.6555, y: 0.2661, w: 0.0756, h: 0.0155),
                L(text: "Copied", x: 0.7760, y: 0.2685, w: 0.0263, h: 0.0131),
            ]
        }
        return lines
    }

    /// Zoomed in on the toolbar, with or without the share popover.
    static func closeUp(popover: Bool) -> [L] {
        var lines: [L] = [
            L(text: "box", x: 0, y: 0.2403, w: 0.0480, h: 0.0362),
            L(text: "nday, 12 October · 12 open", x: 0, y: 0.2997, w: 0.1613, h: 0.0262),
            L(text: "Share", x: 0.7166, y: 0.1318, w: 0.0378, h: 0.0258),
            L(text: "New Task", x: 0.8141, y: 0.1343, w: 0.0624, h: 0.0234),
            L(text: "Mon 12 Oct 9:41", x: 0.8823, y: 0.0102, w: 0.1003, h: 0.0260),
        ]
        let tasks: [(String, Double, String, Double, String, Double)] = [
            ("Record the launch demo for Friday", 0.2182, "Website", 0.0480, "Fri", 0.0218),
            ("Review onboarding copy", 0.1603, "Website", 0.0497, "10:00", 0.0378),
            ("Fix flaky checkout test", 0.1468, "Mobile", 0.0407, "11:30", 0.0378),
            ("Draft Q4 roadmap one-pager", 0.1875, "Planning", 0.0539, "13:00", 0.0407),
            ("Interview: product designer", 0.1788, "Hiring", 0.0378, "15:00", 0.0378),
            ("Send weekly update", 0.1323, "Planning", 0.0527, "17:00", 0.0378),
            ("Update pricing page screenshots", 0.2122, "Website", 0.0480, "Tomorrow", 0.0644),
            ("Triage crash reports", 0.1308, "Mobile", 0.0392, "Tomorrow", 0.0614),
        ]
        for (i, t) in tasks.enumerated() {
            let c = 0.3928 + 0.0805 * Double(i)
            lines.append(L(text: t.0, x: 0.0195, y: c - 0.016, w: t.1, h: 0.0320))
            if popover && i == 0 { continue }
            lines.append(L(text: t.2, x: 0.7176 - t.3 / 2, y: c - 0.0135, w: t.3, h: 0.0270))
            lines.append(L(text: t.4, x: 0.8745 - t.5, y: c - 0.0155, w: t.5, h: 0.0310))
        }
        if popover {
            lines += [
                L(text: "Share “Today”", x: 0.5915, y: 0.2117, w: 0.0945, h: 0.0314),
                L(text: "Anyone with the link can view", x: 0.5916, y: 0.2528, w: 0.1657, h: 0.0241),
                L(text: "tasks.app/s/7Hk2pQx9", x: 0.6003, y: 0.3385, w: 0.1323, h: 0.0258),
                L(text: "Copy link", x: 0.8038, y: 0.3385, w: 0.0581, h: 0.0258),
            ]
        }
        return lines
    }

    /// Output seconds. Nothing while the picture zooms (1 to 2 s, 4.25 to 5.5 s).
    static let textLayer = TextLayer(width: 1920, height: 1080, frames: [
        .init(start: 0, end: 0.4, lines: overview(open: 13, popover: false)),
        .init(start: 0.4, end: 1.0, lines: overview(open: 12, popover: false)),
        .init(start: 2.0, end: 2.75, lines: closeUp(popover: false)),
        .init(start: 2.75, end: 4.25, lines: closeUp(popover: true)),
        .init(start: 5.5, end: 5.85, lines: overview(open: 12, popover: true)),
        .init(start: 5.85, end: 8.0, lines: overview(open: 12, popover: false)),
    ])

    static func meta(baseURL: String = "https://pub.example/r/AbC/", video: Bool = true, guide: Bool = true,
                     text: Bool = true) -> ViewerMeta {
        var m = ViewerMeta(id: "AbC", title: "Share a task list", status: .ready,
                           createdAt: Date(timeIntervalSince1970: 1_760_000_000), duration: 8,
                           pageURL: "https://pub.example/r/AbC/", baseURL: baseURL,
                           video: video ? "video.1.mp4" : nil, width: 1920, height: 1080,
                           poster: video ? "poster.1.jpg" : nil, card: "card.jpg",
                           captions: video ? "captions.1.vtt" : nil, captionsLanguage: "en",
                           chapters: video ? [Chapter(time: 0, title: "Finish a task"), Chapter(time: 2, title: "Share the list")] : [],
                           revision: 1)
        if guide { m.guide = ViewerMeta.Guide(steps: steps) }
        if text { m.text = "text.1.json" }
        return m
    }
}

@Suite struct ViewerPageGuideTests {
    /// The meta the page script reads, decoded from the page.
    func embedded(_ html: String) throws -> (json: String, meta: ViewerMeta) {
        let start = try #require(html.range(of: #"<script type="application/json" id="meta">"#)).upperBound
        let end = try #require(html.range(of: "</script>", range: start..<html.endIndex)).lowerBound
        let json = String(html[start..<end])
        return (json, try JSONCoding.decoder.decode(ViewerMeta.self, from: Data(json.utf8)))
    }

    /// The page's own script (the block after the meta).
    func script(_ html: String) throws -> String {
        let meta = try #require(html.range(of: #"<script type="application/json" id="meta">"#))
        let open = try #require(html.range(of: "<script>", range: meta.upperBound..<html.endIndex))
        let close = try #require(html.range(of: "</script>", range: open.upperBound..<html.endIndex))
        return String(html[open.upperBound..<close.lowerBound])
    }

    @Test func guideAndTextLayerReachThePage() throws {
        let html = ViewerPage.html(ViewerFixture.meta())
        let (json, decoded) = try embedded(html)
        #expect(decoded.guide?.steps == ViewerFixture.steps)
        #expect(decoded.text == "text.1.json")
        #expect(json.contains(#""image" : "steps.1/01.jpg""#))
        // The view switch and the two views are in the page, hidden until the script finds steps.
        #expect(html.contains(#"<div class="views" id="views" hidden>"#))
        #expect(html.contains(#"<div class="seg" role="tablist" aria-label="View">"#))
        for (id, panel) in [("tab-video", "stage"), ("tab-guide", "guide-panel"), ("tab-demo", "demo-panel")] {
            #expect(html.contains(#"role="tab" id="\#(id)""#))
            #expect(html.contains(#"aria-controls="\#(panel)""#))
        }
        #expect(html.contains(#"id="guide-panel" role="tabpanel" aria-labelledby="tab-guide" hidden>"#))
        #expect(html.contains(#"id="demo-panel" role="tabpanel" aria-labelledby="tab-demo" hidden>"#))
        #expect(html.contains(#"id="ocr" type="button" aria-pressed="false" title="Copy text (T)" aria-label="Copy text" hidden>"#))
        #expect(html.contains("Click-through"))
        #expect(!html.contains("{{"))
        // The deep links don't name an element, so opening #guide or #demo doesn't scroll the page.
        #expect(!html.contains(#"id="guide""#) && !html.contains(#"id="demo""#))
    }

    @Test func hostileStepTextAndTitleStayText() throws {
        let evil = "</script><script>alert(1)</script><img src=x onerror=alert(1)> {{META}} {{TITLE}} \u{2028}"
        var m = ViewerFixture.meta()
        m.title = evil
        var steps = ViewerFixture.steps
        steps[0].text = evil
        steps[0].note = evil
        steps[0].section = evil
        steps[3].keys = evil
        steps[1].image = "../../other/secret.jpg"
        m.guide = ViewerMeta.Guide(steps: steps)
        m.text = "https://evil.example/text.1.json"
        let html = ViewerPage.html(m)
        #expect(!html.contains("<script>alert(1)"))
        #expect(!html.contains("<img src=x"))
        // Exactly two scripts: the meta block and the page's own.
        #expect(html.components(separatedBy: "<script").count == 3)
        #expect(html.contains("<title>&lt;/script&gt;&lt;script&gt;alert(1)"))
        // The page gets the text as data, exactly as written; placeholders inside it stay text.
        let (json, decoded) = try embedded(html)
        #expect(!json.contains("\u{2028}"))
        #expect(decoded.guide?.steps[0].text == evil)
        #expect(decoded.guide?.steps[3].keys == evil)
        #expect(decoded.title == evil)
        #expect(json.contains("{{META}} {{TITLE}}"))
        // The page script checks names with the server's rules and only ever sets text.
        let js = try script(html)
        #expect(js.contains(#"const ASSET = /^[A-Za-z0-9][A-Za-z0-9._-]{0,80}(\/[A-Za-z0-9][A-Za-z0-9._-]{0,80}){0,2}$/;"#))
        #expect(js.contains(#"const TEXT_LAYER = /^text\.\d+\.json$/;"#))
        for sink in ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function", "setAttribute(\"on"] {
            #expect(!js.contains(sink), "page script uses \(sink)")
        }
        // No inline handlers in the template's markup (the server's CSP only runs nonce'd scripts).
        let template = ViewerPage.template
        let markup = String(template[..<template.range(of: #"<script type="application/json" id="meta">"#)!.lowerBound])
        #expect(markup.range(of: #"<[^>]*\son[a-z]+\s*="#, options: .regularExpression) == nil)
    }

    @Test func pageWithoutAGuideKeepsTheNewPartsHidden() throws {
        let html = ViewerPage.html(ViewerFixture.meta(guide: false, text: false))
        let (json, decoded) = try embedded(html)
        #expect(decoded.guide == nil && decoded.text == nil)
        #expect(!json.contains(#""guide""#) && !json.contains(#""text""#))
        // Everything the guide and copy text add starts hidden; the stage is the plain player.
        for marker in [
            #"<div class="views" id="views" hidden>"#,
            #"<div class="stage" id="stage">"#,
            #"<video id="v" controls playsinline preload="metadata" poster="https://pub.example/r/AbC/poster.1.jpg"></video>"#,
            #"<div class="tl" id="tl" role="region" aria-label="Text in this frame" hidden></div>"#,
            #"<div class="tl-bar" id="tl-bar" hidden>"#,
            #"aria-label="Copy text" hidden>"#,
            #"id="demo-panel" role="tabpanel" aria-labelledby="tab-demo" hidden>"#,
            #"id="guide-panel" role="tabpanel" aria-labelledby="tab-guide" hidden></section>"#,
            #"<dt id="keys-t" hidden>"#,
            #"<dl id="keys-demo" hidden>"#,
        ] {
            #expect(html.contains(marker), "missing \(marker)")
        }
        // The rest of the page is as before.
        #expect(html.contains(#"<meta property="og:video" content="https://pub.example/r/AbC/video.1.mp4">"#))
        #expect(html.contains(#"<button type="button" id="keys-open" aria-expanded="false" aria-controls="keys">Keyboard shortcuts</button>"#))
        #expect(html.contains("A 0:08 screen recording."))
        // A guide with no steps is no guide.
        var empty = ViewerFixture.meta(text: false)
        empty.guide = ViewerMeta.Guide(steps: [])
        #expect(try embedded(ViewerPage.html(empty)).meta.guide?.steps.isEmpty == true)
    }

    @Test func pageScriptCompiles() throws {
        // JavaScriptCore parses the whole script (every function body) without running it; it needs a DOM to run.
        let js = try script(ViewerPage.html(ViewerFixture.meta()))
        let context = try #require(JSContext())
        context.evaluateScript("(function () {\n" + js + "\n})")
        #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
        // And a script with a syntax error is caught, so the check means something.
        let broken = try #require(JSContext())
        broken.evaluateScript("(function () {\n" + js.replacingOccurrences(of: "function setView(name, fromHash) {", with: "function setView(name, fromHash) {{") + "\n})")
        #expect(broken.exception != nil)
    }

    @Test func textLayerFixtureMatchesTheSchema() throws {
        // The page reads TextLayer's JSON as written by the app: version, width, height, frames of lines.
        let data = try JSONEncoder().encode(ViewerFixture.textLayer)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        let frames = try #require(object["frames"] as? [[String: Any]])
        let line = try #require((frames.first?["lines"] as? [[String: Any]])?.first)
        #expect(Set(line.keys) == ["text", "x", "y", "w", "h"])
        // Sorted and not overlapping, like the app's.
        let layer = ViewerFixture.textLayer
        #expect(zip(layer.frames, layer.frames.dropFirst()).allSatisfy { $0.end <= $1.start })
        for frame in layer.frames {
            for l in frame.lines { #expect(l.x >= 0 && l.y >= 0 && l.x + l.w <= 1.0001 && l.y + l.h <= 1.0001, "\(l.text)") }
        }
    }
}

// MARK: - Preview folder for checking the page by eye

/// `RB_VIEWER_PREVIEW_DIR=/path scripts/test.sh --filter ViewerPagePreview` writes a folder to serve
/// locally (python3 -m http.server --directory /path): index.html (video, captions, guide, copy text),
/// guide-only.html (a guide without video, as the HTML export makes) and plain.html (no guide).
@Suite struct ViewerPagePreview {
    static let directory = ProcessInfo.processInfo.environment["RB_VIEWER_PREVIEW_DIR"]

    @Test(.enabled(if: ViewerPagePreview.directory != nil, "set RB_VIEWER_PREVIEW_DIR to write the preview folder"))
    func writePreviewFolder() async throws {
        let out = URL(fileURLWithPath: try #require(Self.directory), isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: out.appendingPathComponent("steps.1", isDirectory: true), withIntermediateDirectories: true)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let hero = repo.appendingPathComponent("brand/media/hero.mp4")
        let video = out.appendingPathComponent("video.1.mp4")
        try? fm.removeItem(at: video)
        try fm.copyItem(at: hero, to: video)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: hero))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for (i, time) in ViewerFixture.imageTimes.enumerated() {
            let (frame, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
            let image = try scaled(frame, width: 1600, height: 900) // step images are at most 1600 px wide
            try jpeg(image, to: out.appendingPathComponent(String(format: "steps.1/%02d.jpg", i + 1)))
        }
        let (poster, _) = try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600))
        try jpeg(poster, to: out.appendingPathComponent("poster.1.jpg"))

        try JSONEncoder().encode(ViewerFixture.textLayer).write(to: out.appendingPathComponent("text.1.json"))
        try Data("""
        WEBVTT

        00:00.000 --> 00:02.000
        Tick off the flaky test first.

        00:02.000 --> 00:04.250
        Then share the list and copy its link.

        00:04.250 --> 00:08.000
        Close the popover when you're done.

        """.utf8).write(to: out.appendingPathComponent("captions.1.vtt"))

        let pages: [(String, ViewerMeta)] = [
            ("index.html", ViewerFixture.meta(baseURL: "./")),
            ("guide-only.html", ViewerFixture.meta(baseURL: "./", video: false, text: false)),
            ("plain.html", ViewerFixture.meta(baseURL: "./", guide: false, text: false)),
        ]
        for (name, meta) in pages {
            try Data(ViewerPage.html(meta).utf8).write(to: out.appendingPathComponent(name))
        }
        print("Viewer preview written to \(out.path)")
    }

    func scaled(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    func jpeg(_ image: CGImage, to url: URL) throws {
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
    }
}
