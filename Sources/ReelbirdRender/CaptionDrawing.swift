import CoreGraphics
import Foundation
import Metal
import ReelbirdCore

/// What the compositor remembers between frames for captions: where each caption sits when the position is
/// Auto, and the layout of the word group on screen. Both depend only on the plan and the output size.
struct CaptionCache {
    struct Key: Equatable { var plan: ObjectIdentifier; var width: Int; var height: Int }
    var placementKey: Key?
    var onTop: [Bool] = []
    var layoutKey: (key: Key, group: Int)?
    var layout: WordCaptionLayout?
}

/// A word group laid out in lines, in pixels relative to the block's top-left corner (the backing pill).
struct WordCaptionLayout {
    struct Word { var text: String; var inner: CGRect }
    var words: [Word]
    var size: CGSize
    var fontSize: Double
    var weight: Int
    /// Textures are drawn this many times larger and shown shrunk, so Slam's landing stays sharp.
    var superSample: Double
    var padX: Double
    var padY: Double
}

extension Compositor {
    /// Draws the caption for recording time `src`. Returns the new bottom edge for the keystroke overlay
    /// (moved up when the caption sits in the lower half).
    func drawCaptions(plan: RenderPlan, src: Double, width W: Double, height H: Double, layout: CanvasLayout,
                      bottom: Double, draw: (inout SpriteUniforms, any MTLTexture) -> Void) -> Double {
        let settings = plan.edit.captions
        switch settings.style {
        case .none: return bottom
        case .classic: return drawClassicCaption(plan: plan, src: src, width: W, height: H, layout: layout, bottom: bottom, draw: draw)
        default: return drawWordCaption(plan: plan, src: src, width: W, height: H, layout: layout, bottom: bottom, draw: draw)
        }
    }

    // MARK: Classic

    private func drawClassicCaption(plan: RenderPlan, src: Double, width W: Double, height H: Double, layout: CanvasLayout,
                                    bottom: Double, draw: (inout SpriteUniforms, any MTLTexture) -> Void) -> Double {
        guard let (index, cue) = plan.caption(at: src) else { return bottom }
        let s = plan.edit.captions
        let short = min(W, H)
        let key = TextCache.Key(text: cue.text, fontSize: Int((0.038 * short * s.size.scale).rounded()), weight: 500,
                                color: packRGBA(s.palette.text), pill: s.palette.backing.map(packRGBA) ?? 0,
                                maxWidth: Int(W * 0.8))
        guard let e = text.texture(key, context: ctx, queue: queue) else { return bottom }
        let onTop = captionOnTop(plan: plan, width: W, height: H, ranges: plan.captions.map(\.range))
        let y = captionY(blockHeight: Double(e.height), onTop: index < onTop.count && onTop[index], big: false,
                         position: s.position, layout: layout, width: W, height: H, bottom: bottom)
        var su = SpriteUniforms()
        su.rect = SIMD4(Float((W - Double(e.width)) / 2), Float(y), Float(e.width), Float(e.height))
        su.color = SIMD4(1, 1, 1, 1)
        draw(&su, e.texture)
        return y > H / 2 ? min(bottom, y - 0.015 * short) : bottom
    }

    // MARK: Word styles

