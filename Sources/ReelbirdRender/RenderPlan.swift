import CoreGraphics
import Foundation
import ReelbirdCore

/// Errors from rendering, preview and export. Messages are written for people.
public enum RenderError: LocalizedError, Equatable {
    case metalUnavailable
    case missingScreenTrack
    case unreadableMedia(String)
    case writerFailed(String)
    case readerFailed(String)
    case nothingToExport

    public var errorDescription: String? {
        switch self {
        case .metalUnavailable: "This Mac has no usable Metal GPU, so Reelbird can't render video."
        case .missingScreenTrack: "This recording has no screen video to render."
        case .unreadableMedia(let s): "Couldn't read the recording's media (\(s))."
        case .writerFailed(let s): "Couldn't write the video file (\(s))."
        case .readerFailed(let s): "Couldn't decode the recording (\(s))."
        case .nothingToExport: "Everything was trimmed or cut, so there's nothing to export."
        }
    }
}

/// One caption cue on the recording timeline.
public struct CaptionCue: Hashable, Sendable {
    public var range: TimeRange
    public var text: String
}

/// Everything needed to draw any output frame, computed once from the bundle, manifest, edit and events.
/// Deterministic: preview and export built from the same inputs draw identical frames.
public final class RenderPlan: Sendable {
    public let bundle: ProjectBundle
    public let manifest: ProjectManifest
    public let edit: EditDocument
    /// Output ↔ recording time mapping (trim + cuts).
    public let timeline: EditTimeline
    /// Effective zoom regions (auto regions regenerated in `.auto` mode, none in `.off`).
    public let regions: [ZoomRegion]
    public let cursor: CursorPath
    public let camera: CameraPath
    /// Default output canvas (from `edit.canvas`).
    public let canvasSize: PixelSize
    /// Default output frame rate.
    public let frameRate: Int
    /// Screen video size in pixels.
    public let sourceSize: PixelSize
    /// Aspect (width / height) of the screen card on the canvas. Equals the source's unless the canvas is
    /// much narrower than the source (a 9:16 or 1:1 export of a landscape screen), where the card becomes a
    /// window onto part of the screen that follows the action.
    public let cardAspect: Double
    /// The part of the source the card shows at zoom 1 (normalized; `(1, 1)` = all of it).
    public let viewBase: SIMD2<Double>
    public let cursorImages: [String: CursorImageInfo]
    public let captions: [CaptionCue]
    let keyEvents: [InputEvent]
    let keyTimes: [Double]
    let captionStarts: [Double]
    /// Whether the camera bubble should be drawn (track recorded and layout visible).
    public let showsCamera: Bool

    /// Output duration in seconds.
    public var duration: Double { timeline.duration }

    /// Builds the plan, reading events, cursor images and captions from the bundle.
    public convenience init(bundle: ProjectBundle, manifest: ProjectManifest, edit: EditDocument) throws {
        try self.init(bundle: bundle, manifest: manifest, edit: edit, events: bundle.readEvents(), reusing: nil)
    }

