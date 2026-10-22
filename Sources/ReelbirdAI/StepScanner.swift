@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import Vision
import ReelbirdCore

/// A take's guide steps: the clicks, typing and shortcuts in its event log (`StepExtractor`), what each click hit
/// (read from the screen video on this Mac) and, on macOS 26+, instructions worded by the on-device model.
/// The scan is cached in `steps.json`; `steps(bundle:edit:)` applies an edit to it.
public enum StepScanner {
    public struct Options: Sendable {
        /// Word the steps with the on-device model when it's available (macOS 26+, Apple Intelligence on).
        public var useModel = true
        /// Scan again even when `steps.json` matches the recording.
        public var refresh = false
        public init(useModel: Bool = true, refresh: Bool = false) { self.useModel = useModel; self.refresh = refresh }
    }

    public enum ScanError: LocalizedError, Equatable {
        case noScreenVideo
        case unreadable(String)
        public var errorDescription: String? {
            switch self {
            case .noScreenVideo: return "This recording has no screen video to read steps from."
            case .unreadable(let m): return "The screen video couldn't be read: \(m)"
            }
        }
    }

    /// The scanned steps of the whole recording: from `steps.json` when it matches, else scanned now and cached.
    /// A cached scan worded by the template is scanned again when the model can word it now.
    public static func scan(bundle: ProjectBundle, options: Options = Options(),
                            progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> StepDocument {
        let manifest = try bundle.readManifest()
        guard let inputs = bundle.stepInputs(manifest: manifest), let track = manifest.track(.screen),
              let url = bundle.mediaURL(for: .screen, in: manifest), FileManager.default.fileExists(atPath: url.path) else {
            throw ScanError.noScreenVideo
        }
        let wantsModel = options.useModel && StepWriter.isAvailable
        if !options.refresh, let cached = bundle.readSteps(inputs: inputs), cached.writer == "model" || !wantsModel {
            progress(1)
            return cached
        }
        var steps = StepExtractor.extract(events: (try? bundle.readEvents()) ?? [])
        let labels = try await StepLabeler.labels(video: url, timeOffset: track.startTime,
                                                  at: steps.map { ($0.imageTime, $0.point) }) { progress($0 * (wantsModel ? 0.5 : 1)) }
        for i in steps.indices {
            steps[i].label = labels[i]?.text
            steps[i].labelRect = labels[i]?.rect
        }
        var writer = "template"
        if wantsModel {
            let narration = StepExtractor.narration(for: steps, words: transcriptWords(bundle))
            // "model" even when no step had narration to word, or the model failed (Read Again tries again):
            // otherwise every look at the guide would read the screen again.
            if let texts = try? await StepWriter.write(steps: steps, narration: narration, progress: { progress(0.5 + $0 * 0.5) }) {
                for i in steps.indices { steps[i].modelText = texts[i] }
            }
            writer = "model"
        }
        progress(1)
        let doc = StepDocument(inputs: inputs, writer: writer, steps: steps)
        try? bundle.writeSteps(doc)
        return doc
    }

    /// The steps the guide shows for `edit` (kept time and crop only, hand edits applied, typing shown as allowed).
    public static func steps(bundle: ProjectBundle, edit: EditDocument, options: Options = Options(),
                             progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [GuideStep] {
        let doc = try await scan(bundle: bundle, options: options, progress: progress)
        let manifest = try bundle.readManifest()
        let events = (try? bundle.readEvents()) ?? []
        return GuideSteps.resolve(doc.steps, edit: edit, duration: manifest.duration,
                                  markers: Markers.resolve(edit: edit, events: events), words: transcriptWords(bundle))
    }

    /// The transcript as sentences with their times (recording timeline), or none. Narration goes to steps a
    /// sentence at a time, so a step never gets half of one.
    public static func transcriptWords(_ bundle: ProjectBundle) -> [TimedWord] {
        guard let data = try? Data(contentsOf: bundle.transcriptURL),
              let t = try? JSONCoding.decoder.decode(Transcript.self, from: data) else { return [] }
        return sentences(t)
    }

    /// Splits each segment at words ending a sentence (. ? !).
    static func sentences(_ t: Transcript) -> [TimedWord] {
        var out: [TimedWord] = []
        for segment in t.segments {
            var current: [Transcript.Word] = []
            func flush() {
                guard let first = current.first, let last = current.last else { return }
                let text = current.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { out.append(TimedWord(start: first.range.start, end: last.range.end, text: text)) }
                current = []
            }
            for w in segment.timedWords {
                current.append(w)
                if let end = w.text.trimmingCharacters(in: .whitespaces).last, ".?!".contains(end) { flush() }
            }
            flush()
        }
        return out
    }
}

// MARK: - Labels

/// What a click hit: the text under the pointer, or the closest text on the same row, read with Vision.
public enum StepLabeler {
    public struct Label: Hashable, Sendable {
        public var text: String
        /// Full-frame normalized, top-left origin.
        public var rect: NormRect
    }

    /// Text recognised near a point: full-frame normalized boxes, top-left origin.
    struct Found: Hashable, Sendable {
        var text: String
        var rect: NormRect
    }

    /// The area read around each click, in pixels of the screen video (2× points on a Retina display).
    static let window = (w: 640.0, h: 240.0)
    /// How far from the pointer a label may be, in pixels.
    static let reach = 90.0

    /// One label per `(time, point)` (recording timeline; `nil` point = no label). `timeOffset` is the screen
    /// track's start on the recording timeline.
    public static func labels(video url: URL, timeOffset: Double, at requests: [(t: Double, point: NormPoint?)],
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [Label?] {
        guard requests.contains(where: { $0.point != nil }) else { progress(1); return requests.map { _ in nil } }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard try await asset.loadTracks(withMediaType: .video).first != nil else { throw StepScanner.ScanError.noScreenVideo }
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 20)
        gen.requestedTimeToleranceAfter = .zero
        var out: [Label?] = []
        for (i, r) in requests.enumerated() {
            try Task.checkCancellation()
            defer { progress(Double(i + 1) / Double(requests.count)) }
            guard let p = r.point else { out.append(nil); continue }
            let fileTime = min(max(0, r.t - timeOffset), max(0, duration - 0.01))
            guard let image = try? await gen.image(at: CMTime(seconds: fileTime, preferredTimescale: 600)).image else {
                out.append(nil); continue
            }
            let job = UncheckedImage(image)
            let W = Double(image.width), H = Double(image.height)
            var picked = pick(try await BlockingWork.run("reelbird.step-label") { _ in try read(job.image, around: p) }, at: p, pixelWidth: W, pixelHeight: H)
            // A line cut off by the edge of the window is read again across the whole width.
            if let first = picked, touchesWindowEdge(first.rect, around: p, pixelWidth: W, pixelHeight: H) {
                let wide = try await BlockingWork.run("reelbird.step-label") { _ in try read(job.image, around: p, width: W) }
                picked = pick(wide, at: p, pixelWidth: W, pixelHeight: H) ?? first
            }
            out.append(picked.map { Label(text: $0.text, rect: $0.rect) })
        }
        return out
    }

    /// Recognises the text in a window around `p` (full-frame normalized results, top-left origin).
    static func read(_ image: CGImage, around p: NormPoint, width: Double = window.w) throws -> [Found] {
        let W = Double(image.width), H = Double(image.height)
        guard W > 1, H > 1 else { return [] }
        let w = min(1, width / W), h = min(1, window.h / H)
        let x0 = min(max(0, p.x - w / 2), 1 - w), y0 = min(max(0, p.y - h / 2), 1 - h)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Vision's region and results use a bottom-left origin; results are relative to the region.
        let roi = CGRect(x: x0, y: 1 - y0 - h, width: w, height: h)
        request.regionOfInterest = roi
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        var out: [Found] = []
        for obs in try SensitiveInfoScanner.perform(handler, request) {
            guard let text = obs.topCandidates(1).first?.string else { continue }
            let b = obs.boundingBox
            let box = CGRect(x: roi.minX + b.minX * roi.width, y: roi.minY + b.minY * roi.height,
                             width: b.width * roi.width, height: b.height * roi.height)
            out.append(Found(text: text, rect: NormRect(x: Double(box.minX), y: 1 - Double(box.maxY), width: Double(box.width), height: Double(box.height))))
        }
        return out
    }

    /// Whether `rect` reaches the left or right edge of the window read around `p` (the text may go on past it).
    static func touchesWindowEdge(_ rect: NormRect, around p: NormPoint, pixelWidth W: Double, pixelHeight H: Double) -> Bool {
        let w = min(1, window.w / W)
        guard w < 1 else { return false }
        let x0 = min(max(0, p.x - w / 2), 1 - w)
        let slack = 4 / W
        return rect.x <= x0 + slack || rect.x + rect.width >= x0 + w - slack
    }

    /// The label for a click at `p`: the smallest text box containing it (with a few pixels of slack), else the
    /// nearest text within `reach`, preferring text on the same row (a button's title beside its icon). Tidied
    /// and at most 60 characters.
    static func pick(_ found: [Found], at p: NormPoint, pixelWidth W: Double, pixelHeight H: Double) -> Found? {
        func px(_ r: NormRect) -> CGRect { CGRect(x: r.x * W, y: r.y * H, width: r.width * W, height: r.height * H) }
        let q = CGPoint(x: p.x * W, y: p.y * H)
        let usable = found.compactMap { f -> Found? in
            let t = tidy(f.text)
            return t.isEmpty ? nil : Found(text: t, rect: f.rect)
        }
        let containing = usable.filter { px($0.rect).insetBy(dx: -8, dy: -6).contains(q) }
        if let best = containing.min(by: { px($0.rect).width * px($0.rect).height < px($1.rect).width * px($1.rect).height }) {
            return best
        }
        func gap(_ r: CGRect) -> (distance: Double, sameRow: Bool) {
            let dx = max(r.minX - q.x, 0, q.x - r.maxX), dy = max(r.minY - q.y, 0, q.y - r.maxY)
            return (hypot(dx, dy), q.y >= r.minY - r.height * 0.6 && q.y <= r.maxY + r.height * 0.6)
        }
        let near = usable.map { ($0, gap(px($0.rect))) }.filter { $0.1.distance <= reach }
        return near.min { a, b in
            // Same-row text counts as half as far.
            (a.1.sameRow ? a.1.distance / 2 : a.1.distance) < (b.1.sameRow ? b.1.distance / 2 : b.1.distance)
        }?.0
    }

    static func tidy(_ s: String) -> String {
        let t = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " :;,·•|"))
        guard t.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
        return t.count > 60 ? String(t.prefix(59)) + "…" : t
    }
}

/// Hands a CGImage to the queue that alone reads it.
private struct UncheckedImage: @unchecked Sendable {
    let image: CGImage
    init(_ i: CGImage) { image = i }
}
