import CoreGraphics
import Foundation

/// Where the camera bubble sits on the output canvas, and how it gets there.
///
/// A place is `CameraLayout.x` / `y`: 0...1 across the room the bubble can move in, so 0 is against the left
/// (top) edge at the layout's inset, 1 against the right (bottom) edge and 0.5 centred. The four corners are
/// (0, 0), (1, 0), (0, 1) and (1, 1). Because the place is measured in that room, the bubble keeps its spot
/// relative to the frame through any aspect, padding, crop or zoom, and never leaves the canvas. It is an
/// overlay: it does not zoom with the screen.
public enum CameraPlacement {
    /// How long the bubble takes to glide to a new place.
    public static let glideDuration = 0.3
    /// Shape geometry shared by the renderer, the live bubble and the editor.
    /// `roundedSquare` and `portrait` use superellipse corners (exponent 4: continuous curvature where the
    /// curve meets the straight edge, like a macOS app icon) with this radius as a share of the shorter side.
    public static let squircleRadius = 0.31
    public static let squircleExponent = 4.0
    /// `portrait` is 3:4 (width / height).
    public static let portraitAspect = 0.75
    /// A recorded place this close (0...1) to an edge or the centre lands exactly on it.
    static let snapTolerance = 0.02
    /// The sizes the editor offers (`CameraLayout.size`).
    public static let sizeRange = 0.1...0.45

    public static func clampUnit(_ v: Double) -> Double { v.isFinite ? min(1, max(0, v)) : 0.5 }

    /// Moves cleaned for use: finite, places clamped to 0...1, time ≥ 0, sorted by time.
    public static func normalized(_ moves: [CameraLayout.Move]) -> [CameraLayout.Move] {
        moves.filter { $0.t.isFinite }
            .map { CameraLayout.Move(t: max(0, $0.t), x: clampUnit($0.x), y: clampUnit($0.y)) }
            .sorted { $0.t < $1.t }
    }

    // MARK: Shape

    /// Bubble size in output pixels for a canvas whose shorter side is `short`. The portrait tile is 15% taller
    /// than the circle's diameter, so all three shapes cover about the same area.
    public static func bubbleSize(shape: CameraLayout.Shape, size: Double, short: Double) -> (width: Double, height: Double) {
        let d = max(16, size * short)
        switch shape {
        case .circle, .roundedSquare: return (d, d)
        case .portrait:
            let h = d * 1.15
            return (h * portraitAspect, h)
        }
    }

    /// Corner radius and superellipse exponent (2 = a circular arc) for a bubble of this size.
    public static func corner(shape: CameraLayout.Shape, width: Double, height: Double) -> (radius: Double, exponent: Double) {
        let m = min(width, height)
        switch shape {
        case .circle: return (m / 2, 2)
        case .roundedSquare, .portrait: return (m * squircleRadius, squircleExponent)
        }
    }

    /// The bubble's outline as a closed polygon (top-left origin, clockwise from the top edge), for drawing
    /// the same shape outside Metal. `perCorner` points per corner arc.
    public static func outline(shape: CameraLayout.Shape, width w: Double, height h: Double, perCorner: Int = 24) -> [(x: Double, y: Double)] {
        let (r, n) = corner(shape: shape, width: w, height: h)
        let k = max(2, perCorner)
        // Corner centres, going clockwise: top-right, bottom-right, bottom-left, top-left.
        let centres = [(w - r, r, 1.0, -1.0), (w - r, h - r, 1.0, 1.0), (r, h - r, -1.0, 1.0), (r, r, -1.0, -1.0)]
        var pts: [(x: Double, y: Double)] = []
        pts.reserveCapacity(4 * k)
        for (i, c) in centres.enumerated() {
            for j in 0..<k {
                // Sweep from the edge before the corner to the edge after it.
                var a = Double(j) / Double(k - 1) * .pi / 2
                if i % 2 == 0 { a = .pi / 2 - a }
                let cx = pow(max(0, cos(a)), 2 / n), sy = pow(max(0, sin(a)), 2 / n)
                pts.append((c.0 + c.2 * r * cx, c.1 + c.3 * r * sy))
            }
        }
        return pts
    }

