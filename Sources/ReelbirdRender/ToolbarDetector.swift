@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ReelbirdCore

/// Finds a browser's toolbar (tabs, address bar, bookmarks bar) in a recording, without any permission: the band
/// of rows at the top of the screen video that stays still while the page below it changes.
///
/// Samples 16 frames spread over the recording (full height, at most 480 columns, luma only), then per row
/// measures how much it changes between neighbouring samples and how strong a full-width horizontal edge sits
/// above it. The answer is the deepest full-width edge inside the still band at the top (the toolbar's divider
/// line, or where the toolbar's colour meets the page), within 40–220 points and at least 3% of the height,
/// provided the content below it changes. Without such an edge, the end of the still band is used with low
/// confidence. A page whose own header stays still (and has a full-width edge) within 220 points reads as part
/// of the toolbar.
public enum ToolbarDetector {
    /// What the detector found.
    public struct Detection: Hashable, Sendable {
        /// Rows to hide at the top (0 = nothing found).
        public var topPixels: Int
        public var confidence: Double
        /// Height of the analysed video in pixels.
        public var height: Int
        /// Rows at the top that stayed still in the samples.
        public var staticRows: Int
        /// Share of the width the chosen edge spans (0 when no edge was used).
        public var edgeStrength: Double

        static func none(height: Int, staticRows: Int = 0) -> Detection {
            Detection(topPixels: 0, confidence: 0, height: height, staticRows: staticRows, edgeStrength: 0)
        }
    }

    /// Frames sampled across the recording.
    public static let sampleCount = 16
    /// Columns analysed per row (frames are narrowed to this; rows keep full resolution for pixel accuracy).
    static let maxColumns = 480

    /// The bundle's cached suggestion, or a fresh detection (cached in `crop-suggestion.json`). `nil` when the
    /// recording has no readable screen video. Takes well under a second; call it off the main thread.
    public static func suggestion(bundle: ProjectBundle) async -> CropSuggestion? {
        guard let manifest = try? bundle.readManifest(), let file = manifest.track(.screen)?.file else { return nil }
        if let cached = bundle.readCropSuggestion(manifest: manifest) { return cached }
        let size = bundle.fileSize(file)
        guard size > 0 else { return nil }
        let start = Date()
        guard let d = try? await detect(url: bundle.resolve(file), captureScale: manifest.capture.scale) else { return nil }
        let s = CropSuggestion(file: file, fileSize: size, height: d.height, topPixels: d.topPixels, confidence: d.confidence,
                               seconds: (Date().timeIntervalSince(start) * 1000).rounded() / 1000)
        try? bundle.writeCropSuggestion(s)
        return s
    }

    /// Detects the toolbar in a video file. `captureScale` is the display's backing scale (2 on Retina), which
    /// turns the 40–220 point limits into pixels.
    public static func detect(url: URL, captureScale: Double, samples: Int = sampleCount) async throws -> Detection {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw RenderError.missingScreenTrack }
        let (range, natural) = try await track.load(.timeRange, .naturalSize)
        let duration = range.duration.seconds
        guard duration.isFinite, duration > 0, natural.width >= 16, natural.height >= 16 else { return .none(height: Int(natural.height)) }

        let n = max(4, samples)
        let spacing = duration / Double(n)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Any frame near each sample time will do; a loose tolerance lets the decoder stop at nearby sync frames.
        let tolerance = CMTime(seconds: max(0.02, spacing * 0.45), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let times = (0..<n).map { i in
            CMTime(seconds: range.start.seconds + duration * (0.03 + 0.94 * Double(i) / Double(n - 1)), preferredTimescale: 600)
        }

        var acc: Accumulator?
        var lastTime: CMTime?
        for await result in generator.images(for: times) {
            guard let image = try? result.image else { continue }
            if let actual = try? result.actualTime, let last = lastTime, actual == last { continue }
            lastTime = try? result.actualTime
            guard let gray = luma(image) else { continue }
            if acc == nil { acc = Accumulator(width: gray.width, height: gray.height) }
            guard acc?.width == gray.width, acc?.height == gray.height else { continue }
            acc?.add(gray.pixels)
        }
        guard let acc else { return .none(height: Int(natural.height)) }
        return analyze(acc, captureScale: captureScale)
    }

    /// The frame as 8-bit luma: full height, at most `maxColumns` columns.
    static func luma(_ image: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        let w = min(image.width, maxColumns), h = image.height
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            // Nearest-neighbour: columns are sampled, rows stay exact (no vertical blur across the divider line).
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (pixels, w, h) : nil
    }

    /// Per-row statistics over the sampled frames.
    struct Accumulator {
        let width: Int
        let height: Int
        /// Per neighbouring pair of frames: mean absolute change of each row (0...255).
        var pairChange: [[Float]] = []
        /// Per frame: share of columns where row y differs from row y − 1 by more than `edgeThreshold`.
        var edgeFullness: [[Float]] = []
        private var previous: [UInt8]?

        /// Luma steps smaller than this don't count as an edge (subtle dark-mode dividers are about 10).
        static let edgeThreshold = 6

        init(width: Int, height: Int) { self.width = width; self.height = height }

        var frameCount: Int { edgeFullness.count }

