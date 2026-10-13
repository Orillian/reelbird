import Foundation

// Non-destructive crop: `edit.json → crop` names the part of the screen video that stays visible. Everything
// stored in a project (events, annotation rects, zoom focus points) stays in full-screen coordinates; the
// renderer maps them into the crop's own coordinates ("view space"), so changing the crop never moves an
// annotation off the content it points at.

extension NormRect {
    /// The smallest crop side, as a fraction of the screen (5%).
    public static let minimumCropSide = 0.05

    /// This rectangle as a crop: clamped inside the screen, at least `minimumCropSide` on each side, or `nil`
    /// when it is not a usable crop (non-finite) or keeps the whole screen (no crop).
    public var sanitizedCrop: NormRect? {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else { return nil }
        let m = Self.minimumCropSide
        let x0 = min(1 - m, max(0, x)), y0 = min(1 - m, max(0, y))
        let w = min(1 - x0, max(m, width)), h = min(1 - y0, max(m, height))
        let r = NormRect(x: x0, y: y0, width: w, height: h)
        let eps = 1e-4
        if r.x < eps, r.y < eps, r.width > 1 - eps, r.height > 1 - eps { return nil }
        return r
    }

    /// The overlap of two rectangles, or `nil` when they don't overlap.
    public func intersection(_ o: NormRect) -> NormRect? {
        let x0 = max(x, o.x), y0 = max(y, o.y)
        let x1 = min(x + width, o.x + o.width), y1 = min(y + height, o.y + o.height)
        guard x1 > x0, y1 > y0 else { return nil }
        return NormRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// Decodes `crop` leniently: missing `x`/`y` are 0, missing `width`/`height` reach the right/bottom edge (so
/// `{"y": 0.08}` hides the top 8%), and anything unusable means no crop instead of a document that won't open.
struct LenientCrop: Decodable {
    let rect: NormRect?
    private enum Keys: String, CodingKey { case x, y, width, height }
    init(from decoder: any Decoder) throws {
        guard let c = try? decoder.container(keyedBy: Keys.self) else { rect = nil; return }
        func value(_ k: Keys) -> Double? { (try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil }
        let x = value(.x) ?? 0, y = value(.y) ?? 0
        rect = NormRect(x: x, y: y, width: value(.width) ?? (1 - x), height: value(.height) ?? (1 - y)).sanitizedCrop
    }
}

/// Maps between full-screen normalized coordinates ("source") and the crop's normalized coordinates ("view"):
/// view (0, 0) is the crop's top-left, (1, 1) its bottom-right.
public struct CropSpace: Hashable, Sendable {
    /// The visible part of the screen (`NormRect.full` without a crop).
    public let rect: NormRect

    public init(_ crop: NormRect?) { rect = crop?.sanitizedCrop ?? .full }

    public static let identity = CropSpace(nil)
    public var isIdentity: Bool { rect == .full }

    public func toView(_ p: NormPoint) -> NormPoint {
        NormPoint(x: (p.x - rect.x) / rect.width, y: (p.y - rect.y) / rect.height)
    }

    public func toSource(_ p: NormPoint) -> NormPoint {
        NormPoint(x: rect.x + p.x * rect.width, y: rect.y + p.y * rect.height)
    }

    public func toView(_ r: NormRect) -> NormRect {
        let a = toView(NormPoint(x: r.x, y: r.y))
        return NormRect(x: a.x, y: a.y, width: r.width / rect.width, height: r.height / rect.height)
    }

    public func toSource(_ r: NormRect) -> NormRect {
        let a = toSource(NormPoint(x: r.x, y: r.y))
        return NormRect(x: a.x, y: a.y, width: r.width * rect.width, height: r.height * rect.height)
    }

    /// Pixel size of the visible part of a screen video of `size` (at least 2 × 2).
    public func pixelSize(of size: PixelSize) -> PixelSize {
        guard !isIdentity else { return size }
        return PixelSize(width: max(2, Int((Double(size.width) * rect.width).rounded())),
                         height: max(2, Int((Double(size.height) * rect.height).rounded())))
    }

    /// Whether a source point lies inside the crop.
    public func contains(_ p: NormPoint) -> Bool {
        p.x >= rect.x && p.x <= rect.x + rect.width && p.y >= rect.y && p.y <= rect.y + rect.height
    }

    /// The event log in view coordinates. Pointer positions are mapped (and may fall outside 0...1 while the
    /// pointer is in the cropped-off area, which hides the cursor there); focus rectangles are clipped to the
    /// crop, or dropped when they lie outside it, so typing in a hidden toolbar never frames a zoom on it.
    public func viewEvents(_ events: [InputEvent]) -> [InputEvent] {
        guard !isIdentity else { return events }
        return events.map { e in
            var v = e
            if let x = e.x, let y = e.y {
                let p = toView(NormPoint(x: x, y: y))
                v.x = p.x; v.y = p.y
            }
            if let r = e.rect {
                v.rect = r.intersection(rect).map(toView)
            }
            return v
        }
    }
}

extension AutoZoomPlanner {
    /// Plans zooms inside a crop: events outside it never trigger a zoom, and depth is fitted to the cropped
    /// view. Focus points come back in full-screen coordinates, like every stored region.
    public static func plan(events: [InputEvent], duration: Double, intensity: Double, crop: NormRect?) -> [ZoomRegion] {
        let space = CropSpace(crop)
        guard !space.isIdentity else { return plan(events: events, duration: duration, intensity: intensity) }
        return plan(events: space.viewEvents(events), duration: duration, intensity: intensity).map { r in
            var r = r
            r.focus = r.focus.map(space.toSource)
            return r
        }
    }

    /// `merged(existing:events:duration:intensity:)` inside a crop (see `plan(events:duration:intensity:crop:)`).
    public static func merged(existing: [ZoomRegion], events: [InputEvent], duration: Double, intensity: Double,
                              crop: NormRect?) -> [ZoomRegion] {
        // A zoom turned off stays off (and keeps automatic zooms away from that moment), like a zoom you made.
        let user = existing.filter { $0.source == .user || !$0.enabled }
        let auto = plan(events: events, duration: duration, intensity: intensity, crop: crop)
            .filter { a in !user.contains { $0.range.overlaps(a.range) } }
        return (user + auto).sorted { $0.range.start < $1.range.start }
    }
}

/// `crop-suggestion.json`: the detected browser toolbar (a band at the top of the screen video that stays
/// still while the page below it changes), cached per screen video file.
public struct CropSuggestion: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    /// Confidence at or above which the editor offers "Hide Browser Toolbar".
    public static let goodConfidence = 0.6

    public var version: Int
    /// Bundle-relative screen video the detection ran on, and its size in bytes (the cache key).
    public var file: String
    public var fileSize: Int64
    /// Height of the screen video in pixels.
    public var height: Int
    /// Rows to hide at the top, in pixels of the screen video (0 = nothing found).
    public var topPixels: Int
    /// 0...1: how sure the detector is that the band is a toolbar.
    public var confidence: Double
    /// Seconds the detection took (diagnostics).
    public var seconds: Double?

    public init(version: Int = CropSuggestion.currentVersion, file: String, fileSize: Int64, height: Int, topPixels: Int,
                confidence: Double, seconds: Double? = nil) {
        self.version = version; self.file = file; self.fileSize = fileSize; self.height = height
        self.topPixels = topPixels; self.confidence = confidence; self.seconds = seconds
    }

    /// The top inset as a fraction of the video height.
    public var top: Double { height > 0 ? Double(topPixels) / Double(height) : 0 }
    /// Whether a toolbar was found with good confidence.
    public var isConfident: Bool { topPixels > 0 && confidence >= Self.goodConfidence }
    /// The crop that hides the toolbar, or `nil` when none was found.
    public var crop: NormRect? { topPixels > 0 ? NormRect(x: 0, y: top, width: 1, height: 1 - top).sanitizedCrop : nil }
}

extension ProjectBundle {
    public var cropSuggestionURL: URL { url.appendingPathComponent("crop-suggestion.json") }

    /// The cached suggestion, or `nil` when missing, unreadable, from another version, or made for a different
    /// screen video.
    public func readCropSuggestion(manifest: ProjectManifest) -> CropSuggestion? {
        guard let file = manifest.track(.screen)?.file,
              let d = try? Data(contentsOf: cropSuggestionURL),
              let s = try? JSONCoding.decoder.decode(CropSuggestion.self, from: d),
              s.version == CropSuggestion.currentVersion, s.file == file, s.fileSize == fileSize(file), s.fileSize > 0 else { return nil }
        return s
    }

    public func writeCropSuggestion(_ s: CropSuggestion) throws {
        try JSONCoding.writeAtomically(s, to: cropSuggestionURL)
    }
}

extension CaptureSource {
    /// Apps whose windows have a toolbar above the page worth hiding.
    static let browserWords: Set<String> = ["chrome", "chromium", "safari", "arc", "edge", "firefox", "brave", "dia",
                                            "opera", "vivaldi", "orion", "zen"]

    /// The app's name when this is a window of a web browser (Chrome, Safari, Arc, Edge, Firefox, Brave, Dia,
    /// Opera, Vivaldi, …), else `nil`.
    public var browserAppName: String? {
        guard case .window(_, let app, _) = self else { return nil }
        let words = app.lowercased().split(whereSeparator: { !$0.isLetter })
        return words.contains(where: { Self.browserWords.contains(String($0)) }) ? app : nil
    }
}
