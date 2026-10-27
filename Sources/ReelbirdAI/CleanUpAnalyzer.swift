@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ReelbirdCore

/// Reads what Clean Up needs from a project, for `CleanUp.plan`: the voice's level in 20 ms windows, the input
/// events, the transcript's words and how much the screen changes. Everything ends up on the recording timeline.
public enum CleanUpAnalyzer {
    /// The planner's inputs for `bundle`. `transcript` is the word-timed transcript on the recording timeline
    /// (`transcript.json`); without one, pauses come from the audio level alone and there are no fillers or
    /// retakes. `measureScreen` samples small thumbnails of the screen video (about 2 a second, at most 1,200)
    /// so silent stretches where the screen changes are sped up instead of cut.
    public static func analyze(bundle: ProjectBundle, manifest: ProjectManifest, transcript: Transcript?,
                               measureScreen: Bool = true) async throws -> CleanUpInputs {
        let events = (try? bundle.readEvents()) ?? []
        var envelope: AudioEnvelope?
        if let mic = bundle.mediaURL(for: .microphone, in: manifest), FileManager.default.fileExists(atPath: mic.path) {
            var e = try await SilenceDetector.envelope(audio: mic)
            e.origin += manifest.track(.microphone)?.startTime ?? 0
            envelope = e
        }
        var screen: [ScreenChange]?
        if measureScreen, let video = bundle.mediaURL(for: .screen, in: manifest), FileManager.default.fileExists(atPath: video.path) {
            screen = try? await ScreenSampler.changes(video: video, offset: manifest.track(.screen)?.startTime ?? 0,
                                                      duration: manifest.duration)
        }
        try Task.checkCancellation()
        let words = (transcript?.allWords ?? []).map { CleanUpInputs.Word(range: $0.range, text: $0.text) }
        return CleanUpInputs(duration: manifest.duration, words: words, events: events, envelope: envelope,
                             screen: screen, frameRate: Double(manifest.capture.frameRate))
    }
}

/// How much the screen changes over time, from tiny greyscale thumbnails.
enum ScreenSampler {
    static let width = 32, height = 18

    /// Change between consecutive samples about every `max(0.5, duration / maxSamples)` seconds. Thumbnails come
    /// from the nearest sync frames (wide tolerance), so even a long 4K recording takes a few seconds.
    static func changes(video: URL, offset: Double, duration: Double, maxSamples: Int = 1200) async throws -> [ScreenChange] {
        let asset = AVURLAsset(url: video)
        let fileDuration = try await asset.load(.duration).seconds
        guard fileDuration.isFinite, fileDuration > 0 else { return [] }
        let step = max(0.5, min(duration > 0 ? duration : fileDuration, fileDuration) / Double(maxSamples))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 96, height: 96)
        let tolerance = CMTime(seconds: step / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var times: [CMTime] = []
        var t = 0.0
        while t < fileDuration { times.append(CMTime(seconds: t, preferredTimescale: 600)); t += step }

        var out: [ScreenChange] = []
        var previous: [UInt8]?
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            guard case .success(let requested, let image, _) = result, let pixels = grey(image) else { continue }
            if let previous {
                var sum = 0
                for i in 0..<pixels.count { sum += abs(Int(pixels[i]) - Int(previous[i])) }
                out.append(ScreenChange(t: requested.seconds + offset, change: Double(sum) / Double(pixels.count) / 255))
            }
            previous = pixels
        }
        return out
    }

    /// `image` drawn into a `width` × `height` 8-bit grey buffer.
    static func grey(_ image: CGImage) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: width * height)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? buffer : nil
    }
}
