@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import CoreML
import Foundation
import ReelbirdCore
import Vision

/// Finds sensitive text in a recording's screen video, on this Mac: Vision text recognition on sampled frames,
/// pattern matching (`SensitivePatterns`), then linking across samples (`SensitiveTracker`). Nothing leaves the Mac.
///
/// Sampling: a frame every `interval` (0.5 s). A sample whose picture hasn't changed since the last recognised
/// frame reuses that frame's results instead of running recognition again, so still stretches cost almost
/// nothing. While sensitive text is on screen and the picture changes (scrolling, typing), frames in between are
/// sampled every `trackingInterval` (¼ s), recognising only the band around the text already found, so the blur
/// follows it cheaply; every regular sample still reads the whole frame, so new text is found within `interval`.
/// The recording is split into up to four parts scanned in parallel, each decoded once in order.
public enum SensitiveInfoScanner {
    public struct Options: Sendable, Hashable {
        public var kinds: Set<SensitiveKind> = Set(SensitiveKind.allCases)
        /// Extra words to find (names, project code names), matched without regard to case.
        public var customWords: [String] = []
        /// Seconds between samples.
        public var interval: Double = 0.5
        /// Seconds between samples while sensitive text is on screen and the picture is changing.
        public var trackingInterval: Double = 0.25
        /// Parts scanned in parallel (1...8).
        public var parallelism: Int = 4
        public init() {}
    }

    public struct Result: @unchecked Sendable {
        public var detections: [SensitiveDetection]
        /// Frames sampled, and how many of them went through text recognition.
        public var samples: Int
        public var recognized: Int
        /// Wall-clock seconds the scan took.
        public var seconds: Double
        /// A small picture of each detection where it was first seen (keyed by detection ID). Stays in memory.
        public var thumbnails: [String: CGImage]

        public init(detections: [SensitiveDetection], samples: Int, recognized: Int, seconds: Double, thumbnails: [String: CGImage]) {
            self.detections = detections; self.samples = samples; self.recognized = recognized
            self.seconds = seconds; self.thumbnails = thumbnails
        }
    }

    public enum ScanError: LocalizedError {
        case noScreenVideo
        case unreadable(String)
        public var errorDescription: String? {
            switch self {
            case .noScreenVideo: "This recording has no screen video to scan."
            case .unreadable(let s): "Couldn't read the screen video (\(s))."
            }
        }
    }

