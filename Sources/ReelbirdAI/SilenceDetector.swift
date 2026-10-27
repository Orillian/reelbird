import Accelerate
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ReelbirdCore

public enum SilenceDetectorError: LocalizedError, Sendable {
    case unreadableAudio(String)
    public var errorDescription: String? {
        switch self { case .unreadableAudio(let m): return m }
    }
}

/// Finds silent stretches in an audio track by RMS level, for "trim silences" edits.
public enum SilenceDetector {
    /// RMS analysis window in seconds.
    static let window = 0.02
    /// Analysis sample rate: audio is decoded straight to 16 kHz mono, which keeps a 1-hour file fast.
    static let analysisRate = 16_000.0

    /// Silent ranges in seconds from the start of the file, in order.
    ///
    /// A window is silent when its RMS level is below `thresholdDB` (dBFS). Silent runs shorter than
    /// `minDuration` are ignored; non-silent blips under 100 ms (clicks, breaths) inside a silence don't break it.
    /// The decode runs on its own queue, off the cooperative pool and the main thread.
    public static func silentRanges(audio: URL, thresholdDB: Double = -45, minDuration: Double = 1.2) async throws -> [TimeRange] {
        let (levels, origin) = try await rmsLevels(audio: audio)
        return silentRanges(levels: levels, windowDuration: window, origin: origin,
                            thresholdDB: thresholdDB, minDuration: minDuration)
    }

    /// Silent ranges with a threshold that follows the room: the noise floor (10th percentile level) plus
    /// `margin` dB, kept between -60 and -30 dBFS. A noisy room no longer reads as all speech, and a very quiet
    /// one doesn't hide soft words under a fixed -45.
    public static func silentRanges(audio: URL, adaptiveMargin margin: Double, minDuration: Double = 1.2) async throws -> [TimeRange] {
        let env = try await envelope(audio: audio)
        return silentRanges(levels: env.levels, windowDuration: env.window, origin: env.origin,
                            thresholdDB: Double(env.adaptiveThreshold(margin: Float(margin))), minDuration: minDuration)
    }

    /// The level of `audio` in 20 ms windows (dBFS), with times from the start of the file.
    public static func envelope(audio: URL) async throws -> AudioEnvelope {
        let (levels, origin) = try await rmsLevels(audio: audio)
        return AudioEnvelope(levels: levels, window: window, origin: origin)
    }

    /// Cuts that remove silences but keep `padding` seconds of air next to speech, so words aren't clipped.
    /// Silences touching the start (0) or `duration` are cut right to the edge. Cuts shorter than `minimumCut` are dropped.
    public static func trimCuts(silences: [TimeRange], padding: Double = 0.15, minimumCut: Double = 0.3,
                                duration: Double? = nil) -> [TimeRange] {
        silences.compactMap { s in
            let start = s.start <= 0.001 ? s.start : s.start + padding
            let atEnd = duration.map { s.end >= $0 - 0.001 } ?? false
            let end = atEnd ? s.end : s.end - padding
            return end - start >= minimumCut ? TimeRange(start: start, end: end) : nil
        }
    }

    // MARK: - Internals