        mutating func add(_ frame: [UInt8]) {
            let w = width, h = height
            var edges = [Float](repeating: 0, count: h)
            frame.withUnsafeBufferPointer { f in
                for y in 1..<h {
                    var count = 0
                    let a = (y - 1) * w, b = y * w
                    for x in 0..<w where abs(Int(f[b + x]) - Int(f[a + x])) > Self.edgeThreshold { count += 1 }
                    edges[y] = Float(count) / Float(w)
                }
            }
            edgeFullness.append(edges)
            if let previous {
                var change = [Float](repeating: 0, count: h)
                frame.withUnsafeBufferPointer { f in
                    previous.withUnsafeBufferPointer { p in
                        for y in 0..<h {
                            var sum = 0
                            let o = y * w
                            for x in 0..<w { sum += abs(Int(f[o + x]) - Int(p[o + x])) }
                            change[y] = Float(sum) / Float(w)
                        }
                    }
                }
                pairChange.append(change)
            }
            previous = frame
        }
    }

    /// A row counts as changed in a pair when its mean change exceeds this (compression noise on still content
    /// stays under about 1).
    static let changeThreshold: Float = 2
    /// A row is still when it changed in at most this share of pairs (navigating changes the address bar and tab
    /// titles a few times without making them part of the page).
    static let stillActivity: Float = 0.34

    static func analyze(_ acc: Accumulator, captureScale: Double) -> Detection {
        let h = acc.height
        let pairs = acc.pairChange.count
        guard pairs >= 3, h >= 32 else { return .none(height: h) }

        var change = [Float](repeating: 0, count: h)      // mean change per row
        var activity = [Float](repeating: 0, count: h)    // share of pairs in which the row changed
        for p in acc.pairChange {
            for y in 0..<h {
                change[y] += p[y]
                if p[y] > changeThreshold { activity[y] += 1 }
            }
        }
        for y in 0..<h { change[y] /= Float(pairs); activity[y] /= Float(pairs) }
        // Edge strength per row: the median over frames, so a frame where the page happens to match the toolbar's
        // colour doesn't hide the line, and a page edge seen in one frame doesn't create one.
        var edge = [Float](repeating: 0, count: h)
        var column = [Float](repeating: 0, count: acc.frameCount)
        for y in 1..<h {
            for f in 0..<acc.frameCount { column[f] = acc.edgeFullness[f][y] }
            column.sort()
            edge[y] = column[column.count / 2]
        }

        func still(_ y: Int) -> Bool { activity[y] <= stillActivity && change[y] <= 2.5 }
        // The still band at the top ends where a few rows in a row are moving (single noisy rows are tolerated).
        let run = max(3, Int((2 * captureScale).rounded()))
        var staticEnd = h
        var moving = 0
        for y in 0..<h {
            if still(y) { moving = 0 } else {
                moving += 1
                if moving >= run { staticEnd = y - run + 1; break }
            }
        }

        let scale = max(0.5, captureScale.isFinite ? captureScale : 1)
        let minRows = max(Int((40 * scale).rounded()), Int((0.03 * Double(h)).rounded(.up)))
        let maxRows = min(Int((220 * scale).rounded()), h / 2)
        guard minRows < maxRows, staticEnd >= minRows else { return .none(height: h, staticRows: staticEnd) }

        // Everything below a boundary: how much of it moves, and how strongly.
        func below(_ b: Int) -> (change: Double, active: Double) {
            guard b < h else { return (0, 0) }
            var c = 0.0, a = 0
            for y in b..<h { c += Double(change[y]); if activity[y] > stillActivity { a += 1 } }
            return (c / Double(h - b), Double(a) / Double(h - b))
        }
        func bandChange(_ b: Int) -> Double {
            var c = 0.0
            for y in 0..<b { c += Double(change[y]) }
            return c / Double(max(1, b))
        }
        func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

        func score(_ b: Int, edgeStrength: Double) -> Double? {
            let bl = below(b), band = bandChange(b)
            guard bl.active >= 0.15, bl.change >= 1.5, bl.change >= 3 * band + 0.5 else { return nil }
            let edgeScore = clamp01((edgeStrength - 0.5) / 0.4)
            let contrastScore = clamp01((bl.change / (band + 0.5) - 3) / 7)
            let activeScore = clamp01((bl.active - 0.15) / 0.35)
            return 0.5 * edgeScore + 0.25 * contrastScore + 0.25 * activeScore
        }

        // The deepest full-width edge inside the still band.
        let last = min(maxRows, staticEnd)
        if last >= minRows {
            for y in stride(from: last, through: minRows, by: -1) where edge[y] >= 0.5 {
                guard let s = score(y, edgeStrength: Double(edge[y])) else { continue }
                return Detection(topPixels: y, confidence: (s * 1000).rounded() / 1000, height: h, staticRows: staticEnd,
                                 edgeStrength: Double(edge[y]))
            }
        }
        // No edge: the still band itself, when it ends inside the limits (low confidence).
        if staticEnd <= maxRows, let s = score(staticEnd, edgeStrength: 0) {
            return Detection(topPixels: staticEnd, confidence: (min(0.45, s) * 1000).rounded() / 1000, height: h,
                             staticRows: staticEnd, edgeStrength: 0)
        }
        return .none(height: h, staticRows: staticEnd)
    }
}
