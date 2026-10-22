@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import Vision
import ReelbirdCore

/// The text layer of a published video (`TextLayer`): the lines of text on screen and where they are, so the share
/// page can lay them over the paused video for viewers to select and copy.
///
/// It reads the exported video, not the screen recording, so it sees exactly what viewers see: crop, zoom and
/// layout applied, and nothing under a blur (blurred text can't be read). Samples a frame every `interval`
/// seconds and recognises text only when the picture changed since the last recognised frame (the same change
/// test as Find Sensitive Info); unchanged samples extend the previous frame's time range.
public enum ScreenText {
    public static func read(video url: URL, interval: Double = 0.5, maxLines: Int = 400,
                            progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> TextLayer {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw StepScanner.ScanError.noScreenVideo }
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let size = try await track.load(.naturalSize)
        let job = UncheckedAsset(asset: asset, track: track)
        return try await BlockingWork.run("reelbird.screen-text") { cancel in
            try readNow(asset: job.asset, track: job.track, duration: duration, width: Int(size.width.rounded()), height: Int(size.height.rounded()),
                        interval: interval, maxLines: maxLines, cancelled: cancel, progress: progress)
        }
    }

    private static func readNow(asset: AVURLAsset, track: AVAssetTrack, duration: Double, width: Int, height: Int,
                                interval: Double, maxLines: Int, cancelled: CancellationFlag,
                                progress: @escaping @Sendable (Double) -> Void) throws -> TextLayer {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw StepScanner.ScanError.unreadable(error.localizedDescription) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw StepScanner.ScanError.unreadable(reader.error?.localizedDescription ?? "reader") }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Code and commands should come out as typed, not "corrected".
        request.usesLanguageCorrection = false

        var frames: [TextLayer.Frame] = []
        var nextDue = 0.0
        var lastProbe: [UInt8]?
        let eps = 1e-4
        while let sb = output.copyNextSampleBuffer() {
            if cancelled.isCancelled { throw CancellationError() }
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            guard t.isFinite, t >= nextDue - eps else { continue }
            while nextDue <= t + eps { nextDue += interval }
            if duration > 0 { progress(min(1, t / duration)) }
            let probe = SensitiveInfoScanner.probe(pb)
            if let p = lastProbe, let probe, !SensitiveInfoScanner.changed(p, probe) { continue }
            lastProbe = probe
            let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
            request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
            let lines = try SensitiveInfoScanner.perform(handler, request).compactMap(line).prefix(maxLines)
            let sorted = Array(lines).sorted { ($0.y, $0.x) < ($1.y, $1.x) }
            if let last = frames.last, same(last.lines, sorted) { continue }
            if !frames.isEmpty { frames[frames.count - 1].end = t }
            frames.append(TextLayer.Frame(start: frames.isEmpty ? 0 : t, end: duration, lines: sorted))
        }
        if reader.status == .failed { throw StepScanner.ScanError.unreadable(reader.error?.localizedDescription ?? "decode failed") }
        progress(1)
        if let lastIndex = frames.indices.last { frames[lastIndex].end = max(frames[lastIndex].start, duration) }
        // Stretches with no text at all are left out; the page shows nothing to select there.
        return TextLayer(width: width, height: height, frames: frames.filter { !$0.lines.isEmpty })
    }

    /// One recognised line, top-left origin, rounded to 4 decimals (about a pixel at 4K).
    static func line(_ obs: VNRecognizedTextObservation) -> TextLayer.Line? {
        guard let cand = obs.topCandidates(1).first, cand.confidence >= 0.3 else { return nil }
        let text = cand.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let b = obs.boundingBox
        func r(_ v: CGFloat) -> Double { (Double(v) * 10_000).rounded() / 10_000 }
        return TextLayer.Line(text: String(text.prefix(500)), x: r(b.minX), y: r(1 - b.maxY), w: r(b.width), h: r(b.height))
    }

    /// The same text in about the same places (boxes within half a percent): the frame carries on.
    static func same(_ a: [TextLayer.Line], _ b: [TextLayer.Line]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            guard x.text == y.text, abs(x.x - y.x) < 0.005, abs(x.y - y.y) < 0.005,
                  abs(x.w - y.w) < 0.005, abs(x.h - y.h) < 0.005 else { return false }
        }
        return true
    }
}

/// Hands AVFoundation objects (not Sendable) to the queue that alone uses them.
private struct UncheckedAsset: @unchecked Sendable {
    let asset: AVURLAsset
    let track: AVAssetTrack
}