    /// The part of a camera frame (normalized u0, v0, u1, v1) shown in a bubble of aspect `bubble` (w / h):
    /// an aspect-fill crop around the centre, so a face in the middle stays in the middle for every shape.
    public static func aspectFill(camera: Double, bubble: Double) -> (u0: Double, v0: Double, u1: Double, v1: Double) {
        guard camera > 0, bubble > 0 else { return (0, 0, 1, 1) }
        if camera > bubble {
            let w = bubble / camera
            return ((1 - w) / 2, 0, (1 + w) / 2, 1)
        }
        let h = camera / bubble
        return (0, (1 - h) / 2, 1, (1 + h) / 2)
    }

    // MARK: Output geometry

    /// The bubble's rectangle on a `width` × `height` canvas (top-left origin, pixels) at a place.
    public static func frame(at p: NormPoint, layout: CameraLayout, width W: Double, height H: Double) -> CGRect {
        let short = min(W, H)
        let (w, h) = bubbleSize(shape: layout.shape, size: layout.size, short: short)
        let inset = max(0, layout.inset) * short
        let x: Double = inset + clampUnit(p.x) * (W - 2 * inset - w)
        let y: Double = inset + clampUnit(p.y) * (H - 2 * inset - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The place whose bubble has its top-left at `origin` (pixels), clamped to the canvas: the inverse of `frame`.
    public static func position(origin: CGPoint, layout: CameraLayout, width W: Double, height H: Double) -> NormPoint {
        let short = min(W, H)
        let (w, h) = bubbleSize(shape: layout.shape, size: layout.size, short: short)
        let inset = max(0, layout.inset) * short
        let rx = W - 2 * inset - w, ry = H - 2 * inset - h
        return NormPoint(x: rx > 0.5 ? clampUnit((origin.x - inset) / rx) : 0.5,
                         y: ry > 0.5 ? clampUnit((origin.y - inset) / ry) : 0.5)
    }

    /// Lines a dragged bubble snaps to.
    public struct Guides: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let left = Guides(rawValue: 1), centerX = Guides(rawValue: 2), right = Guides(rawValue: 4)
        public static let top = Guides(rawValue: 8), centerY = Guides(rawValue: 16), bottom = Guides(rawValue: 32)
    }

    /// A dragged place snapped to the edges and centre lines when its bubble is within `tolerance` pixels of
    /// one, with the lines it snapped to (to show as guides).
    public static func snapped(_ p: NormPoint, layout: CameraLayout, width W: Double, height H: Double,
                               tolerance: Double) -> (position: NormPoint, guides: Guides) {
        let short = min(W, H)
        let (w, h) = bubbleSize(shape: layout.shape, size: layout.size, short: short)
        let inset = max(0, layout.inset) * short
        var guides: Guides = []
        func axis(_ v: Double, room: Double, _ lo: Guides, _ mid: Guides, _ hi: Guides) -> Double {
            guard room > 0.5 else { return 0.5 }
            let tol = tolerance / room
            if v * room <= tolerance { guides.insert(lo); return 0 }
            if (1 - v) * room <= tolerance { guides.insert(hi); return 1 }
            if abs(v - 0.5) <= tol { guides.insert(mid); return 0.5 }
            return v
        }
        let x = axis(clampUnit(p.x), room: W - 2 * inset - w, .left, .centerX, .right)
        let y = axis(clampUnit(p.y), room: H - 2 * inset - h, .top, .centerY, .bottom)
        return (NormPoint(x: x, y: y), guides)
    }

    // MARK: From the recording

    /// The live bubble's frame normalized to the captured area (both in global points, top-left origin),
    /// moved to the nearest place fully inside it. A bubble larger than the area is centred on that axis.
    public static func normalizedBubble(frame f: CGRect, area: CGRect) -> NormRect? {
        guard area.width > 0, area.height > 0, f.width.isFinite, f.height.isFinite, f.minX.isFinite, f.minY.isFinite else { return nil }
        func axis(_ origin: Double, _ size: Double) -> Double {
            size >= 1 ? (1 - size) / 2 : min(max(origin, 0), 1 - size)
        }
        let w = f.width / area.width, h = f.height / area.height
        return NormRect(x: axis((f.minX - area.minX) / area.width, w), y: axis((f.minY - area.minY) / area.height, h),
                        width: w, height: h)
    }

    /// The place for a bubble recorded at `bubble` (normalized to the captured screen, like the event log):
    /// how far it was across the room it could move in on the visible screen (`crop`), measured with the same
    /// proportional inset. So a bubble in a screen corner lands in that canvas corner, centred stays centred,
    /// and one in a cropped-off area goes to the nearest visible place.
    public static func position(recorded bubble: NormRect, screen: PixelSize, crop: CropSpace = .identity,
                                inset: Double = CameraLayout().inset) -> NormPoint {
        let v = crop.toView(bubble)
        let vw = Double(max(1, screen.width)) * crop.rect.width, vh = Double(max(1, screen.height)) * crop.rect.height
        let m = max(0, inset) * min(vw, vh)
        func axis(_ origin: Double, _ size: Double, _ length: Double) -> Double {
            let room = length - 2 * m - size * length
            let f = room > 1 ? (origin * length - m) / room : origin + size / 2
            let c = clampUnit(f)
            if c <= snapTolerance { return 0 }
            if c >= 1 - snapTolerance { return 1 }
            if abs(c - 0.5) <= snapTolerance / 2 { return 0.5 }
            return c
        }
        return NormPoint(x: axis(v.x, v.width, vw), y: axis(v.y, v.height, vh))
    }

    /// The size (`CameraLayout.size`: a share of the shorter side) of a bubble recorded at `bubble` (normalized to
    /// the captured screen) with this shape, measured on the visible screen (`crop`). `nil` for a point (older logs).
    public static func size(recorded bubble: NormRect, shape: CameraLayout.Shape, screen: PixelSize,
                            crop: CropSpace = .identity) -> Double? {
        let v = crop.toView(bubble)
        let vw = Double(max(1, screen.width)) * crop.rect.width, vh = Double(max(1, screen.height)) * crop.rect.height
        let w = v.width * vw, h = v.height * vh
        guard w > 1, h > 1, w.isFinite, h.isFinite else { return nil }
        // Undo `bubbleSize`: the portrait tile is 1.15× the circle's diameter tall.
        let d = shape == .portrait ? h / 1.15 : w
        return d / min(vw, vh)
    }

    /// The screen card's shorter side as a share of the canvas's shorter side, for a canvas with the source's
    /// aspect (the first edit's): 1 without a background, smaller as padding grows. A bubble recorded at a size
    /// relative to the captured screen is scaled by this, so it keeps that size relative to the screen in the video.
    public static func cardScale(source: PixelSize, background: BackgroundSettings) -> Double {
        let W = Double(max(1, source.width)), H = Double(max(1, source.height)), short = min(W, H)
        let pad = background.kind == .none ? 0 : min(0.45, max(0, background.padding)) * short
        let availW = max(1, W - 2 * pad), availH = max(1, H - 2 * pad)
        var w = availW, h = availW * H / W
        if h > availH { h = availH; w = h * W / H }
        return min(w, h) / short
    }

    /// Places the camera from the recording's `camera` events: the first is where it starts, each later one
    /// a move. The shape follows the live bubble's, and the size is the one it had longest (relative to the
    /// captured screen, times `sizeScale`: see `cardScale`). `duration` ends the last size's run (defaults to
    /// the last event). Does nothing without camera events.
    public static func apply(events: [InputEvent], screen: PixelSize, crop: NormRect?, duration: Double? = nil,
                             sizeScale: Double = 1, to layout: inout CameraLayout) {
        let space = CropSpace(crop)
        var places: [(t: Double, p: NormPoint)] = []
        var shape: CameraLayout.Shape?
        var sizes: [(t: Double, size: Double)] = []
        for e in events where e.type == .camera {
            let rect = e.rect ?? e.point.map { NormRect(x: $0.x, y: $0.y, width: 0, height: 0) }
            guard let rect else { continue }
            if let s = e.shape.flatMap(CameraLayout.Shape.init(rawValue:)) { shape = s }
            if let d = size(recorded: rect, shape: shape ?? layout.shape, screen: screen, crop: space) { sizes.append((e.t, d)) }
            let p = position(recorded: rect, screen: screen, crop: space, inset: layout.inset)
            if let last = places.last, abs(last.p.x - p.x) < 1e-3, abs(last.p.y - p.y) < 1e-3 { continue }
            places.append((e.t, p))
        }
        if let shape { layout.shape = shape }
        if !sizes.isEmpty {
            // Time held by each size (sizes within 1% count as one).
            let end = max(duration ?? 0, sizes.last?.t ?? 0)
            var held: [(size: Double, time: Double)] = []
            for (i, s) in sizes.enumerated() {
                let until = i + 1 < sizes.count ? sizes[i + 1].t : end
                let time = max(0, until - s.t) + 1e-6
                if let j = held.firstIndex(where: { abs($0.size - s.size) <= 0.01 * s.size }) { held[j].time += time } else { held.append((s.size, time)) }
            }
            if let best = held.max(by: { $0.time < $1.time }), sizeScale.isFinite, sizeScale > 0 {
                layout.size = min(sizeRange.upperBound, max(sizeRange.lowerBound, best.size * sizeScale))
            }
        }
        guard let first = places.first else { return }
        if let corner = CameraLayout.Corner.allCases.first(where: { $0.position == first.p }) {
            layout.pin(to: corner)
        } else {
            layout.position = first.p
        }
        layout.moves = places.dropFirst().map { CameraLayout.Move(t: $0.t, x: $0.p.x, y: $0.p.y) }
    }
}

/// The bubble's place over recording time: the start place, then an eased glide for each move. Built once;
/// `position(at:)` allocates nothing.
public struct CameraPlacementPath: Hashable, Sendable {
    public let start: NormPoint
    let times: [Double]
    let from: [NormPoint]
    let to: [NormPoint]