    private func drawWordCaption(plan: RenderPlan, src: Double, width W: Double, height H: Double, layout canvas: CanvasLayout,
                                 bottom: Double, draw: (inout SpriteUniforms, any MTLTexture) -> Void) -> Double {
        guard let (gi, group) = plan.captionGroup(at: src) else { return bottom }
        let s = plan.edit.captions
        let style = s.style, palette = s.palette
        let short = min(W, H)
        let k = short / 1080
        let big = style.isWordAtATime
        let L = wordLayout(plan: plan, groupIndex: gi, group: group, width: W, height: H)
        let onTop = captionOnTop(plan: plan, width: W, height: H, ranges: plan.captionGroups.map(\.range))
        let baseY = captionY(blockHeight: L.size.height, onTop: gi < onTop.count && onTop[gi], big: big,
                             position: s.position, layout: canvas, width: W, height: H, bottom: bottom)
        let words = group.words
        let t = src

        // Group entrance.
        var alpha = 1.0, dy = 0.0
        switch style {
        case .highlight, .marker:
            let p = easeOut((t - group.range.start) / 0.25)
            alpha = p; dy = (1 - p) * 8 * k
        case .oneWord:
            let p = easeOut((t - group.range.start) / 0.1)
            alpha = p; dy = (1 - p) * 4 * k
        default: break
        }
        guard alpha > 0.001 else { return bottom }
        let origin = CGPoint(x: (W - L.size.width) / 2, y: baseY + dy)
        func place(_ r: CGRect) -> CGRect { r.offsetBy(dx: origin.x, dy: origin.y) }

        // The spoken word: from its start until the next word starts (or a moment after it ends, before a pause).
        func activeIndex() -> Int? {
            guard let i = words.lastIndex(where: { $0.range.start <= t }) else { return nil }
            let next = i + 1 < words.count ? words[i + 1].range.start : nil
            let until = next.map { n in n - words[i].range.end < 0.4 ? n : words[i].range.end + 0.15 } ?? (words[i].range.end + 0.15)
            return t < until ? i : nil
        }

        // Backing pill.
        let groupEmphasis = words.contains(where: \.emphasis)
        if let backing = palette.backing {
            var pill: CGRect? = CGRect(origin: .zero, size: L.size)
            if style == .pop {
                // The pill grows with the words that have appeared.
                let shown = L.words.indices.filter { t >= words[$0].range.start - 0.02 }
                pill = shown.isEmpty ? nil : shown.map { L.words[$0].inner }.reduce(CGRect.null) { $0.union($1) }
                    .insetBy(dx: -L.padX, dy: -L.padY)
            }
            if var r = pill.map(place) {
                if style == .slam {
                    let (scale, shake) = slamMotion(t: t, start: group.range.start, emphasis: groupEmphasis)
                    r = r.applying(CGAffineTransform(translationX: -r.midX, y: -r.midY)
                        .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                        .concatenating(CGAffineTransform(translationX: r.midX + shake * k, y: r.midY)))
                }
                let a = style == .slam ? min(1, max(0, (t - group.range.start + 0.04) / 0.04)) : 1
                fillRoundRect(r, radius: min(r.height / 2, 0.6 * L.fontSize), color: backing, alpha: alpha * a, draw: draw)
            }
        }

        // Marker box: glides from the previous word to the spoken one.
        let active = activeIndex()
        // The spoken word switches to the box's text colour once the box is mostly under it.
        var boxArrived = true
        if style == .marker, let i = active {
            let pad = CGSize(width: 0.12 * L.fontSize, height: 0.04 * L.fontSize)
            let to = L.words[i].inner.insetBy(dx: -pad.width, dy: -pad.height)
            let p = easeOut((t - words[i].range.start) / 0.12)
            boxArrived = p >= 0.6
            var r = to
            if i > 0, words[i].range.start - words[i - 1].range.end < 0.4 {
                let from = L.words[i - 1].inner.insetBy(dx: -pad.width, dy: -pad.height)
                r = CGRect(x: from.minX + (to.minX - from.minX) * p, y: from.minY + (to.minY - from.minY) * p,
                           width: from.width + (to.width - from.width) * p, height: from.height + (to.height - from.height) * p)
            }
            let a = i > 0 && words[i].range.start - words[i - 1].range.end < 0.4 ? 1 : p
            fillRoundRect(place(r), radius: 0.22 * L.fontSize, color: palette.accent, alpha: alpha * a, draw: draw)
        }

        // Words.
        let shadow = palette.backing == nil
        for (i, w) in L.words.enumerated() {
            var color = palette.text, a = alpha, scale = 1.0, ox = 0.0
            switch style {
            case .highlight:
                if i == active { color = palette.accent; scale = 1.04 } else if t < words[i].range.start { a *= 0.72 }
            case .marker:
                if i == active, boxArrived { color = palette.onAccent } else if t < words[i].range.start { a *= 0.72 }
            case .pop:
                let p = (t - words[i].range.start) / 0.18
                guard p > 0 else { continue }
                a *= min(1, p * 1.6)
                scale = 0.85 + 0.15 * backOut(p)
                if words[i].emphasis { color = palette.accent }
            case .oneWord:
                if groupEmphasis { color = palette.accent }
            case .slam:
                let (sc, shake) = slamMotion(t: t, start: group.range.start, emphasis: groupEmphasis)
                scale = sc; ox = shake * k
                a *= min(1, max(0, (t - group.range.start + 0.04) / 0.04))
                if groupEmphasis { color = palette.accent }
            default: break
            }
            // Text on a light accent box or a light pill: no shadow. Bare text keeps a soft one.
            let key = TextCache.Key(text: w.text, fontSize: Int((L.fontSize * L.superSample).rounded()), weight: L.weight,
                                    color: packRGBA(color), pill: 0, maxWidth: 0, shadow: shadow && !(style == .marker && i == active && boxArrived))
            guard a > 0.001, let e = text.texture(key, context: ctx, queue: queue) else { continue }
            let tw = Double(e.width) / L.superSample, th = Double(e.height) / L.superSample
            var r = CGRect(x: w.inner.midX - tw / 2, y: w.inner.midY - th / 2, width: tw, height: th)
            if style == .slam {
                // The whole block scales about its centre, so the words stay together as they land.
                let c = CGPoint(x: L.size.width / 2, y: L.size.height / 2)
                r = r.applying(CGAffineTransform(translationX: -c.x, y: -c.y).concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    .concatenating(CGAffineTransform(translationX: c.x + ox, y: c.y)))
            } else if scale != 1 {
                r = r.insetBy(dx: -tw * (scale - 1) / 2, dy: -th * (scale - 1) / 2)
            }
            var su = SpriteUniforms()
            let ar = place(r)
            su.rect = SIMD4(Float(ar.minX), Float(ar.minY), Float(ar.width), Float(ar.height))
            su.color = SIMD4(1, 1, 1, Float(a))
            draw(&su, e.texture)
        }
        return baseY > H / 2 ? min(bottom, baseY - 0.015 * short) : bottom
    }

