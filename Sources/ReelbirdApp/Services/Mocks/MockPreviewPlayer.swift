import AppKit
import QuartzCore
import ReelbirdCore

/// Stand-in for `ReelbirdRender.PreviewPlayer`: draws the edit with Core Graphics (background,
/// padded rounded screen, zoom, cursor, clicks, camera bubble, captions) so the editor behaves
/// like the real thing.
@MainActor final class MockPreviewPlayer: PreviewPlayerHandle {
    private let canvas: MockPreviewView
    private var timeline: EditTimeline
    private var playing = false
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private(set) var currentTime: Double = 0
    var onTimeChange: (@MainActor (Double) -> Void)?
    var onReady: (@MainActor ((any Error)?) -> Void)?
    let sourceDuration: Double

    init(duration: Double, events: [InputEvent], sourceSize: PixelSize, hasCamera: Bool, art: MockArt.Variant = .docs) {
        sourceDuration = duration
        timeline = EditTimeline(duration: duration, trim: nil, cuts: [])
        canvas = MockPreviewView(events: events, sourceSize: sourceSize, hasCamera: hasCamera, art: art)
    }

    var view: NSView { canvas }
    var duration: Double { timeline.duration }

    func setHearOriginal(_ on: Bool) {}
    func voiceStemDidChange() {}

    func update(edit: EditDocument) {
        timeline = EditTimeline(duration: sourceDuration, trim: edit.trim, cuts: edit.cuts)
        canvas.edit = edit
        canvas.sourceTime = timeline.sourceTime(forOutput: currentTime)
        canvas.needsDisplay = true
    }

    func play() {
        guard !playing else { return }
        if currentTime >= duration - 0.05 { seek(to: 0) }
        playing = true
        lastTick = CACurrentMediaTime()
        let l = canvas.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func pause() {
        playing = false
        link?.invalidate()
        link = nil
    }

    func seek(to outputTime: Double) {
        currentTime = min(max(0, outputTime), duration)
        canvas.sourceTime = timeline.sourceTime(forOutput: currentTime)
        canvas.needsDisplay = true
        onTimeChange?(currentTime)
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = now - lastTick
        lastTick = now
        let next = currentTime + dt
        if next >= duration {
            seek(to: duration)
            pause()
        } else {
            seek(to: next)
        }
    }
}

final class MockPreviewView: NSView {
    var edit = EditDocument()
    var sourceTime: Double = 0
    private let events: [InputEvent]
    private let moves: [InputEvent]
    private let clicks: [InputEvent]
    private let sourceSize: PixelSize
    private let hasCamera: Bool
    private let art: MockArt.Variant
    private var cachedScreen: (CGSize, CGImage)?

    init(events: [InputEvent], sourceSize: PixelSize, hasCamera: Bool, art: MockArt.Variant) {
        self.events = events
        self.moves = events.filter { $0.type == .move || $0.type == .down }
        self.clicks = events.filter { $0.type == .down }
        self.sourceSize = sourceSize
        self.hasCamera = hasCamera
        self.art = art
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private var crop: CropSpace { CropSpace(edit.crop) }
    /// Aspect of the visible (cropped) screen.
    private var visibleAspect: Double { sourceSize.aspect * crop.rect.width / crop.rect.height }

    /// Output aspect for the edit's canvas setting.
    var outputAspect: Double {
        switch edit.canvas.aspect {
        case .source: visibleAspect
        case .wide: 16.0 / 9
        case .vertical: 9.0 / 16
        case .square: 1
        case .classic: 4.0 / 3
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Fit the output frame in the view.
        let a = outputAspect
        var frame = bounds
        if bounds.width / bounds.height > a {
            frame.size.width = bounds.height * a
            frame.origin.x = (bounds.width - frame.width) / 2
        } else {
            frame.size.height = bounds.width / a
            frame.origin.y = (bounds.height - frame.height) / 2
        }
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.clip()

        let short = min(frame.width, frame.height)
        let bg = edit.background
        let pad = bg.kind == .none ? 0 : short * bg.padding
        let avail = frame.insetBy(dx: pad, dy: pad)
        var screen = avail
        let sa = visibleAspect
        if avail.width / avail.height > sa {
            screen.size.width = avail.height * sa
            screen.origin.x = avail.midX - screen.width / 2
        } else {
            screen.size.height = avail.width / sa
            screen.origin.y = avail.midY - screen.height / 2
        }

        // Zoom
        let (scale, focus) = zoomState(at: sourceTime)
        ctx.saveGState()
        if scale > 1.001 {
            // Zoom the whole composition towards the focus point, keeping the view inside the frame.
            let px = screen.minX + screen.width * focus.x
            let py = screen.minY + screen.height * focus.y
            let halfW = frame.width / 2 / scale, halfH = frame.height / 2 / scale
            let cx = min(max(px, frame.minX + halfW), frame.maxX - halfW)
            let cy = min(max(py, frame.minY + halfH), frame.maxY - halfH)
            ctx.translateBy(x: frame.midX, y: frame.midY)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -cx, y: -cy)
        }
        drawBackground(ctx, frame)

        let radius = bg.kind == .none ? 0 : short * bg.cornerRadius
        let screenPath = CGPath(roundedRect: screen, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if bg.kind != .none && bg.shadow > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: short * 0.012 * bg.shadow), blur: short * 0.05 * bg.shadow,
                          color: NSColor.black.withAlphaComponent(0.45 * bg.shadow).cgColor)
            ctx.addPath(screenPath); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(screenPath); ctx.clip()
        // The whole screen image, placed so the crop fills the screen rect.
        let full = CGRect(x: screen.minX - crop.rect.x * screen.width / crop.rect.width,
                          y: screen.minY - crop.rect.y * screen.height / crop.rect.height,
                          width: screen.width / crop.rect.width, height: screen.height / crop.rect.height)
        if let img = screenImage(size: full.size) {
            ctx.saveGState()
            ctx.translateBy(x: full.minX, y: full.maxY); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(origin: .zero, size: full.size))
            ctx.restoreGState()
        }
        ctx.restoreGState()

