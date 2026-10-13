@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import ReelbirdCore
@testable import ReelbirdRender

func writePNG(_ img: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

/// Renders the realistic demo recording (see `DemoFixture`) with default edit settings into `RB_DEMO_DIR`:
/// MP4s at the source aspect, 16:9, 9:16 and 1:1, a GIF, stills at key moments and motion statistics.
///
///     RB_DEMO_DIR=/path scripts/test.sh --filter demoExports   (a heavy job: about a minute of encoding)
///
/// `RB_DEMO_ONLY=stills` skips the videos; `RB_DEMO_REUSE=1` keeps an existing bundle.
@Test func demoExports() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let dirPath = env["RB_DEMO_DIR"] else { return }
    let dir = URL(fileURLWithPath: dirPath)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let bundleURL = dir.appendingPathComponent("Tasks demo.reelbird")
    let bundle: ProjectBundle
    if env["RB_DEMO_REUSE"] != nil, FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("project.json").path) {
        bundle = ProjectBundle(url: bundleURL)
    } else {
        let clock = ContinuousClock()
        var b: ProjectBundle!
        let took = try await clock.measure { b = try await DemoFixture.makeBundle(at: bundleURL) }
        bundle = b
        print("DEMO bundle built in \(took)")
    }
    let manifest = try bundle.readManifest()
    let edit = EditDocument.initial(for: manifest)
    let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: edit)
    let events = try bundle.readEvents()

    print("DEMO duration \(String(format: "%.2f", plan.duration)) s, \(events.count) events")
    for r in plan.regions {
        print(String(format: "DEMO region %@ %.2f–%.2f scale %.2f focus (%.3f, %.3f)", r.id, r.range.start, r.range.end, r.scale,
                     r.focus?.x ?? -1, r.focus?.y ?? -1))
    }
    for line in MotionReport.lines(plan: plan, events: events) { print("DEMO " + line) }

    // Stills at the moments that matter: before/at/after each click, mid-typing, mid-scroll.
    let sources = try await MediaSources.load(bundle: bundle, manifest: manifest)
    let stills = dir.appendingPathComponent("stills")
    try FileManager.default.createDirectory(at: stills, withIntermediateDirectories: true)
    var moments: [(String, Double)] = []
    for (i, c) in events.filter({ $0.type == .down }).enumerated() {
        moments += [("click\(i + 1)-pre", c.t - 0.5), ("click\(i + 1)-at", c.t + 0.03), ("click\(i + 1)-post", c.t + 0.6)]
    }
    let keys = events.filter { $0.type == .key }
    if let k = keys.dropFirst(keys.count / 2).first { moments.append(("typing", k.t)) }
    if let s = events.first(where: { $0.type == .scroll }) { moments.append(("scroll", s.t + 0.3)) }
    for (name, t) in moments where t >= 0 && t < plan.duration {
        let img = try await Thumbnailer.render(plan: plan, sources: sources, at: t, maxWidth: 1728)
        writePNG(img, to: stills.appendingPathComponent(String(format: "%05.2f-%@.png", t, name)))
    }
    // Full source resolution at the busiest zoomed click, for judging cursor and text crispness.
    if let (_, t) = moments.first(where: { $0.0 == "click7-at" }) {
        writePNG(try await Thumbnailer.render(plan: plan, sources: sources, at: t, maxWidth: 2880), to: stills.appendingPathComponent("full-res-click7.png"))
    }
    for aspect in [CanvasSettings.Aspect.vertical, .square, .wide] {
        var e = edit
        e.canvas.aspect = aspect
        let p = try RenderPlan(bundle: bundle, manifest: manifest, edit: e)
        for (name, t) in moments where name.hasSuffix("-at") || name == "typing" {
            let img = try await Thumbnailer.render(plan: p, sources: sources, at: t, maxWidth: aspect == .vertical ? 1080 : 1440)
            writePNG(img, to: stills.appendingPathComponent(String(format: "%@-%05.2f-%@.png", aspect.rawValue.replacingOccurrences(of: ":", with: "x"), t, name)))
        }
    }
    if env["RB_DEMO_ONLY"] == "stills" { return }

    let outputs: [(String, CanvasSettings.Aspect, ExportOptions)] = [
        ("demo-default-1080p.mp4", .source, ExportOptions(format: .mp4H264, height: 1080)),
        ("demo-16x9-1080p.mp4", .wide, ExportOptions(format: .mp4H264, height: 1080)),
        ("demo-9x16-1080x1920.mp4", .vertical, ExportOptions(format: .mp4H264, height: 1920)),
        ("demo-1x1-1080.mp4", .square, ExportOptions(format: .mp4H264, height: 1080)),
        ("demo.gif", .source, ExportOptions(format: .gif)),
    ]
    for (name, aspect, var options) in outputs {
        var e = edit
        e.canvas.aspect = aspect
        options.destination = dir.appendingPathComponent(name)
        let clock = ContinuousClock()
        let took = try await clock.measure { _ = try await Exporter.export(bundle: bundle, edit: e, options: options) { _ in } }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as? Int) ?? 0
        print(String(format: "DEMO export %@: %.2f s (%.1fx realtime), %.1f MB", name, took.secs, plan.duration / took.secs, Double(bytes) / 1e6))
    }
}