    // MARK: Layout

    /// The group laid out in up to a few centred lines no wider than 80% of the frame.
    private func wordLayout(plan: RenderPlan, groupIndex: Int, group: CaptionGroup, width W: Double, height H: Double) -> WordCaptionLayout {
        let key = CaptionCache.Key(plan: ObjectIdentifier(plan), width: Int(W), height: Int(H))
        if let lk = captionCache.layoutKey, lk.key == key, lk.group == groupIndex, let l = captionCache.layout { return l }
        let s = plan.edit.captions
        let short = min(W, H)
        let big = s.style.isWordAtATime
        let fontSize = (big ? 0.0836 : 0.04) * short * s.size.scale
        let weight = big ? 800 : 600
        let ss = s.style == .slam ? 2.0 : 1.0
        let texts = group.words.map { w -> String in
            guard big else { return w.text }
            let trimmed = w.text.trimmingCharacters(in: CharacterSet(charactersIn: ",;:."))
            return s.uppercase ? trimmed.uppercased() : trimmed
        }
        // Texture padding (see TextCache): 0.15 em plus 1 px on each side, at the super-sampled size.
        let texPad = (0.15 * fontSize * ss + 1) / ss
        var sizes: [CGSize] = texts.map { t in
            let l = TextCache.labelSize(text: t, fontSize: fontSize * ss, weight: weight, pill: false, maxWidth: 0)
            return CGSize(width: Double(l.width) / ss - 2 * texPad, height: Double(l.height) / ss - 2 * texPad)
        }
        if sizes.isEmpty { sizes = [.zero] }
        let space = TextCache.spaceAdvance(fontSize: fontSize, weight: weight)
        let lineHeight = sizes.map(\.height).max() ?? fontSize * 1.2
        let padX = 0.55 * fontSize, padY = 0.28 * fontSize
        let maxLine = W * 0.8 - 2 * padX
        var lines: [[Int]] = [[]]
        var lineWidth = 0.0
        for i in texts.indices {
            let w = sizes[i].width
            if !lines[lines.count - 1].isEmpty, lineWidth + space + w > maxLine {
                lines.append([]); lineWidth = 0
            }
            lineWidth += (lines[lines.count - 1].isEmpty ? 0 : space) + w
            lines[lines.count - 1].append(i)
        }
        func width(of line: [Int]) -> Double { line.map { sizes[$0].width }.reduce(0, +) + space * Double(max(0, line.count - 1)) }
        let innerW = lines.map(width).max() ?? 0
        let size = CGSize(width: innerW + 2 * padX, height: lineHeight * Double(lines.count) + 2 * padY)
        var words = texts.map { WordCaptionLayout.Word(text: $0, inner: .zero) }
        for (li, line) in lines.enumerated() {
            var x = padX + (innerW - width(of: line)) / 2
            let y = padY + Double(li) * lineHeight
            for i in line {
                words[i].inner = CGRect(x: x, y: y, width: sizes[i].width, height: lineHeight)
                x += sizes[i].width + space
            }
        }
        let l = WordCaptionLayout(words: words, size: size, fontSize: fontSize, weight: weight, superSample: ss, padX: padX, padY: padY)
        captionCache.layoutKey = (key, groupIndex)
        captionCache.layout = l
        return l
    }