    /// Builds the plan from already-loaded events. Pass the previous plan as `reusing` to skip rebuilding
    /// the cursor path (when smoothing is unchanged) and reuse cursor metadata and captions.
    init(bundle: ProjectBundle, manifest: ProjectManifest, edit: EditDocument, events: [InputEvent], reusing old: RenderPlan?) throws {
        self.bundle = bundle
        self.manifest = manifest
        self.edit = edit
        let duration = max(manifest.duration, manifest.track(.screen)?.duration ?? 0)
        timeline = EditTimeline(duration: duration, trim: edit.trim, cuts: edit.cuts)
        let screen = manifest.track(.screen)?.pixelSize ?? manifest.capture.pixelSize
        sourceSize = PixelSize(width: max(2, screen.width), height: max(2, screen.height))

        if let old, old.cursor.smoothing == min(1, max(0, edit.cursor.smoothing)) {
            cursor = old.cursor
        } else {
            cursor = CursorPath(events: events, smoothing: edit.cursor.smoothing)
        }
        switch edit.zoom.mode {
        case .off: regions = []
        case .manual: regions = edit.zoom.regions
        case .auto:
            if let old, old.edit.zoom == edit.zoom, old.manifest.duration == manifest.duration {
                regions = old.regions
            } else {
                regions = AutoZoomPlanner.merged(existing: edit.zoom.regions, events: events, duration: duration,
                                                 intensity: edit.zoom.intensity)
            }
        }
        canvasSize = Self.canvasSize(source: sourceSize, aspect: edit.canvas.aspect, height: edit.canvas.outputHeight)
        (cardAspect, viewBase) = Self.cardGeometry(source: sourceSize, canvas: canvasSize, background: edit.background)
        if let old, old.regions == regions, old.cursor.smoothing == cursor.smoothing, old.camera.duration == duration,
           old.camera.base == viewBase {
            camera = old.camera
        } else {
            camera = CameraPath(regions: regions, cursor: cursor, duration: duration, aspect: sourceSize.aspect, base: viewBase)
        }

        frameRate = min(240, max(1, edit.canvas.frameRate ?? manifest.capture.frameRate))

        if let old {
            cursorImages = old.cursorImages
            keyEvents = old.keyEvents
            keyTimes = old.keyTimes
        } else {
            cursorImages = Dictionary(bundle.readCursorImages().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let keys = events.filter { $0.type == .key && !($0.chars ?? "").isEmpty }.sorted { $0.t < $1.t }
            keyEvents = keys
            keyTimes = keys.map(\.t)
        }
        if let old, old.edit.captions == edit.captions {
            captions = old.captions
        } else if let file = edit.captions.file, edit.captions.burnIn,
                  let text = try? String(contentsOf: bundle.resolve(file), encoding: .utf8) {
            captions = WebVTT.parse(text)
        } else {
            captions = []
        }
        captionStarts = captions.map(\.range.start)
        showsCamera = edit.camera.visible && manifest.track(.camera) != nil
    }

    /// Output canvas size for a source and aspect. `height == nil` keeps the source's shorter side.
    public static func canvasSize(source: PixelSize, aspect: CanvasSettings.Aspect, height: Int?) -> PixelSize {
        let ratio: Double
        switch aspect {
        case .source: ratio = source.aspect
        case .wide: ratio = 16.0 / 9.0
        case .vertical: ratio = 9.0 / 16.0
        case .square: ratio = 1
        case .classic: ratio = 4.0 / 3.0
        }
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        if let height, height > 0 {
            return PixelSize(width: even(Double(height) * ratio), height: even(Double(height)))
        }
        if aspect == .source { return PixelSize(width: even(Double(source.width)), height: even(Double(source.height))) }
        let short = Double(min(source.width, source.height))
        return ratio >= 1 ? PixelSize(width: even(short * ratio), height: even(short))
                          : PixelSize(width: even(short), height: even(short / ratio))
    }

    /// The card's aspect and the part of the source it shows at zoom 1.
    ///
    /// When the padded canvas is narrower than 0.8× the source aspect, letterboxing would leave the screen a
    /// thin strip (a 16:10 screen fills under a third of a 9:16 frame). Instead the card's aspect is a
    /// weighted geometric mean, canvas^0.6 · source^0.4: 16:10 → 9:16 gives a 0.82:1 window (51% of the
    /// screen's width, full height, 58% of the frame's height), 16:10 → 1:1 a 1.21:1 window (75%). Text
    /// stays legible on a phone and the camera follows the action.
    static func cardGeometry(source: PixelSize, canvas: PixelSize, background: BackgroundSettings) -> (Double, SIMD2<Double>) {
        let src = source.aspect
        let short = Double(min(canvas.width, canvas.height))
        let pad = background.kind == .none ? 0 : min(0.45, max(0, background.padding)) * short
        let availW = max(1, Double(canvas.width) - 2 * pad), availH = max(1, Double(canvas.height) - 2 * pad)
        let avail = availW / availH
        guard avail / src < 0.8 else { return (src, SIMD2(1, 1)) }
        let card = pow(avail, 0.6) * pow(src, 0.4)
        return (card, SIMD2(card / src, 1))
    }

    /// Recent keystroke text to show at recording time `t`, with its opacity, or `nil`.
    /// A shortcut (⌘/⌃/⌥ held) shows alone; plain typing shows the last few characters.
    func keystrokeText(at t: Double) -> (text: String, opacity: Double)? {
        guard edit.cursor.showKeystrokes, !keyTimes.isEmpty else { return nil }
        var i = upperBoundD(keyTimes, t) - 1
        guard i >= 0 else { return nil }
        let age = t - keyTimes[i]
        let hold = 1.1, fade = 0.25
        guard age <= hold + fade else { return nil }
        let opacity = age <= hold ? 1 : 1 - (age - hold) / fade
        func label(_ e: InputEvent) -> String { (e.mods ?? []).joined() + (e.chars ?? "") }
        func isShortcut(_ e: InputEvent) -> Bool {
            !(e.mods ?? []).filter { $0 != "⇧" && $0 != "shift" }.isEmpty || (e.chars?.count ?? 0) > 1
        }
        let last = keyEvents[i]
        if isShortcut(last) { return (label(last), opacity) }
        var chars: [String] = []
        var prevT = last.t
        while i >= 0, chars.count < 24 {
            let e = keyEvents[i]
            if isShortcut(e) || prevT - e.t > 1.0 { break }
            chars.append(e.chars ?? "")
            prevT = e.t
            i -= 1
        }
        let text = chars.reversed().joined()
        return text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : (text, opacity)
    }

    /// The caption cue active at recording time `t`.
    func caption(at t: Double) -> (index: Int, cue: CaptionCue)? {
        let i = upperBoundD(captionStarts, t) - 1
        guard i >= 0, captions[i].range.contains(t) else { return nil }
        return (i, captions[i])
    }
}

/// Where things sit on the output canvas for a given output size. All sizes scale with the shorter side,
/// so preview (any size) and export (full size) are proportionally identical.
struct CanvasLayout {
    let width: Double
    let height: Double
    var short: Double { min(width, height) }
    /// The screen card at zoom 1, in output pixels (top-left origin).
    let card: CGRect
    /// The part of the source the card shows at zoom 1 (normalized).
    let base: SIMD2<Double>
    /// Output pixels per source pixel at zoom 1.
    let contentScale: Double
    let cornerRadius: Double
    let shadowStrength: Double
    let shadowBlur: Double
    let shadowOffset: Double