    public init(_ layout: CameraLayout) {
        start = layout.position
        let moves = layout.moves
        var times: [Double] = [], from: [NormPoint] = [], to: [NormPoint] = []
        times.reserveCapacity(moves.count); from.reserveCapacity(moves.count); to.reserveCapacity(moves.count)
        for m in moves {
            // A move that starts mid-glide sets off from wherever the bubble is then.
            let here = Self.evaluate(m.t, start: start, times: times, from: from, to: to)
            times.append(m.t); from.append(here); to.append(m.position)
        }
        self.times = times; self.from = from; self.to = to
    }

    public var hasMoves: Bool { !times.isEmpty }

    public func position(at t: Double) -> NormPoint { Self.evaluate(t, start: start, times: times, from: from, to: to) }

    /// Whether the bubble is gliding at `t`.
    public func isMoving(at t: Double) -> Bool {
        let i = Self.upperBound(times, t) - 1
        return i >= 0 && t - times[i] < CameraPlacement.glideDuration
    }

    /// Cubic ease in and out over 0...1.
    public static func ease(_ u: Double) -> Double {
        let x = min(1, max(0, u))
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    private static func evaluate(_ t: Double, start: NormPoint, times: [Double], from: [NormPoint], to: [NormPoint]) -> NormPoint {
        let i = upperBound(times, t) - 1
        guard i >= 0 else { return start }
        let u = (t - times[i]) / CameraPlacement.glideDuration
        guard u < 1 else { return to[i] }
        let e = ease(u), a = from[i], b = to[i]
        return NormPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e)
    }

    private static func upperBound(_ a: [Double], _ x: Double) -> Int {
        var lo = 0, hi = a.count
        while lo < hi { let m = (lo + hi) >> 1; if a[m] <= x { lo = m + 1 } else { hi = m } }
        return lo
    }
}

extension CameraLayout {
    /// The bubble's place over time.
    public var path: CameraPlacementPath { CameraPlacementPath(self) }

    /// The move in effect at recording time `t` (the last one that started), or `nil` before the first.
    public func moveIndex(at t: Double) -> Int? {
        moves.lastIndex { $0.t <= t + 1e-9 }
    }

    /// Sets the place in effect at `t`: the move that started last, or the start place before any move.
    public mutating func setPosition(_ p: NormPoint, at t: Double) {
        let p = NormPoint(x: CameraPlacement.clampUnit(p.x), y: CameraPlacement.clampUnit(p.y))
        if let i = moveIndex(at: t) {
            moves[i].x = p.x
            moves[i].y = p.y
        } else {
            position = p
        }
    }
}