    /// Scans a project's screen track. Times in the result are on the recording timeline.
    public static func scan(bundle: ProjectBundle, options: Options = Options(),
                            progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Result {
        guard let manifest = try? bundle.readManifest(), let track = manifest.track(.screen),
              let url = bundle.mediaURL(for: .screen, in: manifest), FileManager.default.fileExists(atPath: url.path) else {
            throw ScanError.noScreenVideo
        }
        return try await scan(video: url, timeOffset: track.startTime, duration: max(manifest.duration, track.duration),
                              options: options, progress: progress)
    }

    /// Scans a video file. `timeOffset` is added to its times (the screen track's start on the recording timeline).
    public static func scan(video url: URL, timeOffset: Double = 0, duration: Double? = nil, options: Options = Options(),
                            progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Result {
        let started = Date()
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ScanError.noScreenVideo }
        let range = try await track.load(.timeRange)
        let fileDuration = range.duration.seconds
        guard fileDuration.isFinite, fileDuration > 0 else { throw ScanError.unreadable("empty video") }
        let total = max(duration ?? 0, fileDuration + timeOffset)

        let parts = max(1, min(8, min(options.parallelism, Int(fileDuration / 8) + 1)))
        let progressBox = ProgressBox(parts: parts, report: progress)
        let results = try await withThrowingTaskGroup(of: ChunkResult.self) { group in
            for i in 0..<parts {
                let a = fileDuration * Double(i) / Double(parts), b = fileDuration * Double(i + 1) / Double(parts)
                group.addTask {
                    try await scanChunk(url: url, from: a, to: b, isLast: i == parts - 1, options: options) { p in progressBox.set(i, p) }
                }
            }
            var all: [ChunkResult] = []
            for try await r in group { all.append(r) }
            return all
        }
        var samples: [SensitiveSample] = []
        var thumbs: [String: (t: Double, image: CGImage)] = [:]
        var sampled = 0, recognized = 0
        for r in results {
            samples += r.samples.map { SensitiveSample(t: $0.t + timeOffset, sightings: $0.sightings) }
            sampled += r.sampled
            recognized += r.recognized
            for (k, v) in r.thumbnails where thumbs[k] == nil || v.t < thumbs[k]!.t { thumbs[k] = v }
        }
        let linked = SensitiveTracker.linkWithValues(samples: samples, duration: total, maxGap: max(1.2, options.interval * 2.4))
        var thumbnails: [String: CGImage] = [:]
        for (d, value) in linked {
            if let img = thumbs[thumbKey(d.kind, value)]?.image { thumbnails[d.id] = img }
        }
        let detections = linked.map(\.detection)
        progress(1)
        return Result(detections: detections, samples: sampled, recognized: recognized,
                      seconds: Date().timeIntervalSince(started), thumbnails: thumbnails)
    }

    // MARK: One part

    struct ChunkResult: @unchecked Sendable {
        var samples: [SensitiveSample]
        var sampled: Int
        var recognized: Int
        var thumbnails: [String: (t: Double, image: CGImage)]
    }

    /// Size of the change-detection picture (block means of the luma plane).
    static let probeSize = (w: 160, h: 100)

    private static func scanChunk(url: URL, from a: Double, to b: Double, isLast: Bool, options: Options,
                                  progress: @escaping @Sendable (Double) -> Void) async throws -> ChunkResult {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ScanError.noScreenVideo }
        // Decoding and recognition block for seconds: they run on their own dispatch queue, never on Swift's
        // cooperative threads (see BlockingWork).
        let job = UncheckedBox((asset, track))
        return try await BlockingWork.run("reelbird.sensitive-scan") { cancel in
            try scanChunkNow(asset: job.value.0, track: job.value.1, from: a, to: b, isLast: isLast, options: options,
                             cancelled: cancel, progress: progress)
        }
    }