    /// Top edge of a caption block of height `h`.
    private func captionY(blockHeight h: Double, onTop: Bool, big: Bool, position: CaptionSettings.Position,
                          layout: CanvasLayout, width W: Double, height H: Double, bottom: Double) -> Double {
        let short = min(W, H)
        let margin = 0.045 * short
        let gap = H - layout.card.maxY
        let belowFits = gap >= h + 0.06 * short
        let below = layout.card.maxY + (gap - h) / 2
        let bottomY = big ? min(H * 0.80 - h / 2, bottom - h) : bottom - h
        let topY = big ? max(margin, H * 0.20 - h / 2) : margin
        switch position {
        case .bottom: return bottomY
        case .top: return topY
        case .belowVideo: return belowFits ? below : bottomY
        case .auto: return belowFits ? below : (onTop ? topY : bottomY)
        }
    }

    /// For Auto: which captions move to the top because the cursor is in the bottom third of the frame while
    /// they are on screen. Computed once per plan and output size.
    private func captionOnTop(plan: RenderPlan, width W: Double, height H: Double, ranges: [TimeRange]) -> [Bool] {
        guard plan.edit.captions.position == .auto else { return [] }
        let key = CaptionCache.Key(plan: ObjectIdentifier(plan), width: Int(W), height: Int(H))
        if captionCache.placementKey == key, captionCache.onTop.count == ranges.count { return captionCache.onTop }
        var out: [Bool] = []
        out.reserveCapacity(ranges.count)
        for r in ranges {
            var top = false
            var t = r.start
            while t <= r.end, !top {
                if let p = plan.cursor.position(at: t) {
                    let layout = CanvasLayout(plan: plan, width: W, height: H, layout: plan.layoutState(at: t))
                    let (s, rc) = plan.camera.transform(at: t)
                    let at = layout.map(p, scale: s, center: layout.fillCenter(scale: s, center: rc))
                    if at.y > H * 0.62, at.y < H, at.x > 0, at.x < W { top = true }
                }
                t += 0.1
            }
            out.append(top)
        }
        // A single caption between two at the bottom flips only when it is on screen long enough to read.
        for i in out.indices where out[i] && i > 0 && i + 1 < out.count && !out[i - 1] && !out[i + 1] && ranges[i].duration < 0.8 {
            out[i] = false
        }
        captionCache.placementKey = key
        captionCache.onTop = out
        return out
    }

    // MARK: Drawing helpers

    private func fillRoundRect(_ r: CGRect, radius: Double, color: RGBA, alpha: Double,
                               draw: (inout SpriteUniforms, any MTLTexture) -> Void) {
        var su = SpriteUniforms()
        su.rect = SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height))
        su.mode.x = 4
        su.mode.y = 2
        su.params = SIMD4(Float(r.width / 2), Float(r.height / 2), Float(min(radius, min(r.width, r.height) / 2)), 0)
        let a = Float(color.a * alpha)
        su.color = SIMD4(Float(color.r) * a, Float(color.g) * a, Float(color.b) * a, a)
        draw(&su, ctx.blank)
    }

    /// Slam: lands from 1.5× (1.8× for an emphasis word) in 0.12 s, then a two-frame, 3 px shake.
    private func slamMotion(t: Double, start: Double, emphasis: Bool) -> (scale: Double, shake: Double) {
        let dt = t - (start + 0.04)
        let from = emphasis ? 1.8 : 1.5
        let scale = dt >= 0.12 ? 1 : from - (from - 1) * easeOut(max(0, dt) / 0.12)
        let after = dt - 0.12
        let shake = after > 0 && after < 0.066 ? (Int(after * 60) % 2 == 0 ? 3.0 : -3.0) : 0
        return (scale, shake)
    }
}

@inline(__always) private func easeOut(_ x: Double) -> Double {
    let c = min(max(x, 0), 1)
    return 1 - (1 - c) * (1 - c) * (1 - c)
}

/// Overshoots a little and settles (Pop's entrance).
@inline(__always) private func backOut(_ x: Double) -> Double {
    let c = min(max(x, 0), 1), k = 1.7
    return 1 + (k + 1) * pow(c - 1, 3) + k * pow(c - 1, 2)
}