        if edit.cursor.visible, let sp = cursorPosition(at: sourceTime) {
            let p = crop.toView(sp)
            drawClickEffects(ctx, screen: screen)
            if (-0.005...1.005).contains(p.x), (-0.005...1.005).contains(p.y) {
                let pt = CGPoint(x: screen.minX + screen.width * p.x, y: screen.minY + screen.height * p.y)
                drawCursor(ctx, at: pt, size: short * 0.022 * edit.cursor.size)
            }
        }
        ctx.restoreGState() // zoom

        if hasCamera && edit.camera.visible { drawCamera(ctx, frame) }
        drawKeystrokes(ctx, frame)
        drawCaption(ctx, frame)
        ctx.restoreGState()
    }

    private func drawBackground(_ ctx: CGContext, _ r: CGRect) {
        let bg = edit.background
        let colors = bg.colors.map { NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: $0.a).cgColor }
        switch bg.kind {
        case .none:
            ctx.setFillColor(NSColor.black.cgColor); ctx.fill(r)
        case .solid:
            ctx.setFillColor(colors.first ?? NSColor.gray.cgColor); ctx.fill(r)
        case .gradient, .image:
            let cs = bg.kind == .image ? [NSColor(hex: 0x8AA3B8).cgColor, NSColor(hex: 0x3C4F63).cgColor] : colors
            if cs.count >= 2, let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: cs as CFArray, locations: nil) {
                ctx.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
            } else {
                ctx.setFillColor(cs.first ?? NSColor.gray.cgColor); ctx.fill(r)
            }
        }
    }

    private func screenImage(size: CGSize) -> CGImage? {
        let px = CGSize(width: (size.width * 2).rounded(), height: (size.height * 2).rounded())
        if let c = cachedScreen, abs(c.0.width - px.width) < 40 { return c.1 }
        guard px.width > 4, px.height > 4,
              let img = MockArt.image(width: Int(px.width), height: Int(px.height), variant: art) else { return nil }
        cachedScreen = (px, img)
        return img
    }

    func cursorPosition(at t: Double) -> NormPoint? {
        guard !moves.isEmpty else { return nil }
        var lo = 0, hi = moves.count - 1
        if t <= moves[0].t { return moves[0].point }
        if t >= moves[hi].t { return moves[hi].point }
        while hi - lo > 1 { let mid = (lo + hi) / 2; if moves[mid].t <= t { lo = mid } else { hi = mid } }
        guard let a = moves[lo].point, let b = moves[hi].point else { return nil }
        let f = (t - moves[lo].t) / max(1e-6, moves[hi].t - moves[lo].t)
        return NormPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }

    private func zoomState(at t: Double) -> (Double, NormPoint) {
        guard edit.zoom.mode != .off else { return (1, .center) }
        let ease = 0.45
        for r in edit.zoom.regions where t >= r.range.start - ease && t <= r.range.end + ease {
            if edit.zoom.mode == .manual && r.source == .auto { continue }
            let fIn = min(1, max(0, (t - (r.range.start - ease)) / ease))
            let fOut = min(1, max(0, ((r.range.end + ease) - t) / ease))
            let f = min(fIn, fOut)
            let e = f * f * (3 - 2 * f)
            let focus = r.focus ?? cursorPosition(at: t) ?? .center
            return (1 + (r.scale - 1) * e, crop.toView(focus))
        }
        return (1, .center)
    }

    private func drawCursor(_ ctx: CGContext, at p: CGPoint, size s: CGFloat) {
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: 0, y: s * 1.45))
        path.addLine(to: CGPoint(x: s * 0.36, y: s * 1.1))
        path.addLine(to: CGPoint(x: s * 0.62, y: s * 1.62))
        path.addLine(to: CGPoint(x: s * 0.82, y: s * 1.52))
        path.addLine(to: CGPoint(x: s * 0.56, y: s * 1.02))
        path.addLine(to: CGPoint(x: s * 1.02, y: s * 1.02))
        path.closeSubpath()
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.setShadow(offset: CGSize(width: 0, height: s * 0.08), blur: s * 0.25, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(path); ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(max(1, s * 0.09)); ctx.setLineJoin(.round); ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawClickEffects(_ ctx: CGContext, screen: CGRect) {
        guard edit.cursor.clickEffect != .none else { return }
        for c in clicks where sourceTime >= c.t && sourceTime < c.t + 0.5 {
            guard let sp = c.point, crop.contains(sp) else { continue }
            let p = crop.toView(sp)
            let f = (sourceTime - c.t) / 0.5
            let center = CGPoint(x: screen.minX + screen.width * p.x, y: screen.minY + screen.height * p.y)
            let r = min(screen.width, screen.height) * (0.015 + 0.04 * f)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9 * (1 - f)).cgColor)
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.25 * (1 - f)).cgColor)
            ctx.setLineWidth(2)
            let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            if edit.cursor.clickEffect == .ripple { ctx.fillEllipse(in: rect) }
            ctx.strokeEllipse(in: rect)
        }
    }

    private func drawCamera(_ ctx: CGContext, _ frame: CGRect) {
        let cam = edit.camera
        let short = min(frame.width, frame.height)
        let d = short * cam.size
        let inset = short * cam.inset
        var origin = CGPoint(x: frame.maxX - inset - d, y: frame.maxY - inset - d)
        switch cam.corner {
        case .topLeft: origin = CGPoint(x: frame.minX + inset, y: frame.minY + inset)
        case .topRight: origin = CGPoint(x: frame.maxX - inset - d, y: frame.minY + inset)
        case .bottomLeft: origin = CGPoint(x: frame.minX + inset, y: frame.maxY - inset - d)
        case .bottomRight: break
        }
        let rect = CGRect(origin: origin, size: CGSize(width: d, height: d))
        let path = cam.shape == .circle ? CGPath(ellipseIn: rect, transform: nil)
            : CGPath(roundedRect: rect, cornerWidth: d * 0.18, cornerHeight: d * 0.18, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: d * 0.03), blur: d * 0.12, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let v = MockCameraView(frame: rect)
        ctx.translateBy(x: rect.minX, y: rect.minY)
        NSGraphicsContext.saveGraphicsState()
        let flippedCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.current = flippedCtx
        v.frame = CGRect(origin: .zero, size: rect.size)
        v.draw(v.bounds)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    private func drawKeystrokes(_ ctx: CGContext, _ frame: CGRect) {
        guard edit.cursor.showKeystrokes else { return }
        let keys = events.filter { $0.type == .key && sourceTime >= $0.t && sourceTime < $0.t + 1.2 }
        guard !keys.isEmpty else { return }
        let text = keys.suffix(6).map { ($0.mods ?? []).joined() + ($0.chars ?? "") }.joined(separator: " ")
        drawPill(ctx, text: text, in: frame, y: frame.maxY - min(frame.width, frame.height) * 0.12, size: 0.032)
    }

    private func drawCaption(_ ctx: CGContext, _ frame: CGRect) {
        guard edit.captions.file != nil,
              let seg = MockData.transcript.segments.first(where: { $0.range.contains(sourceTime) }) else { return }
        drawPill(ctx, text: seg.text, in: frame, y: frame.maxY - min(frame.width, frame.height) * 0.07, size: 0.034)
    }

    private func drawPill(_ ctx: CGContext, text: String, in frame: CGRect, y: CGFloat, size: CGFloat) {
        let fontSize = min(frame.width, frame.height) * size
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                                                    .foregroundColor: NSColor.white]
        let str = NSAttributedString(string: text, attributes: attrs)
        let sz = str.size()
        let box = CGRect(x: frame.midX - sz.width / 2 - fontSize * 0.6, y: y - sz.height / 2 - fontSize * 0.3,
                         width: sz.width + fontSize * 1.2, height: sz.height + fontSize * 0.6)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: fontSize * 0.4, cornerHeight: fontSize * 0.4, transform: nil))
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
        ctx.fillPath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        str.draw(at: CGPoint(x: box.minX + fontSize * 0.6, y: box.minY + fontSize * 0.3))
        NSGraphicsContext.restoreGraphicsState()
    }
}
