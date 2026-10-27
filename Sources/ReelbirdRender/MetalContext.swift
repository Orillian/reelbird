import AppKit
import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import Metal

/// The GPU device, compiled pipelines and texture cache shared by every compositor in the process.
/// Shaders are compiled once from source on first use.
final class MetalContext: @unchecked Sendable {
    let device: any MTLDevice
    let compositePipeline: any MTLRenderPipelineState
    let spritePipeline: any MTLRenderPipelineState
    let textureCache: CVMetalTextureCache
    /// 1×1 placeholders for unused texture slots.
    let blank: any MTLTexture
    let blankRG: any MTLTexture

    static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: MetalContext?

    /// The shared context, created on first call.
    static func shared() throws -> MetalContext {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let c = try MetalContext()
        cached = c
        return c
    }

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.metalUnavailable }
        self.device = device
        let library: any MTLLibrary
        do {
            let opts = MTLCompileOptions()
            opts.mathMode = .fast
            library = try device.makeLibrary(source: shaderSource, options: opts)
        } catch {
            throw RenderError.writerFailed("shader compile: \(error.localizedDescription)")
        }
        func pipeline(_ v: String, _ f: String, blend: Bool) throws -> any MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: v)
            d.fragmentFunction = library.makeFunction(name: f)
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = Self.pixelFormat
            if blend {
                ca.isBlendingEnabled = true
                ca.rgbBlendOperation = .add
                ca.alphaBlendOperation = .add
                ca.sourceRGBBlendFactor = .one
                ca.sourceAlphaBlendFactor = .one
                ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
                ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        compositePipeline = try pipeline("fullscreen_vertex", "composite_fragment", blend: false)
        spritePipeline = try pipeline("sprite_vertex", "sprite_fragment", blend: true)

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard let cache else { throw RenderError.metalUnavailable }
        textureCache = cache

        func onePixel(_ format: MTLPixelFormat, _ bytes: [UInt8]) -> any MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 1, height: 1, mipmapped: false)
            d.usage = .shaderRead
            let t = device.makeTexture(descriptor: d)!
            bytes.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: bytes.count) }
            return t
        }
        blank = onePixel(.bgra8Unorm, [40, 40, 40, 255])
        blankRG = onePixel(.rg8Unorm, [128, 128])
    }

    /// Wraps one plane of an IOSurface-backed pixel buffer as a texture without copying.
    func texture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat, renderTarget: Bool = false) -> CVMetalTexture? {
        let planar = CVPixelBufferIsPlanar(pb)
        let w = planar ? CVPixelBufferGetWidthOfPlane(pb, plane) : CVPixelBufferGetWidth(pb)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pb, plane) : CVPixelBufferGetHeight(pb)
        var out: CVMetalTexture?
        let attrs: CFDictionary? = renderTarget
            ? [kCVMetalTextureUsage as String: NSNumber(value: MTLTextureUsage([.renderTarget, .shaderRead]).rawValue)] as CFDictionary
            : nil
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pb, attrs, format, w, h, plane, &out)
        return out
    }

    /// Makes a premultiplied BGRA texture (with mipmaps when asked) from a CGImage.
    func texture(from image: CGImage, mipmapped: Bool, queue: any MTLCommandQueue) -> (any MTLTexture)? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return texture(fromContext: ctx, mipmapped: mipmapped, queue: queue)
    }

    /// Uploads a premultiplied BGRA bitmap context into a texture.
    func texture(fromContext ctx: CGContext, mipmapped: Bool, queue: any MTLCommandQueue) -> (any MTLTexture)? {
        guard let data = ctx.data else { return nil }
        let w = ctx.width, h = ctx.height
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: mipmapped)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: ctx.bytesPerRow)
        if mipmapped, t.mipmapLevelCount > 1, let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: t)
            blit.endEncoding()
            cb.commit()
        }
        return t
    }
}

/// Draws text (optionally on a pill) into cached textures. Keys include size and colours, so a change
/// re-renders; an LRU bound keeps memory flat.
final class TextCache {
    struct Key: Hashable {
        var text: String
        var fontSize: Int
        var weight: Int
        var color: UInt32
        var pill: UInt32
        var maxWidth: Int
        /// Without a pill, a soft shadow keeps text readable on anything; off for text on a solid backing.
        var shadow = true
    }
    struct Entry { let texture: any MTLTexture; let width: Int; let height: Int }

    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private let limit = 160

    func texture(_ key: Key, context: MetalContext, queue: any MTLCommandQueue) -> Entry? {
        if let e = entries[key] {
            if let i = order.firstIndex(of: key) { order.remove(at: i); order.append(key) }
            return e
        }
        guard let e = Self.render(key, context: context, queue: queue) else { return nil }
        entries[key] = e
        order.append(key)
        if order.count > limit { entries[order.removeFirst()] = nil }
        return e
    }

