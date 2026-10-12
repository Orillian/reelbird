import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
import ReelbirdCore

struct CompositeUniforms {
    var canvas = SIMD4<Float>(), card = SIMD4<Float>(), camera = SIMD4<Float>(), cameraPrev = SIMD4<Float>()
    var shadow = SIMD4<Float>(), bg0 = SIMD4<Float>(), bg1 = SIMD4<Float>(), bg2 = SIMD4<Float>(), bg3 = SIMD4<Float>()
    var bgInfo = SIMD4<Float>(), bgImage = SIMD4<Float>(), screenInfo = SIMD4<Float>()
    var yuv0 = SIMD4<Float>(), yuv1 = SIMD4<Float>(), yuv2 = SIMD4<Float>(), yuvOffset = SIMD4<Float>()
}

struct SpriteUniforms {
    var rect = SIMD4<Float>(), canvas = SIMD4<Float>(), uvRect = SIMD4<Float>(0, 0, 1, 1), color = SIMD4<Float>(1, 1, 1, 1)
    var params = SIMD4<Float>(), params2 = SIMD4<Float>()
    var yuv0 = SIMD4<Float>(), yuv1 = SIMD4<Float>(), yuv2 = SIMD4<Float>(), yuvOffset = SIMD4<Float>()
    var camera = SIMD4<Float>(), card = SIMD4<Float>()
    var mode = SIMD4<Int32>()
}

/// YCbCr → RGB conversion for a decoded frame (matrix and range from the buffer's own attachments).
struct YUVInfo {
    var r0: SIMD4<Float>, r1: SIMD4<Float>, r2: SIMD4<Float>, offset: SIMD4<Float>
    var planeFormats: (MTLPixelFormat, MTLPixelFormat)

    init?(_ pb: CVPixelBuffer) {
        let f = CVPixelBufferGetPixelFormatType(pb)
        let full: Bool
        switch f {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: full = false; planeFormats = (.r8Unorm, .rg8Unorm)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: full = true; planeFormats = (.r8Unorm, .rg8Unorm)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: full = false; planeFormats = (.r16Unorm, .rg16Unorm)
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: full = true; planeFormats = (.r16Unorm, .rg16Unorm)
        default: return nil
        }
        var kr = 0.2126, kb = 0.0722
        if let m = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String {
            if m == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) || m == (kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 as String) {
                kr = 0.299; kb = 0.114
            } else if m == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) {
                kr = 0.2627; kb = 0.0593
            }
        }
        let kg = 1 - kr - kb
        let cs = full ? 1.0 : 255.0 / 224.0
        r0 = SIMD4(1, 0, Float(2 * (1 - kr) * cs), 0)
        r1 = SIMD4(1, Float(-2 * (1 - kb) * kb / kg * cs), Float(-2 * (1 - kr) * kr / kg * cs), 0)
        r2 = SIMD4(1, Float(2 * (1 - kb) * cs), 0, 0)
        offset = SIMD4(full ? 0 : 16.0 / 255.0, 128.0 / 255.0, full ? 1 : 255.0 / 219.0, 1)
    }
}

/// Draws one output frame: background, padded rounded screen with shadow and zoom (plus motion blur),
/// annotations, cursor and click effects, camera bubble, keystrokes and captions.
///
/// Not thread-safe: each pipeline (preview, export, thumbnail) owns one compositor and calls it from one
/// thread. Per-frame work allocates nothing beyond the CoreVideo texture wrappers for the input frames.
final class Compositor {
    let ctx: MetalContext
    let queue: any MTLCommandQueue

    struct CursorSprite { let texture: any MTLTexture; let size: CGSize; let hot: CGPoint }
    private var cursors: [String: CursorSprite?] = [:]
    private var defaultCursor: CursorSprite?
    private var background: (path: String, texture: any MTLTexture)?
    private let text = TextCache()

    init(context: MetalContext, queue: any MTLCommandQueue) {
        ctx = context
        self.queue = queue
    }