/// Numbers a picky designer would otherwise judge by eye: how fast the camera zooms and pans, how far the
/// smoothed cursor strays from the real one, and whether it lands on clicks.
enum MotionReport {
    static func lines(plan: RenderPlan, events: [InputEvent]) -> [String] {
        var out: [String] = []
        let dt = 1.0 / 120
        var peakZoomRate = 0.0, peakPan = 0.0, peakPanAt = 0.0, peakZoomAt = 0.0
        var prev = plan.camera.transform(at: 0)
        var t = dt
        while t < plan.duration {
            let cur = plan.camera.transform(at: t)
            let zr = abs(log(cur.scale) - log(prev.scale)) / dt
            // Apparent pan speed of the content on screen, in view widths per second.
            let pan = hypot(cur.center.x - prev.center.x, cur.center.y - prev.center.y) * cur.scale / dt
            if zr > peakZoomRate { peakZoomRate = zr; peakZoomAt = t }
            if pan > peakPan { peakPan = pan; peakPanAt = t }
            prev = cur
            t += dt
        }
        out.append(String(format: "camera peak zoom rate %.2f ln/s at %.2f s, peak pan %.2f views/s at %.2f s", peakZoomRate, peakZoomAt, peakPan, peakPanAt))
        // Cursor: lag behind the raw pointer while moving, and error at clicks.
        let raw = CursorPath(events: events, smoothing: 0)
        var maxDev = 0.0, maxDevAt = 0.0
        t = 0
        while t < plan.duration {
            if let a = raw.position(at: t), let b = plan.cursor.position(at: t) {
                let d = hypot((a.x - b.x) * 1440, (a.y - b.y) * 900)
                if d > maxDev { maxDev = d; maxDevAt = t }
            }
            t += dt
        }
        var clickErr = 0.0
        for c in events where c.type == .down {
            if let p = plan.cursor.position(at: c.t), let x = c.x, let y = c.y { clickErr = max(clickErr, hypot((p.x - x) * 1440, (p.y - y) * 900)) }
        }
        out.append(String(format: "cursor max deviation from raw %.1f pt at %.2f s, max click error %.2f pt", maxDev, maxDevAt, clickErr))
        // Click visibility: where each click sits in the view when it happens.
        for c in events where c.type == .down {
            guard let x = c.x, let y = c.y else { continue }
            let v = plan.camera.viewport(at: c.t)
            let u = (x - v.x) / v.width, w = (y - v.y) / v.height
            out.append(String(format: "click %.2f s at view (%.2f, %.2f) zoom %.2f", c.t, u, w, 1 / v.width))
        }
        return out
    }
}
