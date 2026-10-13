@preconcurrency import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ReelbirdCore

/// A synthetic screen recording with rendered fake secrets, for Find Sensitive Info tests.
///
/// 1920 × 1200 at 30 fps (a 2× Retina screen: 28 px text is 14 pt):
/// - 0–20 s, a settings page: an email, an OpenAI-style key, a test card number, a phone number, and things that
///   aren't secrets (a date, a version, an order number).
/// - 20–40 s, a deploy log scrolling up at 40 px/s, with a GitHub token and an email in it.
/// - 40–60 s, a dark terminal: an AWS example key, a Slack token, and "Project Bluebird" (a custom word), plus a
///   line typed at 50 s holding a Stripe test key.
/// All keys are documentation examples or made up.
enum SecretFixture {
    struct Truth: Sendable {
        var kind: SensitiveKind
        var text: String
        /// When it is fully on screen.
        var visible: TimeRange
        /// Where it is at time `t` (normalized, top-left origin).
        var rect: @Sendable (Double) -> NormRect
    }

    struct Fixture: Sendable {
        var url: URL
        var seconds: Double
        var width: Int
        var height: Int
        var truth: [Truth]
    }

    static let width = 1920, height = 1200, fps = 30

    /// Built once per test process.
    static func shared(seconds: Double = 60) async throws -> Fixture {
        try await Cache.shared.fixture(seconds: seconds)
    }

    private actor Cache {
        static let shared = Cache()
        private var made: [Double: Fixture] = [:]
        func fixture(seconds: Double) async throws -> Fixture {
            if let f = made[seconds] { return f }
            let f = try await SecretFixture.make(seconds: seconds)
            made[seconds] = f
            return f
        }
    }

    // MARK: Layout

    struct Line {
        var text: String
        var x: Double
        var baseline: Double
        var size: Double
        var mono = false
        var weight: Double = 0
        var color: CGColor
    }

    static let ink = CGColor(srgbRed: 0.10, green: 0.08, blue: 0.07, alpha: 1)
    static let muted = CGColor(srgbRed: 0.43, green: 0.39, blue: 0.36, alpha: 1)
    static let paper = CGColor(srgbRed: 0.97, green: 0.96, blue: 0.95, alpha: 1)
    static let termBG = CGColor(srgbRed: 0.10, green: 0.08, blue: 0.07, alpha: 1)
    static let termFG = CGColor(srgbRed: 0.91, green: 0.89, blue: 0.85, alpha: 1)

    static func font(_ l: Line) -> CTFont {
        l.mono ? CTFontCreateWithName("Menlo-Regular" as CFString, l.size, nil)
            : CTFontCreateUIFontForLanguage(l.weight > 0 ? .emphasizedSystem : .system, l.size, nil)!
    }