    /// Per-window RMS in dBFS for the first audio track, plus the time of the first sample.
    static func rmsLevels(audio url: URL) async throws -> (levels: [Float], origin: Double) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SilenceDetectorError.unreadableAudio("Audio file not found: \(url.path)")
        }
        let asset = AVURLAsset(url: url)
        let track: AVAssetTrack
        do { track = try await AudioDecoding.firstAudioTrack(of: asset) } catch {
            throw SilenceDetectorError.unreadableAudio(error.localizedDescription)
        }
        return try await BlockingWork.run("reelbird.silence") { cancel in
            let reader: AVAssetReader
            do { reader = try AVAssetReader(asset: asset) } catch {
                throw SilenceDetectorError.unreadableAudio("Can't read \(url.lastPathComponent): \(error.localizedDescription)")
            }
            let settings: [String: any Sendable] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: analysisRate,
                AVNumberOfChannelsKey: 1,
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else {
                throw SilenceDetectorError.unreadableAudio(
                    "Can't decode \(url.lastPathComponent): \(reader.error?.localizedDescription ?? "unknown error").")
            }

            let windowSize = Int(analysisRate * window)
            var levels: [Float] = []
            var carry = [Float](repeating: 0, count: windowSize)
            var carryCount = 0
            var scratch: [Float] = []
            var origin: Double?

            func emit(_ p: UnsafePointer<Float>) {
                var rms: Float = 0
                vDSP_rmsqv(p, 1, &rms, vDSP_Length(windowSize))
                levels.append(rms > 0 ? 20 * log10f(rms) : -160)
            }

            while !cancel.isCancelled, let sample = output.copyNextSampleBuffer() {
                if origin == nil {
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    origin = pts.isNumeric ? pts.seconds : 0
                }
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
                guard count > 0 else { continue }
                var lengthAtOffset = 0, total = 0
                var raw: UnsafeMutablePointer<CChar>?
                let contiguous = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                                             totalLengthOut: &total, dataPointerOut: &raw) == kCMBlockBufferNoErr
                    && lengthAtOffset == total && raw != nil
                let process = { (samples: UnsafeBufferPointer<Float>) in
                    var i = 0
                    // Finish a partial window from the previous buffer.
                    if carryCount > 0 {
                        let need = min(windowSize - carryCount, samples.count)
                        for k in 0..<need { carry[carryCount + k] = samples[k] }
                        carryCount += need; i = need
                        if carryCount == windowSize { carry.withUnsafeBufferPointer { emit($0.baseAddress!) }; carryCount = 0 }
                    }
                    while i + windowSize <= samples.count {
                        emit(samples.baseAddress! + i)
                        i += windowSize
                    }
                    for k in i..<samples.count { carry[carryCount] = samples[k]; carryCount += 1 }
                }
                if contiguous, let raw {
                    raw.withMemoryRebound(to: Float.self, capacity: count) { process(UnsafeBufferPointer(start: $0, count: count)) }
                } else {
                    if scratch.count < count { scratch = [Float](repeating: 0, count: count) }
                    scratch.withUnsafeMutableBytes { dst in
                        _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: dst.baseAddress!)
                    }
                    scratch.withUnsafeBufferPointer { process(UnsafeBufferPointer(rebasing: $0[0..<count])) }
                }
            }
            if cancel.isCancelled { reader.cancelReading(); throw CancellationError() }
            if reader.status == .failed {
                throw SilenceDetectorError.unreadableAudio(
                    "Decoding \(url.lastPathComponent) failed: \(reader.error?.localizedDescription ?? "unknown error").")
            }
            if carryCount > windowSize / 2 {
                for k in carryCount..<windowSize { carry[k] = 0 }
                carry.withUnsafeBufferPointer { emit($0.baseAddress!) }
            }
            return (levels, origin ?? 0)
        }
    }

    /// Silent ranges from per-window levels. Pure, so it is unit-testable without audio.
    static func silentRanges(levels: [Float], windowDuration: Double, origin: Double,
                             thresholdDB: Double, minDuration: Double, maxBlip: Double = 0.1) -> [TimeRange] {
        let threshold = Float(thresholdDB)
        let maxBlipWindows = Int((maxBlip / windowDuration).rounded())
        var runs: [(start: Int, end: Int)] = []   // silent window runs, end exclusive
        var i = 0
        while i < levels.count {
            guard levels[i] < threshold else { i += 1; continue }
            var j = i
            while j < levels.count, levels[j] < threshold { j += 1 }
            if let last = runs.last, i - last.end <= maxBlipWindows {
                runs[runs.count - 1].end = j   // bridge a short blip
            } else {
                runs.append((i, j))
            }
            i = j
        }
        return runs.compactMap { r in
            let range = TimeRange(start: origin + Double(r.start) * windowDuration, end: origin + Double(r.end) * windowDuration)
            return range.duration >= minDuration ? range : nil
        }
    }
}