    static func rgba(_ v: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((v >> 24) & 0xff) / 255, green: CGFloat((v >> 16) & 0xff) / 255,
                blue: CGFloat((v >> 8) & 0xff) / 255, alpha: CGFloat(v & 0xff) / 255)
    }

    /// The laid-out text, its padding and the label's whole size in pixels.
    private static func layout(text: String, fontSize: Int, weight: Int, color: UInt32, pill: Bool, maxWidth: Int)
        -> (setter: CTFramesetter, fit: CGSize, padX: CGFloat, padY: CGFloat, w: Int, h: Int) {
        let size = CGFloat(max(4, fontSize))
        let nsWeight: NSFont.Weight = weight >= 800 ? .heavy : weight >= 700 ? .bold : weight >= 600 ? .semibold : (weight >= 500 ? .medium : .regular)
        let font = NSFont.systemFont(ofSize: size, weight: nsWeight) as CTFont
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): rgba(color),
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let setter = CTFramesetterCreateWithAttributedString(str)
        let padX = pill ? size * 0.75 : size * 0.15
        let padY = pill ? size * 0.45 : size * 0.15
        let maxW = maxWidth > 0 ? CGFloat(maxWidth) - 2 * padX : CGFloat.greatestFiniteMagnitude
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                               CGSize(width: maxW, height: .greatestFiniteMagnitude), nil)
        let w = Int((fit.width + 2 * padX).rounded(.up)) + 2
        let h = Int((fit.height + 2 * padY).rounded(.up)) + 2
        return (setter, fit, padX, padY, w, h)
    }

    /// Width in pixels of a space in the system font at this size and weight.
    static func spaceAdvance(fontSize: Double, weight: Int) -> Double {
        let a = labelSize(text: "a a", fontSize: fontSize, weight: weight, pill: false, maxWidth: 0)
        let b = labelSize(text: "aa", fontSize: fontSize, weight: weight, pill: false, maxWidth: 0)
        return Double(max(1, a.width - b.width))
    }

    /// Pixel size of a label as `texture` would draw it.
    static func labelSize(text: String, fontSize: Double, weight: Int, pill: Bool, maxWidth: Int) -> (width: Int, height: Int) {
        let l = layout(text: text, fontSize: Int(fontSize.rounded()), weight: weight, color: 0xFFFFFFFF, pill: pill, maxWidth: maxWidth)
        return (l.w, l.h)
    }

    private static func render(_ key: Key, context: MetalContext, queue: any MTLCommandQueue) -> Entry? {
        let size = CGFloat(max(4, key.fontSize))
        let (setter, fit, padX, padY, w, h) = layout(text: key.text, fontSize: key.fontSize, weight: key.weight, color: key.color,
                                                     pill: key.pill != 0, maxWidth: key.maxWidth)
        guard w > 0, h > 0, w < 16384, h < 16384,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        if key.pill != 0 {
            let r = min(CGFloat(h) / 2, size * 0.9)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 1, y: 1, width: w - 2, height: h - 2), cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.setFillColor(rgba(key.pill))
            ctx.fillPath()
        } else if key.shadow {
            ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.05), blur: size * 0.15, color: CGColor(gray: 0, alpha: 0.5))
        }
        let path = CGPath(rect: CGRect(x: padX + 1, y: padY + 1, width: fit.width + 1, height: fit.height), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
        guard let t = context.texture(fromContext: ctx, mipmapped: true, queue: queue) else { return nil }
        return Entry(texture: t, width: w, height: h)
    }
}

/// The built-in arrow cursor, used when the recording has no cursor images.
enum DefaultCursor {
    /// Size in points and hot spot in normalized image coordinates.
    static let pointSize = CGSize(width: 24, height: 24)
    static let hotSpot = CGPoint(x: 3.0 / 24.0, y: 3.0 / 24.0)

    static func image(scale: Int = 4) -> CGImage? {
        let w = Int(pointSize.width) * scale, h = Int(pointSize.height) * scale
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        // Flip to top-left origin.
        ctx.translateBy(x: 0, y: pointSize.height)
        ctx.scaleBy(x: 1, y: -1)
        let pts: [CGPoint] = [CGPoint(x: 3, y: 3), CGPoint(x: 3, y: 19.5), CGPoint(x: 7, y: 15.8), CGPoint(x: 10, y: 22.4),
                              CGPoint(x: 12.7, y: 21.3), CGPoint(x: 9.8, y: 14.8), CGPoint(x: 15, y: 14.8)]
        let path = CGMutablePath()
        path.addLines(between: pts)
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(2.2)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        return ctx.makeImage()
    }
}