    static func ctLine(_ l: Line) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(l),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): l.color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: l.text, attributes: attrs))
    }

    /// The line's box in pixels (top-left origin).
    static func box(_ l: Line) -> CGRect {
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let w = CTLineGetTypographicBounds(ctLine(l), &ascent, &descent, &leading)
        return CGRect(x: l.x, y: l.baseline - ascent, width: w, height: ascent + descent)
    }

    static func norm(_ r: CGRect) -> NormRect {
        NormRect(x: r.minX / Double(width), y: r.minY / Double(height), width: r.width / Double(width), height: r.height / Double(height))
    }

    static let settings: [Line] = {
        var out = [Line(text: "Account settings", x: 160, baseline: 180, size: 48, weight: 1, color: ink)]
        let rows: [(String, String)] = [
            ("Email", "jane.doe@example.com"),
            ("API key", "sk-proj-Ab3dEf9GhJk2LmN0pQr5StU8vWx1"),
            ("Card", "4242 4242 4242 4242"),
            ("Phone", "+1 415-555-0132"),
            ("Plan", "Pro, renews 2026-11-01"),
            ("Version", "2.4.1 (build 1903)"),
            ("Order", "Order 1234567 shipped"),
        ]
        for (i, r) in rows.enumerated() {
            let y = 300 + Double(i) * 90
            out.append(Line(text: r.0, x: 160, baseline: y, size: 28, color: muted))
            out.append(Line(text: r.1, x: 520, baseline: y, size: 28, color: ink))
        }
        return out
    }()

    static let logRows: [String] = (0..<40).map { i in
        switch i {
        case 8: return "GITHUB_TOKEN=gh" + "p_16C7e42F292c6912E7710c838347Ae178B4a"
        case 13: return "notify ops-team@acme.io when the deploy finishes"
        default: return "[deploy] step \(i + 1) of 40 finished in \(12 + i * 3) ms"
        }
    }
    static let logStart = 20.0, logSpeed = 40.0, logTop = 200.0, logRowHeight = 56.0

    static func logLine(_ i: Int, at t: Double) -> Line {
        Line(text: logRows[i], x: 160, baseline: logTop + Double(i) * logRowHeight - logSpeed * (t - logStart), size: 28, mono: true, color: ink)
    }

    static let terminal: [Line] = [
        Line(text: "$ export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE", x: 120, baseline: 200, size: 26, mono: true, color: termFG),
        Line(text: "$ export SLACK_TOKEN=xo" + "xb-1234567890-0987654321-AbCdEfGhIjKlMnOp", x: 120, baseline: 260, size: 26, mono: true, color: termFG),
        Line(text: "$ echo 'Project Bluebird launch notes'", x: 120, baseline: 320, size: 26, mono: true, color: termFG),
        Line(text: "$ ls -la /usr/local/bin", x: 120, baseline: 380, size: 26, mono: true, color: termFG),
    ]
    static let typed = Line(text: "$ stripe login --api-key sk" + "_test_4eC39HqLyjWDarjtT1zdp7dc", x: 120, baseline: 440, size: 26, mono: true, color: termFG)
    static let typedAt = 50.0

    /// The part of `line` covering `substring`, in pixels.
    static func box(of substring: String, in line: Line) -> CGRect {
        let full = box(line)
        guard let r = line.text.range(of: substring) else { return full }
        let prefix = Line(text: String(line.text[..<r.lowerBound]), x: line.x, baseline: line.baseline, size: line.size, mono: line.mono,
                          weight: line.weight, color: line.color)
        let part = Line(text: substring, x: line.x, baseline: line.baseline, size: line.size, mono: line.mono, weight: line.weight, color: line.color)
        let px = line.text.distance(from: line.text.startIndex, to: r.lowerBound) == 0 ? 0 : box(prefix).width
        let b = box(part)
        return CGRect(x: line.x + px, y: full.minY, width: b.width, height: full.height)
    }

    static func truths(seconds: Double) -> [Truth] {
        var out: [Truth] = []
        func still(_ kind: SensitiveKind, _ text: String, _ line: Line, _ range: TimeRange) {
            let r = norm(box(of: text, in: line))
            out.append(Truth(kind: kind, text: text, visible: range, rect: { _ in r }))
        }
        let a = TimeRange(start: 0, end: min(20, seconds))
        still(.email, "jane.doe@example.com", settings[2], a)
        still(.apiKey, "sk-proj-Ab3dEf9GhJk2LmN0pQr5StU8vWx1", settings[4], a)
        still(.card, "4242 4242 4242 4242", settings[6], a)
        still(.phone, "+1 415-555-0132", settings[8], a)
        if seconds > 20 {
            for (i, kind, text) in [(8, SensitiveKind.apiKey, "gh" + "p_16C7e42F292c6912E7710c838347Ae178B4a"), (13, .email, "ops-team@acme.io")] {
                // Fully on screen while its top is below 0.
                let start0 = logLine(i, at: logStart)
                let height0 = box(start0).height
                let leaves = logStart + (box(start0).minY - 2) / logSpeed
                let end = min(min(40, seconds), leaves)
                _ = height0
                out.append(Truth(kind: kind, text: text, visible: TimeRange(start: logStart, end: end),
                                 rect: { t in norm(box(of: text, in: logLine(i, at: t))) }))
            }
        }
        if seconds > 40 {
            let c = TimeRange(start: 40, end: seconds)
            still(.apiKey, "AKIAIOSFODNN7EXAMPLE", terminal[0], c)
            still(.apiKey, "xo" + "xb-1234567890-0987654321-AbCdEfGhIjKlMnOp", terminal[1], c)
            still(.custom, "Project Bluebird", terminal[2], c)
        }
        if seconds > typedAt {
            still(.apiKey, "sk" + "_test_4eC39HqLyjWDarjtT1zdp7dc", typed, TimeRange(start: typedAt, end: seconds))
        }
        return out
    }

    // MARK: Drawing

    static func draw(_ lines: [Line], in ctx: CGContext) {
        for l in lines {
            ctx.textPosition = CGPoint(x: l.x, y: l.baseline)
            CTLineDraw(ctLine(l), ctx)
        }
    }

    /// A top-left-origin context over BGRA memory.
    static func context(_ data: UnsafeMutableRawPointer, bytesPerRow: Int) -> CGContext? {
        guard let ctx = CGContext(data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.setShouldSmoothFonts(false)
        return ctx
    }

    static func frame(at t: Double, into ctx: CGContext) {
        let all = CGRect(x: 0, y: 0, width: width, height: height)
        if t < 20 {
            ctx.setFillColor(paper); ctx.fill(all)
            draw(settings, in: ctx)
        } else if t < 40 {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(all)
            draw((0..<logRows.count).map { logLine($0, at: t) }.filter { $0.baseline > -40 && $0.baseline < Double(height) + 40 }, in: ctx)
        } else {
            ctx.setFillColor(termBG); ctx.fill(all)
            draw(terminal + (t >= typedAt ? [typed] : []), in: ctx)
        }
    }

    static func make(seconds: Double) async throws -> Fixture {
        let url = testTemporaryDirectory.appendingPathComponent("rb-secrets-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000, AVVideoMaxKeyFrameIntervalKey: fps * 2,
                                              AVVideoAllowFrameReorderingKey: false],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let frames = Int(seconds * Double(fps))
        for n in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            guard let pb else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(pb, [])
            if let ctx = context(CVPixelBufferGetBaseAddress(pb)!, bytesPerRow: CVPixelBufferGetBytesPerRow(pb)) {
                frame(at: Double(n) / Double(fps), into: ctx)
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: Int64(n), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return Fixture(url: url, seconds: seconds, width: width, height: height, truth: truths(seconds: seconds))
    }
}
