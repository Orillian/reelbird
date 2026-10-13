import CoreGraphics
import Foundation
import ReelbirdCore

/// What the camera does during zooms: how far into a zoom the screen is (the bubble shrinks with it, on the
/// same curve), and where the bubble steps aside when the cursor or the zoom's focus would pass under it.
///
/// Built once per plan from the zoom camera's sanitised regions; `progress` and `place` allocate nothing.
struct CameraZoomFraming: Sendable {
    /// Per zoom region: when its zoom starts and ends (transitions included), and ln(its scale).
    let zoomT0: [Double]
    let zoomT1: [Double]
    let zoomLn: [Double]
    /// Glides aside: when they start and end, how long the glide in and out takes, and where the bubble goes.
    let asideT0: [Double]
    let asideT1: [Double]
    let asideGlide: [Double]
    let asideTo: [NormPoint]

    static let empty = CameraZoomFraming(zoomT0: [], zoomT1: [], zoomLn: [], asideT0: [], asideT1: [], asideGlide: [], asideTo: [])

    /// Seconds between the cursor samples tested against the bubble during a zoom.
    static let sampleStep = 1.0 / 15
    /// The bubble counts as covering a point this close to it (share of the canvas's shorter side).
    static let margin = 0.02

    /// How long a zoom region's transitions take (the zoom camera's rule).
    static func transition(_ r: ZoomRegion) -> Double {
        min(Spring.zoomDuration(from: 1, to: r.scale), max(0.3, r.range.duration))
    }

    /// `regions` are the zoom camera's (sanitised, view coordinates). `aside` is nil when smart framing is off.
    init(regions: [ZoomRegion], aside: Aside?) {
        var t0: [Double] = [], t1: [Double] = [], ln: [Double] = []
        for r in regions {
            let d = Self.transition(r)
            t0.append(r.range.start - d / 2); t1.append(r.range.end + d / 2); ln.append(log(max(1.0001, r.scale)))
        }
        zoomT0 = t0; zoomT1 = t1; zoomLn = ln
        var a0: [Double] = [], a1: [Double] = [], ad: [Double] = [], to: [NormPoint] = []
        if let aside {
            for r in regions {
                guard let target = aside.corner(for: r) else { continue }
                let d = Self.transition(r)
                let s = r.range.start - d / 2, e = r.range.end + d / 2
                // Back to back with the same corner: stay there instead of gliding out and in again.
                if let last = to.last, last == target, s <= a1[a1.count - 1] + d {
                    a1[a1.count - 1] = max(a1[a1.count - 1], e)
                    continue
                }
                a0.append(s); a1.append(e); ad.append(d); to.append(target)
            }
        }
        asideT0 = a0; asideT1 = a1; asideGlide = ad; asideTo = to
    }

    private init(zoomT0: [Double], zoomT1: [Double], zoomLn: [Double], asideT0: [Double], asideT1: [Double],
                 asideGlide: [Double], asideTo: [NormPoint]) {
        self.zoomT0 = zoomT0; self.zoomT1 = zoomT1; self.zoomLn = zoomLn
        self.asideT0 = asideT0; self.asideT1 = asideT1; self.asideGlide = asideGlide; self.asideTo = asideTo
    }

    /// How far into a zoom the screen is at `t` with the zoom camera at `scale`: 0 un-zoomed, 1 at the zoom's
    /// depth. ln(scale) / ln(depth), so it follows the zoom's own curve exactly.
    func progress(at t: Double, scale: Double) -> Double {
        guard scale > 1.0001 else { return 0 }
        var i = upperBoundD(zoomT0, t) - 1
        var ref = Double.infinity
        // Windows only overlap their neighbours (back-to-back zooms).
        let stop = max(0, i - 3)
        while i >= stop {
            if t < zoomT1[i] { ref = min(ref, zoomLn[i]) }
            i -= 1
        }
        guard ref.isFinite, ref > 0 else { return 0 }
        return min(1, max(0, log(scale) / ref))
    }

    /// The bubble's place at `t`, from its place without zooms: gliding aside over each zoom's transition.
    func place(at t: Double, base: NormPoint) -> NormPoint {
        let last = upperBoundD(asideT0, t) - 1
        guard last >= 0 else { return base }
        var p = base
        // From the earliest glide that may still overlap, so a glide into the next corner starts from this one.
        for i in max(0, last - 2)...last where t < asideT1[i] {
            let d = max(1e-3, asideGlide[i])
            let w = Spring.glide(min(1, (t - asideT0[i]) / d, (asideT1[i] - t) / d))
            let q = asideTo[i]
            p = NormPoint(x: p.x + (q.x - p.x) * w, y: p.y + (q.y - p.y) * w)
        }
        return p
    }