    init(plan: RenderPlan, width: Double, height: Double) {
        self.width = width
        self.height = height
        let bg = plan.edit.background
        let short = min(width, height)
        let pad = bg.kind == .none ? 0 : min(0.45, max(0, bg.padding)) * short
        let avail = CGSize(width: max(1, width - 2 * pad), height: max(1, height - 2 * pad))
        let cardAspect = plan.cardAspect
        var w = avail.width, h = avail.width / cardAspect
        if h > avail.height { h = avail.height; w = h * cardAspect }
        card = CGRect(x: (width - w) / 2, y: (height - h) / 2, width: w, height: h)
        base = plan.viewBase
        contentScale = Double(w) / (base.x * Double(plan.sourceSize.width))
        cornerRadius = bg.kind == .none ? 0 : max(0, bg.cornerRadius) * short
        shadowStrength = bg.kind == .none ? 0 : min(1, max(0, bg.shadow))
        // A soft ambient shadow (blur 4.5% of the short side, dropped 1.8%) for depth, plus a tight contact
        // shadow (0.6%) that defines the card's edge on light backgrounds.
        shadowBlur = 0.045 * short
        shadowOffset = 0.018 * short
    }

    /// Output pixel for a normalized source point under camera (scale, centre).
    func map(_ p: NormPoint, scale s: Double, center c: NormPoint) -> CGPoint {
        CGPoint(x: card.minX + card.width * ((p.x - c.x) * s / base.x + 0.5),
                y: card.minY + card.height * ((p.y - c.y) * s / base.y + 0.5))
    }

    /// Output rectangle for a normalized source rectangle.
    func map(_ r: NormRect, scale s: Double, center c: NormPoint) -> CGRect {
        let a = map(NormPoint(x: r.x, y: r.y), scale: s, center: c)
        return CGRect(x: a.x, y: a.y, width: r.width * card.width * s / base.x, height: r.height * card.height * s / base.y)
    }

    /// Source uv for output pixel p: `uv = a + p·b` per axis (a = .xy, b = .zw).
    func uvMap(scale s: Double, center c: NormPoint) -> SIMD4<Float> {
        let bx = base.x / (s * card.width), by = base.y / (s * card.height)
        let ax = c.x - (card.midX) * bx, ay = c.y - (card.midY) * by
        return SIMD4(Float(ax), Float(ay), Float(bx), Float(by))
    }

    /// Whether the card is a window onto part of the source (narrow outputs).
    var crops: Bool { base.x < 0.999 || base.y < 0.999 }

    /// How much the card's frame (corners, shadow) grows at zoom `s`. A full-source card grows with the zoom
    /// and slides off the canvas, so the zoomed screen fills the frame; a cropping card stays a fixed window
    /// and the screen zooms inside it, which keeps a tall output tidy instead of showing the screen's top
    /// edge halfway down the frame.
    func frameGrowth(_ s: Double) -> Double { crops ? 1 : s }

    /// The visible screen card at a camera: the whole source mapped to the canvas, or (when cropping) the
    /// zoom-1 card window.
    func screenRect(scale s: Double, center c: NormPoint) -> CGRect {
        let a = map(NormPoint(x: 0, y: 0), scale: s, center: c), b = map(NormPoint(x: 1, y: 1), scale: s, center: c)
        var x0 = a.x, y0 = a.y, x1 = b.x, y1 = b.y
        if crops {
            x0 = max(x0, card.minX); x1 = min(x1, card.maxX)
            y0 = max(y0, card.minY); y1 = min(y1, card.maxY)
        }
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }
}

@inline(__always) func upperBoundD(_ a: [Double], _ x: Double) -> Int {
    var lo = 0, hi = a.count
    while lo < hi { let m = (lo + hi) >> 1; if a[m] <= x { lo = m + 1 } else { hi = m } }
    return lo
}

/// Minimal WebVTT reader: cue timings and text (tags stripped).
public enum WebVTT {
    public static func parse(_ text: String) -> [CaptionCue] {
        var cues: [CaptionCue] = []
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let ti = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[ti].components(separatedBy: "-->")
            guard parts.count == 2, let a = time(parts[0]), let b = time(parts[1].split(separator: " ").first.map(String.init) ?? "") else { continue }
            let body = lines[(ti + 1)...].joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            if !body.isEmpty { cues.append(CaptionCue(range: TimeRange(start: a, end: b), text: body)) }
        }
        return cues.sorted { $0.range.start < $1.range.start }
    }

    static func time(_ s: String) -> Double? {
        let f = s.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard !f.isEmpty, let sec = Double(f.last!.replacingOccurrences(of: ",", with: ".")) else { return nil }
        var total = sec
        if f.count >= 2, let m = Double(f[f.count - 2]) { total += m * 60 }
        if f.count >= 3, let h = Double(f[f.count - 3]) { total += h * 3600 }
        return total
    }
}