    private static func scanChunkNow(asset: AVURLAsset, track: AVAssetTrack, from a: Double, to b: Double, isLast: Bool, options: Options,
                                     cancelled: CancellationFlag, progress: @escaping @Sendable (Double) -> Void) throws -> ChunkResult {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw ScanError.unreadable(error.localizedDescription) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 600),
                                       end: isLast ? .positiveInfinity : CMTime(seconds: b, preferredTimescale: 600))
        guard reader.startReading() else { throw ScanError.unreadable(reader.error?.localizedDescription ?? "reader") }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let ci = CIContext(options: [.cacheIntermediates: false])

        var samples: [SensitiveSample] = []
        var thumbnails: [String: (t: Double, image: CGImage)] = [:]
        var sampled = 0, recognized = 0
        var nextDue = a
        var lastProbe: [UInt8]?
        var lastCheckedAt = -Double.infinity
        var last: [SensitiveSighting] = []
        let eps = 1e-4
        let span = max(1e-3, b - a)

        while let sb = output.copyNextSampleBuffer() {
            if cancelled.isCancelled { throw CancellationError() }
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            guard t.isFinite, t >= a - eps else { continue }
            if !isLast, t >= b - eps { break }
            let due = t >= nextDue - eps
            let tracking = !last.isEmpty && t - lastCheckedAt >= options.trackingInterval - eps
            guard due || tracking else { continue }
            if due {
                while nextDue <= t + eps { nextDue += options.interval }
            }
            sampled += 1
            lastCheckedAt = t
            progress(min(1, (t - a) / span))
            let probe = Self.probe(pb)
            if let p = lastProbe, let probe, !changed(p, probe) {
                // The same picture as the last recognised frame: the same text is still there.
                if due { samples.append(SensitiveSample(t: t, sightings: last)) }
                continue
            }
            lastProbe = probe
            recognized += 1
            // Between regular samples, only the band where the text was (it moves a little at most).
            let region = due ? nil : trackingRegion(last)
            let found = try recognize(pb, request: request, options: options, region: region)
            // Text elsewhere on screen can't have changed position unseen: keep what lies outside the band.
            let sightings = region.map { r in last.filter { $0.rect.intersection(r) == nil } + found } ?? found
            samples.append(SensitiveSample(t: t, sightings: sightings))
            for s in sightings {
                let key = thumbKey(s.kind, s.value)
                if thumbnails[key] == nil, let img = thumbnail(pb, rect: s.rect, context: ci) { thumbnails[key] = (t, img) }
            }
            last = sightings
        }
        if reader.status == .failed { throw ScanError.unreadable(reader.error?.localizedDescription ?? "decode failed") }
        progress(1)
        return ChunkResult(samples: samples, sampled: sampled, recognized: recognized, thumbnails: thumbnails)
    }

    /// Recognises text in one frame and returns the sensitive parts with padded boxes (top-left origin).
    /// Recognises text in one frame (or only inside `region`) and returns the sensitive parts with padded boxes
    /// (top-left origin, whole frame).
    static func recognize(_ pb: CVPixelBuffer, request: VNRecognizeTextRequest, options: Options, region: NormRect? = nil) throws -> [SensitiveSighting] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
        // Vision's region and results use a bottom-left origin; results are relative to the region.
        let roi = region.map { CGRect(x: $0.x, y: 1 - $0.y - $0.height, width: $0.width, height: $0.height) } ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        request.regionOfInterest = roi
        var out: [SensitiveSighting] = []
        for obs in try perform(handler, request) {
            guard let cand = obs.topCandidates(1).first else { continue }
            let text = cand.string
            for m in SensitivePatterns.matches(in: text, kinds: options.kinds, customWords: options.customWords) {
                let b = (try? cand.boundingBox(for: m.range))?.boundingBox ?? obs.boundingBox
                let box = CGRect(x: roi.minX + b.minX * roi.width, y: roi.minY + b.minY * roi.height,
                                 width: b.width * roi.width, height: b.height * roi.height)
                out.append(SensitiveSighting(kind: m.kind, value: m.value, rect: padded(box)))
            }
        }
        return out
    }

    /// Runs text recognition on one frame. With two test runs scanning at once, Vision sometimes fails a frame
    /// (`e5rtError(... 13)`, `CRImageReaderError 1`); this used to be swallowed as "no text", so the scan silently
    /// missed what was on screen. A failed frame is retried with a fresh request (briefly, then once on the CPU) and a
    /// frame that still fails fails the scan: a privacy scan must never report "nothing found" for a frame it couldn't
    /// read. Runs on the scan's own dispatch queue, so the waits never block a cooperative thread.
    static func perform(_ handler: VNImageRequestHandler, _ request: VNRecognizeTextRequest) throws -> [VNRecognizedTextObservation] {
        func fresh() -> VNRecognizeTextRequest {
            let r = VNRecognizeTextRequest()
            r.recognitionLevel = request.recognitionLevel
            r.usesLanguageCorrection = request.usesLanguageCorrection
            r.regionOfInterest = request.regionOfInterest
            return r
        }
        do { try handler.perform([request]); return request.results ?? [] } catch {}
        for delay: useconds_t in [20_000, 80_000, 320_000] {
            usleep(delay)
            let r = fresh()
            do { try handler.perform([r]); return r.results ?? [] } catch {}
        }
        let r = fresh()
        if let cpu = try r.supportedComputeStageDevices[.main]?.first(where: { if case .cpu = $0 { true } else { false } }) {
            r.setComputeDevice(cpu, for: .main)
        }
        try handler.perform([r])
        return r.results ?? []
    }

    /// The band to re-read between regular samples: the found text's rows, grown by a few line heights up and
    /// down (scrolling) and the full width (text that reflows), or `nil` to read the whole frame.
    static func trackingRegion(_ sightings: [SensitiveSighting]) -> NormRect? {
        guard let first = sightings.first else { return nil }
        let rows = sightings.dropFirst().reduce(first.rect) { $0.union($1.rect) }
        let line = sightings.map(\.rect.height).max() ?? 0.03
        let y0 = max(0, rows.y - max(0.08, line * 3)), y1 = min(1, rows.y + rows.height + max(0.08, line * 3))
        guard y1 - y0 < 0.75 else { return nil }
        return NormRect(x: 0, y: y0, width: 1, height: y1 - y0)
    }

    /// Vision's box (bottom-left origin) as a screen rect with a margin of a third of the line height, so
    /// descenders, anti-aliasing and a slightly misplaced box stay covered.
    static func padded(_ b: CGRect) -> NormRect {
        let h = Double(b.height)
        let r = NormRect(x: Double(b.minX) - h * 0.4, y: 1 - Double(b.maxY) - h * 0.35, width: Double(b.width) + h * 0.8, height: h * 1.7)
        let x0 = max(0, r.x), y0 = max(0, r.y), x1 = min(1, r.x + r.width), y1 = min(1, r.y + r.height)
        return NormRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    /// Block means of the luma plane, `probeSize`, or `nil` for an unexpected pixel format.
    static func probe(_ pb: CVPixelBuffer) -> [UInt8]? {
        guard CVPixelBufferGetPlaneCount(pb) >= 1 else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let pw = probeSize.w, ph = probeSize.h
        guard w >= pw, h >= ph else { return nil }
        var sums = [UInt32](repeating: 0, count: pw * ph)
        var counts = [UInt32](repeating: 0, count: pw * ph)
        // Every second row and column is plenty to see a glyph change inside a block.
        for y in Swift.stride(from: 0, to: h, by: 2) {
            let row = base + y * stride
            let by = y * ph / h
            for x in Swift.stride(from: 0, to: w, by: 2) {
                let i = by * pw + x * pw / w
                sums[i] &+= UInt32(row[x])
                counts[i] &+= 1
            }
        }
        return zip(sums, counts).map { UInt8($1 == 0 ? 0 : $0 / $1) }
    }

    /// Whether any block's mean moved by more than 8 levels: a glyph appearing moves its block by 20 or more,
    /// while a keyframe's compression noise moves blocks by a few.
    static func changed(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return true }
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) > 8 { return true }
        return false
    }

    /// The area around a sighting, at most 320 pixels wide.
    static func thumbnail(_ pb: CVPixelBuffer, rect: NormRect, context: CIContext) -> CGImage? {
        let img = CIImage(cvPixelBuffer: pb)
        let W = img.extent.width, H = img.extent.height
        let grown = rect.insetBy(dx: -rect.height * 0.6, dy: -rect.height * 0.6)
        let x0 = max(0, grown.x), y0 = max(0, grown.y), x1 = min(1, grown.x + grown.width), y1 = min(1, grown.y + grown.height)
        guard x1 > x0, y1 > y0 else { return nil }
        // CoreImage has a bottom-left origin.
        let crop = CGRect(x: x0 * W, y: (1 - y1) * H, width: (x1 - x0) * W, height: (y1 - y0) * H).integral
        let scale = min(1, 320 / max(1, crop.width))
        let out = img.cropped(to: crop).transformed(by: CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: -crop.minX, y: -crop.minY))
        return context.createCGImage(out, from: CGRect(x: 0, y: 0, width: (crop.width * scale).rounded(), height: (crop.height * scale).rounded()))
    }

    static func thumbKey(_ kind: SensitiveKind, _ value: String) -> String { "\(kind.rawValue)|\(value)" }
}

/// Combined progress over parallel parts.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [Double]
    private let report: @Sendable (Double) -> Void
    init(parts: Int, report: @escaping @Sendable (Double) -> Void) { self.parts = Array(repeating: 0, count: parts); self.report = report }
    func set(_ i: Int, _ p: Double) {
        let total: Double = lock.withLock {
            parts[i] = max(parts[i], p)
            return parts.reduce(0, +) / Double(parts.count)
        }
        report(min(0.99, total))
    }
}

/// Hands AVFoundation objects (not Sendable) to the thread that alone uses them.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ v: T) { value = v }
}