    var hasAsides: Bool { !asideT0.isEmpty }

    /// Decides, for each zoom, whether the bubble should step aside and to which corner.
    struct Aside {
        let camera: CameraPath
        let cursor: CursorPath
        let layout: CanvasLayout
        let bubble: CameraLayout
        let path: CameraPlacementPath
        /// The bubble's size during a zoom (share of its size).
        let zoomedScale: Double

        /// The nearest corner where the bubble covers fewer of the zoom's focus points than where it is, or nil
        /// when it covers none (or no corner is better).
        func corner(for r: ZoomRegion) -> NormPoint? {
            let W = layout.width, H = layout.height
            let d = CameraZoomFraming.transition(r)
            var a = r.range.start + d / 2, b = r.range.end - d / 2
            if b < a { a = (r.range.start + r.range.end) / 2; b = a }
            let count = min(400, max(1, Int(((b - a) / CameraZoomFraming.sampleStep).rounded(.up)) + 1))
            var points: [CGPoint] = []
            points.reserveCapacity(count)
            for k in 0..<count {
                let t = count == 1 ? a : a + (b - a) * Double(k) / Double(count - 1)
                guard let p = r.focus ?? cursor.position(at: t) else { continue }
                let (s, c) = camera.transform(at: t)
                points.append(layout.map(p, scale: s, center: layout.fillCenter(scale: s, center: c)))
            }
            guard !points.isEmpty else { return nil }
            let m = CameraZoomFraming.margin * layout.short
            func hits(_ place: NormPoint) -> Int {
                let f = CameraPlacement.frame(at: place, layout: bubble, width: W, height: H, sizeScale: zoomedScale).insetBy(dx: -m, dy: -m)
                return points.reduce(0) { $0 + (f.contains($1) ? 1 : 0) }
            }
            let here = path.position(at: a)
            let now = hits(here)
            guard now > 0 else { return nil }
            var best: (place: NormPoint, hits: Int, distance: Double)?
            for corner in CameraLayout.Corner.allCases {
                let p = corner.position
                if abs(p.x - here.x) < 1e-6, abs(p.y - here.y) < 1e-6 { continue }
                let h = hits(p), dist = hypot((p.x - here.x) * W, (p.y - here.y) * H)
                if best == nil || h < best!.hits || (h == best!.hits && dist < best!.distance) { best = (p, h, dist) }
            }
            guard let best, best.hits < now else { return nil }
            return best.place
        }
    }
}

/// The camera's tile on the canvas: the bubble, the full frame, the split panel, or the bubble stepping away.
public struct CameraTile: Equatable, Sendable {
    public var rect: CGRect
    /// Corner radius (px) and superellipse exponent (2 = circular arcs).
    public var radius: Double
    public var exponent: Double
    public var opacity: Double
    /// Shares of the usual rim and shadow (`CameraBubbleStyle`).
    public var rim: Double
    public var shadow: Double

    func lerp(to b: CameraTile, _ e: Double) -> CameraTile {
        func l(_ x: Double, _ y: Double) -> Double { x + (y - x) * e }
        return CameraTile(rect: CGRect(x: l(rect.minX, b.rect.minX), y: l(rect.minY, b.rect.minY),
                                       width: l(rect.width, b.rect.width), height: l(rect.height, b.rect.height)),
                          radius: l(radius, b.radius), exponent: e < 0.5 ? exponent : b.exponent,
                          opacity: l(opacity, b.opacity), rim: l(rim, b.rim), shadow: l(shadow, b.shadow))
    }
}

/// Where the screen card and the camera panel sit in the Split layout: side by side when the canvas is at least
/// as wide as it is tall (the camera a third of the width on the right), stacked on a taller canvas (the camera
/// below, a third of the height). Both share the padding, a gap between them and the card's corner radius; the
/// panel is as tall (wide) as the card, and the pair is centred.
enum SplitGeometry {
    /// The camera's share of the padded width (side by side) or height (stacked).
    static let cameraShare = 0.34

