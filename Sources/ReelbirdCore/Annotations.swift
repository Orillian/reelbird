import Foundation

// Annotation geometry and defaults shared by the renderer, the editor, the CLI and MCP.

extension Annotation {
    /// Coral, the default for arrows, boxes and text.
    public static let defaultColor = RGBA(1, 90.0 / 255, 54.0 / 255)

    /// The colours the editor offers (coral first). Any colour works in `edit.json`.
    public static let palette: [(name: String, color: RGBA)] = [
        ("Coral", defaultColor),
        ("Sun", RGBA(hex: "#FFB627")!),
        ("Harbor", RGBA(hex: "#2F7DE1")!),
        ("Ink", RGBA(hex: "#1A1512")!),
        ("White", RGBA(1, 1, 1)),
    ]

    /// Default blur strength.
    public static let defaultStrength = 0.5
    /// Shortest an overlay can be, in seconds.
    public static let minimumDuration = 0.2

    public var blurStyle: BlurStyle { style ?? .blur }
    public var blurStrength: Double { min(1, max(0, strength ?? Self.defaultStrength)) }

    /// The area at recording time `t`. Without keys, `rect`. With keys: the first or last key's area outside
    /// them, and between two keys the area covering both (so text moving between two samples stays hidden).
    /// Allocation-free (per-frame render code calls it).
    public func rect(at t: Double) -> NormRect {
        guard let keys, let first = keys.first else { return rect }
        if t <= first.t { return first.rect }
        var lo = 0, hi = keys.count
        while lo < hi { let m = (lo + hi) >> 1; if keys[m].t <= t { lo = m + 1 } else { hi = m } }
        let i = lo - 1
        guard i + 1 < keys.count else { return keys[keys.count - 1].rect }
        let a = keys[i].rect, b = keys[i + 1].rect
        return a == b ? a : a.union(b)
    }

    /// The area a blur's cell size is measured from: steady over time, so cells don't change size as text moves.
    public var blurReferenceRect: NormRect { keys?.first?.rect ?? rect }

    /// Arrow ends (tail, head) in normalized screen coordinates.
    public var arrowEnds: (tail: NormPoint, head: NormPoint) {
        (tail ?? NormPoint(x: rect.x, y: rect.y), head ?? NormPoint(x: rect.x + rect.width, y: rect.y + rect.height))
    }

    /// Text letter size as a fraction of the screen video's height.
    public var textSize: Double { fontSize ?? rect.height * 0.7 }

    /// Moves and resizes the annotation so that `rect` becomes `newRect`, carrying keys and arrow ends along.
    public mutating func setRect(_ newRect: NormRect) {
        let old = rect
        func map(_ p: NormPoint) -> NormPoint {
            NormPoint(x: newRect.x + (old.width > 1e-9 ? (p.x - old.x) / old.width * newRect.width : 0),
                      y: newRect.y + (old.height > 1e-9 ? (p.y - old.y) / old.height * newRect.height : 0))
        }
        func map(_ r: NormRect) -> NormRect {
            let a = map(NormPoint(x: r.x, y: r.y)), b = map(NormPoint(x: r.x + r.width, y: r.y + r.height))
            return NormRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        }
        if let k = keys { keys = k.map { Key(t: $0.t, rect: map($0.rect)) } }
        if kind == .arrow {
            let e = arrowEnds
            tail = map(e.tail)
            head = map(e.head)
        }
        if kind == .text, let f = fontSize, old.height > 1e-9 { fontSize = f * newRect.height / old.height }
        rect = newRect
    }

    /// Sets an arrow's ends; `rect` becomes their bounding box.
    public mutating func setArrow(tail t: NormPoint, head h: NormPoint) {
        tail = t
        head = h
        rect = NormRect(x: min(t.x, h.x), y: min(t.y, h.y), width: abs(h.x - t.x), height: abs(h.y - t.y))
    }

    /// Shifts the whole annotation (range and keys) by `dt` seconds.
    public mutating func shift(by dt: Double) {
        range = TimeRange(start: range.start + dt, end: range.end + dt)
        if let k = keys { keys = k.map { Key(t: $0.t + dt, rect: $0.rect) } }
    }

    /// A short name for lists and the timeline.
    public var title: String {
        switch kind {
        case .blur:
            if let d = detected, let k = SensitiveKind(rawValue: d) { return k.title }
            return blurStyle == .pixelate ? "Pixelate" : "Blur"
        case .arrow: return "Arrow"
        case .box: return "Box"
        case .text: return text.map { $0.isEmpty ? "Text" : $0 } ?? "Text"
        case .highlight: return "Highlight"
        }
    }
}

extension Annotation.Kind {
    public var title: String {
        switch self {
        case .arrow: "Arrow"
        case .box: "Box"
        case .text: "Text"
        case .highlight: "Highlight"
        case .blur: "Blur"
        }
    }
}

/// Privacy blur sizing, shared by the renderer and the editor's stand-in preview.
public enum PrivacyBlur {
    /// Side of one blur cell in screen-video pixels. Cells are anchored to the screen video, so they never
    /// shimmer as the camera zooms or pans, and the output keeps one averaged colour per cell: what was under
    /// it can't be recovered. The floor (9 to 18 points) is larger than the capital letters of body text, and
    /// the cell also grows with the area (a quarter to half of its shorter side), so headings inside a tight
    /// box disappear too.
    public static func cellPixels(shortSidePixels: Double, strength: Double, captureScale: Double) -> Double {
        let s = min(1, max(0, strength.isFinite ? strength : Annotation.defaultStrength))
        let floorPoints = 9 + 9 * s
        let fraction = 0.25 + 0.25 * s
        return max(floorPoints * max(1, captureScale), fraction * max(0, shortSidePixels))
    }
}

extension NormRect {
    /// The smallest rectangle containing both.
    public func union(_ o: NormRect) -> NormRect {
        // Exactly one of the two when it holds the other (no rounding drift for repeated unions).
        if o.x >= x, o.y >= y, o.x + o.width <= x + width, o.y + o.height <= y + height { return self }
        if x >= o.x, y >= o.y, x + width <= o.x + o.width, y + height <= o.y + o.height { return o }
        let x0 = min(x, o.x), y0 = min(y, o.y)
        let x1 = max(x + width, o.x + o.width), y1 = max(y + height, o.y + o.height)
        return NormRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    public func contains(_ p: NormPoint) -> Bool { p.x >= x && p.x <= x + width && p.y >= y && p.y <= y + height }

    /// Inset by `dx`, `dy` on each side (negative values grow it).
    public func insetBy(dx: Double, dy: Double) -> NormRect {
        NormRect(x: x + dx, y: y + dy, width: max(0, width - 2 * dx), height: max(0, height - 2 * dy))
    }

    /// Clamped into the unit square (at least `minSide` on each side), keeping its size where it fits.
    public func clampedToUnit(minSide: Double = 0.002) -> NormRect {
        let w = min(1, max(minSide, width.isFinite ? width : minSide)), h = min(1, max(minSide, height.isFinite ? height : minSide))
        let nx = min(max(0, x.isFinite ? x : 0), 1 - w), ny = min(max(0, y.isFinite ? y : 0), 1 - h)
        return NormRect(x: nx, y: ny, width: w, height: h)
    }

    /// The rectangle spanned by two corners, in either order.
    public static func spanning(_ a: NormPoint, _ b: NormPoint) -> NormRect {
        NormRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