    /// Wraps a decoded frame for sampling. Keep the returned objects alive until the GPU finishes.
    struct BoundFrame {
        var t0: any MTLTexture
        var t1: any MTLTexture
        var yuv: YUVInfo?
        var width: Int
        var height: Int
        var keepAlive: [CVMetalTexture]
    }

    func bind(_ pb: CVPixelBuffer) -> BoundFrame? {
        if let info = YUVInfo(pb) {
            guard let y = ctx.texture(pb, plane: 0, format: info.planeFormats.0),
                  let c = ctx.texture(pb, plane: 1, format: info.planeFormats.1),
                  let ty = CVMetalTextureGetTexture(y), let tc = CVMetalTextureGetTexture(c) else { return nil }
            return BoundFrame(t0: ty, t1: tc, yuv: info, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb), keepAlive: [y, c])
        }
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA,
              let t = ctx.texture(pb, plane: 0, format: .bgra8Unorm), let tt = CVMetalTextureGetTexture(t) else { return nil }
        return BoundFrame(t0: tt, t1: ctx.blankRG, yuv: nil, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb), keepAlive: [t])
    }

    /// Encodes the frame at `outputTime` into `target` (inside `viewport`, default the whole texture).
    /// `frameInterval` sets the motion-blur shutter (half a frame). Returns the texture wrappers that must
    /// stay alive until `commandBuffer` completes (the caller usually captures them in a completion handler).
    @discardableResult
    func encode(plan: RenderPlan, outputTime: Double, screen: CVPixelBuffer?, camera: CVPixelBuffer?,
                target: any MTLTexture, viewport: CGRect? = nil, frameInterval: Double,
                commandBuffer: any MTLCommandBuffer) -> [CVMetalTexture] {
        let vp = viewport ?? CGRect(x: 0, y: 0, width: target.width, height: target.height)
        let W = Double(vp.width), H = Double(vp.height)
        let layout = CanvasLayout(plan: plan, width: W, height: H)
        let edit = plan.edit
        let src = plan.timeline.sourceTime(forOutput: outputTime)
        let (s, c) = plan.camera.transform(at: src)

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { return [] }
        enc.setViewport(MTLViewport(originX: vp.minX, originY: vp.minY, width: W, height: H, znear: 0, zfar: 1))

        var keep: [CVMetalTexture] = []
        let screenFrame = screen.flatMap(bind)
        if let f = screenFrame { keep += f.keepAlive }

        // Motion blur: compare against the camera half a frame earlier (same kept segment only).
        var taps: Float = 0
        var prev = (s: s, c: c)
        if edit.background.motionBlur {
            let srcPrev = plan.timeline.sourceTime(forOutput: max(0, outputTime - frameInterval * 0.5))
            if abs((src - srcPrev) - frameInterval * 0.5) < 1e-3 || outputTime < frameInterval {
                let pt = plan.camera.transform(at: srcPrev); prev = (pt.scale, pt.center)
                var maxMove = 0.0
                for corner in [NormPoint(x: 0, y: 0), NormPoint(x: 1, y: 1), NormPoint(x: 0.5, y: 0.5)] {
                    let a = layout.map(corner, scale: s, center: c), b = layout.map(corner, scale: prev.s, center: prev.c)
                    maxMove = max(maxMove, hypot(a.x - b.x, a.y - b.y))
                }
                if maxMove > 1.5 { taps = Float(min(16, max(4, (maxMove / 2).rounded(.up)))) }
            }
        }

        // 1. Background, shadow, screen.
        var u = CompositeUniforms()
        u.canvas = SIMD4(Float(W), Float(H), Float(vp.minX), Float(vp.minY))
        u.card = SIMD4(Float(layout.card.minX), Float(layout.card.minY), Float(layout.card.width), Float(layout.card.height))
        u.camera = SIMD4(Float(s), Float(c.x), Float(c.y), Float(layout.cornerRadius))
        u.cameraPrev = SIMD4(Float(prev.s), Float(prev.c.x), Float(prev.c.y), taps)
        u.shadow = SIMD4(Float(layout.shadowStrength * 0.85), Float(layout.shadowBlur), Float(layout.shadowOffset), 0)
        let colors = edit.background.colors.isEmpty ? [RGBA(0.1, 0.1, 0.1)] : edit.background.colors
        func v4(_ c: RGBA) -> SIMD4<Float> { SIMD4(Float(c.r), Float(c.g), Float(c.b), Float(c.a)) }
        u.bg0 = v4(colors[0]); u.bg1 = v4(colors[min(1, colors.count - 1)])
        u.bg2 = v4(colors[min(2, colors.count - 1)]); u.bg3 = v4(colors[min(3, colors.count - 1)])
        var bgKind: Float = 0
        var bgTex: any MTLTexture = ctx.blank
        switch edit.background.kind {
        case .none: u.bg0 = SIMD4(0, 0, 0, 1)
        case .solid: break
        case .gradient: bgKind = colors.count > 1 ? 1 : 0
        case .image:
            if let t = backgroundTexture(plan) {
                bgKind = 2
                bgTex = t
                let ia = Double(t.width) / Double(t.height), ca = W / H
                u.bgImage = ia > ca ? SIMD4(Float(ca / ia), 1, 0, 0) : SIMD4(1, Float(ia / ca), 0, 0)
            }
        }
        u.bgInfo = SIMD4(bgKind, Float(min(4, colors.count)), 1.5 / 255, 0)
        let footprint = Double(plan.sourceSize.width) / layout.card.width
        u.screenInfo = SIMD4(Float(screenFrame?.width ?? 1), Float(screenFrame?.height ?? 1), screenFrame?.yuv != nil ? 1 : 0, Float(footprint))
        if let y = screenFrame?.yuv { u.yuv0 = y.r0; u.yuv1 = y.r1; u.yuv2 = y.r2; u.yuvOffset = y.offset }
        enc.setRenderPipelineState(ctx.compositePipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
        enc.setFragmentTexture(screenFrame?.t0 ?? ctx.blank, index: 0)
        enc.setFragmentTexture(screenFrame?.t1 ?? ctx.blankRG, index: 1)
        enc.setFragmentTexture(bgTex, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        enc.setRenderPipelineState(ctx.spritePipeline)
        let canvas = SIMD4<Float>(Float(W), Float(H), Float(vp.minX), Float(vp.minY))
        let short = layout.short
        func draw(_ su: inout SpriteUniforms, _ t0: any MTLTexture = ctx.blank, _ t1: any MTLTexture = ctx.blankRG) {
            su.canvas = canvas
            enc.setVertexBytes(&su, length: MemoryLayout<SpriteUniforms>.stride, index: 0)
            enc.setFragmentBytes(&su, length: MemoryLayout<SpriteUniforms>.stride, index: 0)
            enc.setFragmentTexture(t0, index: 0)
            enc.setFragmentTexture(t1, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        func rect(_ r: CGRect) -> SIMD4<Float> { SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)) }
        func premul(_ c: RGBA, _ a: Double = 1) -> SIMD4<Float> {
            let al = Float(c.a * a)
            return SIMD4(Float(c.r) * al, Float(c.g) * al, Float(c.b) * al, al)
        }

        // 2. Annotations (recording timeline).
        for a in edit.annotations where a.range.contains(src) {
            let fadeIn = min(1, (src - a.range.start) / 0.2), fadeOut = min(1, (a.range.end - src) / 0.2)
            let alpha = max(0, min(fadeIn, fadeOut))
            let r = layout.map(a.rect, scale: s, center: c)
            var su = SpriteUniforms()
            switch a.kind {
            case .highlight:
                su.rect = SIMD4(0, 0, Float(W), Float(H))
                su.mode.x = 8
                su.params = SIMD4(Float(r.midX), Float(r.midY), Float(r.width / 2), Float(r.height / 2))
                su.params2 = SIMD4(Float(0.01 * short * s), Float(0.004 * short), 0, 0)
                su.color = SIMD4(0, 0, 0, Float(0.55 * alpha))
                draw(&su)
            case .box:
                let sw = max(2, 0.0045 * short)
                su.rect = rect(r.insetBy(dx: -sw, dy: -sw))
                su.mode.x = 3
                su.params = SIMD4(Float(r.width / 2), Float(r.height / 2), Float(0.008 * short), Float(sw))
                su.color = premul(a.color, alpha)
                draw(&su)
            case .arrow:
                let th = max(2, 0.006 * short), head = th * 4.5
                let q = r.insetBy(dx: -head, dy: -head)
                su.rect = rect(q)
                su.mode.x = 7
                su.params = SIMD4(Float(r.minX - q.minX), Float(r.minY - q.minY), Float(r.maxX - q.minX), Float(r.maxY - q.minY))
                su.params2 = SIMD4(Float(th), Float(head), 0, 0)
                su.color = premul(a.color, alpha)
                draw(&su)
            case .blur:
                guard let f = screenFrame else { continue }
                su.rect = rect(r)
                su.mode.x = 6
                let cellPx = max(8.0, min(r.width, r.height) / 10)
                let cellU = cellPx / (layout.card.width * s)
                su.params = SIMD4(Float(r.width / 2), Float(r.height / 2), Float(0.006 * short), Float(cellU))
                su.params2 = SIMD4(Float(layout.card.width / layout.card.height), 0, 0, 0)
                su.camera = SIMD4(Float(s), Float(c.x), Float(c.y), 0)
                su.card = u.card
                if let y = f.yuv { su.yuv0 = y.r0; su.yuv1 = y.r1; su.yuv2 = y.r2; su.yuvOffset = y.offset }
                su.color = SIMD4(1, 1, 1, Float(alpha))
                draw(&su, f.t0, f.t1)
            case .text:
                guard let str = a.text, !str.isEmpty else { continue }
                // Render at the zoom-1 size ×2 so zooming stays crisp; mipmaps handle shrinking.
                let base = a.rect.height * layout.card.height * 0.7
                let key = TextCache.Key(text: str, fontSize: Int((base * 2).rounded()), weight: 600,
                                        color: packRGBA(a.color), pill: 0, maxWidth: 0)
                guard let e = text.texture(key, context: ctx, queue: queue) else { continue }
                let scale = s / 2
                let tw = Double(e.width) * scale, th = Double(e.height) * scale
                su.rect = SIMD4(Float(r.minX), Float(r.midY - th / 2), Float(tw), Float(th))
                su.mode.x = 0
                su.color = SIMD4(1, 1, 1, Float(alpha))
                draw(&su, e.texture)
            }
        }

        // 3. Cursor and click effects.
        let cursorSettings = edit.cursor
        if cursorSettings.visible, let pos = plan.cursor.position(at: src),
           pos.x > -0.02, pos.x < 1.02, pos.y > -0.02, pos.y < 1.02 {
            let opacity = plan.cursor.opacity(at: src, hideAfter: cursorSettings.hideWhenIdleAfter)
            let sprite = cursorSprite(plan.cursor.imageID(at: src), plan: plan)
            // Points → source pixels → output pixels, enlarged by zoom and the size setting.
            let pxPerPoint = plan.manifest.capture.scale * (layout.card.width / Double(plan.sourceSize.width)) * s * max(0.1, cursorSettings.size)
            var cw = sprite.size.width * pxPerPoint, ch = sprite.size.height * pxPerPoint
            let at = layout.map(pos, scale: s, center: c)
            let ref = max(8, ch)

            var press = 1.0
            plan.cursor.forEachRecentClick(before: src, window: 0.6, limit: 4) { click in
                guard let cp = click.point else { return }
                let age = src - click.t
                let o = layout.map(cp, scale: s, center: c)
                var su = SpriteUniforms()
                su.mode.x = 2
                switch cursorSettings.clickEffect {
                case .none: return
                case .ripple:
                    let p = age / 0.5
                    guard p < 1 else { return }
                    let e = 1 - pow(1 - p, 3)
                    let radius = ref * (0.25 + 0.95 * e)
                    let thick = max(1.5, ref * 0.14 * (1 - p))
                    let alpha = pow(1 - p, 1.5) * opacity
                    let side = (radius + thick * 2 + 2) * 2
                    su.rect = SIMD4(Float(o.x - side / 2), Float(o.y - side / 2), Float(side), Float(side))
                    su.params = SIMD4(Float(radius), Float(thick * 1.9), Float(thick * 0.6), 0)
                    su.color = SIMD4(0, 0, 0, Float(0.22 * alpha))
                    draw(&su)
                    su.params = SIMD4(Float(radius), Float(thick), 0.75, 0)
                    su.color = SIMD4(repeating: Float(0.92 * alpha))
                    draw(&su)
                case .ring:
                    let p = age / 0.4
                    guard p < 1 else { return }
                    let radius = ref * (0.95 - 0.45 * p)
                    let thick = max(1.5, ref * 0.09)
                    let alpha = sin(p * .pi) * opacity
                    let side = (radius + thick * 2 + 2) * 2
                    su.rect = SIMD4(Float(o.x - side / 2), Float(o.y - side / 2), Float(side), Float(side))
                    su.params = SIMD4(Float(radius), Float(thick), 0.75, 0)
                    su.color = SIMD4(Float(1.0 * alpha), Float(0.62 * alpha), Float(0.3 * alpha), Float(alpha))
                    draw(&su)
                case .press:
                    let p = age / 0.25
                    if p < 1 { press = min(press, 1 - 0.2 * sin(p * .pi)) }
                }
            }
            if opacity > 0.001 {
                cw *= press; ch *= press
                let margin = max(2, ch * 0.18)
                let x0 = at.x - sprite.hot.x * cw, y0 = at.y - sprite.hot.y * ch
                var su = SpriteUniforms()
                su.rect = SIMD4(Float(x0 - margin), Float(y0 - margin), Float(cw + 2 * margin), Float(ch + 2 * margin))
                let mu = margin / cw, mv = margin / ch
                su.uvRect = SIMD4(Float(-mu), Float(-mv), Float(1 + mu), Float(1 + mv))
                su.mode.x = 1
                su.params = SIMD4(0, Float(0.06), Float(0.05), 0.35)
                su.color = SIMD4(1, 1, 1, Float(opacity))
                draw(&su, sprite.texture)
            }
        }

        // 4. Camera bubble.
        if plan.showsCamera, let cam = camera.flatMap(bind) {
            keep += cam.keepAlive
            let cl = edit.camera
            let w = max(16, cl.size * short)
            let h = cl.shape == .circle ? w : w * 0.75
            let radius = cl.shape == .circle ? w / 2 : w * 0.14
            let inset = cl.inset * short
            let x: Double = (cl.corner == .topLeft || cl.corner == .bottomLeft) ? inset : W - inset - w
            let y: Double = (cl.corner == .topLeft || cl.corner == .topRight) ? inset : H - inset - h
            var sh = SpriteUniforms()
            let soft = w * 0.06
            sh.rect = SIMD4(Float(x - soft * 2), Float(y - soft * 2 + w * 0.015), Float(w + soft * 4), Float(h + soft * 4))
            sh.mode.x = 4
            sh.params = SIMD4(Float(w / 2), Float(h / 2), Float(radius), Float(soft))
            sh.color = SIMD4(0, 0, 0, 0.32)
            draw(&sh)
            var su = SpriteUniforms()
            su.rect = SIMD4(Float(x), Float(y), Float(w), Float(h))
            su.mode.x = 5
            // Aspect-fill crop of the camera frame.
            let ca = Double(cam.width) / Double(max(1, cam.height)), ba = w / h
            var u0 = 0.0, v0 = 0.0, u1 = 1.0, v1 = 1.0
            if ca > ba { let cw = ba / ca; u0 = (1 - cw) / 2; u1 = u0 + cw } else { let chh = ca / ba; v0 = (1 - chh) / 2; v1 = v0 + chh }
            if cl.mirror { swap(&u0, &u1) }
            su.uvRect = SIMD4(Float(u0), Float(v0), Float(u1), Float(v1))
            su.params = SIMD4(Float(w / 2), Float(h / 2), Float(radius), Float(max(1.5, 0.0035 * short)))
            su.params2 = SIMD4(1, 1, 1, 0.35)
            if let y = cam.yuv { su.yuv0 = y.r0; su.yuv1 = y.r1; su.yuv2 = y.r2; su.yuvOffset = y.offset }
            draw(&su, cam.t0, cam.t1)
        }

        // 5. Captions and keystrokes along the bottom.
        var bottom = H - 0.045 * short
        if let (index, cue) = plan.caption(at: src) {
            let key = TextCache.Key(text: cue.text, fontSize: Int((0.038 * short).rounded()), weight: 500,
                                    color: 0xFFFFFFFF, pill: 0x000000B8, maxWidth: Int(W * 0.8))
            if let e = text.texture(key, context: ctx, queue: queue) {
                _ = index
                var su = SpriteUniforms()
                su.rect = SIMD4(Float((W - Double(e.width)) / 2), Float(bottom - Double(e.height)), Float(e.width), Float(e.height))
                su.color = SIMD4(1, 1, 1, 1)
                draw(&su, e.texture)
                bottom -= Double(e.height) + 0.015 * short
            }
        }
        if let (str, alpha) = plan.keystrokeText(at: src) {
            let key = TextCache.Key(text: str, fontSize: Int((0.034 * short).rounded()), weight: 600,
                                    color: 0xFFFFFFFF, pill: 0x1A1714D9, maxWidth: Int(W * 0.6))
            if let e = text.texture(key, context: ctx, queue: queue) {
                var su = SpriteUniforms()
                su.rect = SIMD4(Float((W - Double(e.width)) / 2), Float(bottom - Double(e.height) - 0.02 * short), Float(e.width), Float(e.height))
                su.color = SIMD4(1, 1, 1, Float(alpha))
                draw(&su, e.texture)
            }
        }

        enc.endEncoding()
        return keep
    }

    private func backgroundTexture(_ plan: RenderPlan) -> (any MTLTexture)? {
        guard let path = plan.edit.background.imagePath else { return nil }
        if let b = background, b.path == path { return b.texture }
        let url = plan.bundle.resolve(path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let t = ctx.texture(from: img, mipmapped: true, queue: queue) else { return nil }
        background = (path, t)
        return t
    }

    private func cursorSprite(_ id: String?, plan: RenderPlan) -> CursorSprite {
        if let id {
            if let cached = cursors[id] { if let c = cached { return c } } else {
                let sprite = loadCursor(id, plan: plan)
                cursors[id] = sprite
                if let sprite { return sprite }
            }
        }
        if let d = defaultCursor { return d }
        let img = DefaultCursor.image()
        let tex = img.flatMap { ctx.texture(from: $0, mipmapped: true, queue: queue) } ?? ctx.blank
        let d = CursorSprite(texture: tex, size: DefaultCursor.pointSize, hot: DefaultCursor.hotSpot)
        defaultCursor = d
        return d
    }

    private func loadCursor(_ id: String, plan: RenderPlan) -> CursorSprite? {
        let url = plan.bundle.cursorsURL.appendingPathComponent("\(id).png")
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let tex = ctx.texture(from: img, mipmapped: true, queue: queue) else { return nil }
        let pw = Double(img.width), ph = Double(img.height)
        if let info = plan.cursorImages[id], info.width > 0, info.height > 0 {
            // Hot spot is in image pixels of the (2x) PNG.
            return CursorSprite(texture: tex, size: CGSize(width: info.width, height: info.height),
                                hot: CGPoint(x: info.hotX / pw, y: info.hotY / ph))
        }
        return CursorSprite(texture: tex, size: CGSize(width: pw / 2, height: ph / 2), hot: .zero)
    }
}

func packRGBA(_ c: RGBA) -> UInt32 {
    func b(_ v: Double) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
    return b(c.r) << 24 | b(c.g) << 16 | b(c.b) << 8 | b(c.a)
}