    static func rects(width W: Double, height H: Double, background bg: BackgroundSettings,
                      cardAspect: Double) -> (card: CGRect, camera: CGRect) {
        let short = min(W, H)
        let pad = bg.kind == .none ? 0 : min(0.45, max(0, bg.padding)) * short
        let gap = max(0.02 * short, pad * 0.5)
        let iw = max(2, W - 2 * pad), ih = max(2, H - 2 * pad)
        let aspect = cardAspect.isFinite && cardAspect > 0 ? cardAspect : 16.0 / 10.0
        if W >= H {
            let camW = iw * cameraShare
            let areaW = max(1, iw - camW - gap)
            var cw = areaW, ch = areaW / aspect
            if ch > ih { ch = ih; cw = ch * aspect }
            let x0 = (W - (cw + gap + camW)) / 2, y0 = (H - ch) / 2
            return (CGRect(x: x0, y: y0, width: cw, height: ch), CGRect(x: x0 + cw + gap, y: y0, width: camW, height: ch))
        }
        let camH = ih * cameraShare
        let areaH = max(1, ih - camH - gap)
        var ch = areaH, cw = areaH * aspect
        if cw > iw { cw = iw; ch = cw / aspect }
        let x0 = (W - cw) / 2, y0 = (H - (ch + gap + camH)) / 2
        return (CGRect(x: x0, y: y0, width: cw, height: ch), CGRect(x: x0, y: y0 + ch + gap, width: cw, height: camH))
    }
}

extension RenderPlan {
    /// The layout at recording time `t` (always the overlay without a camera).
    public func layoutState(at t: Double) -> LayoutTimeline.State {
        showsCamera ? layoutTimeline.state(at: t) : .overlay
    }

    /// How far into a zoom the screen is at recording time `t` (0...1), on the zoom's curve.
    public func zoomProgress(at t: Double) -> Double {
        zoomFraming.progress(at: t, scale: camera.transform(at: t).scale)
    }

    /// The bubble's place at recording time `t`: its place (start plus moves), stepping aside during zooms.
    public func cameraPlace(at t: Double) -> NormPoint {
        zoomFraming.place(at: t, base: cameraPlacement.position(at: t))
    }

    /// The bubble's size at recording time `t` as a share of `camera.size` (smaller during zooms).
    public func cameraSizeScale(at t: Double) -> Double {
        guard edit.camera.shrinkWhenZoomed else { return 1 }
        let p = zoomProgress(at: t)
        return 1 + (edit.camera.sizeWhileZoomed - 1) * p
    }

    /// The camera's tile on a `width` × `height` canvas at recording time `t`, in the layout of that moment
    /// (blended during a change of layout).
    public func cameraTile(at t: Double, width W: Double, height H: Double) -> CameraTile {
        let state = layoutState(at: t)
        let overlay = cameraFrame(at: t, width: W, height: H)
        let exponent = CameraPlacement.corner(shape: edit.camera.shape, width: overlay.width, height: overlay.height).exponent
        func tile(_ k: LayoutSegment.Kind) -> CameraTile {
            switch k {
            case .overlay:
                let r = CameraPlacement.corner(shape: edit.camera.shape, width: overlay.width, height: overlay.height).radius
                return CameraTile(rect: overlay, radius: r, exponent: exponent, opacity: 1, rim: 1, shadow: 1)
            case .screenOnly:
                // Shrinks to 60% about its centre as it fades.
                let r = CameraPlacement.corner(shape: edit.camera.shape, width: overlay.width, height: overlay.height).radius
                let f = overlay.insetBy(dx: overlay.width * 0.2, dy: overlay.height * 0.2)
                return CameraTile(rect: f, radius: r * 0.6, exponent: exponent, opacity: 0, rim: 1, shadow: 1)
            case .fullCamera:
                return CameraTile(rect: CGRect(x: 0, y: 0, width: W, height: H), radius: 0, exponent: exponent, opacity: 1, rim: 0, shadow: 0)
            case .split:
                let g = SplitGeometry.rects(width: W, height: H, background: edit.background, cardAspect: cardAspect)
                let radius = edit.background.kind == .none ? 0 : max(0, edit.background.cornerRadius) * min(W, H)
                return CameraTile(rect: g.camera, radius: radius, exponent: exponent, opacity: 1, rim: 0.6, shadow: 1)
            }
        }
        if state.isSteady { return tile(state.progress >= 1 ? state.to : state.from) }
        return tile(state.from).lerp(to: tile(state.to), state.progress)
    }
}
