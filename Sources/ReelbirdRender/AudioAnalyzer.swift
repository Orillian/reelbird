@preconcurrency import AVFoundation
import Foundation
import ReelbirdCore
import Synchronization

/// Measures a recording's voice loudness once and caches it in the bundle (`analysis.json`).
public enum AudioAnalyzer {
    /// Analysis sample rate: plenty for speech loudness, and decoding to it is fast.
    static let sampleRate = 16_000.0

    private static let inflight = Mutex<[String: Task<AudioAnalysis?, Never>]>([:])

    /// The cached analysis when it still matches the media, else measures now (one fast decode of the
    /// microphone track, well under a second per 10 minutes) and writes `analysis.json`. `nil` when the
    /// recording has no microphone track or it can't be read. Concurrent calls for one bundle share one pass.
    public static func analysis(bundle: ProjectBundle) async -> AudioAnalysis? {
        guard let manifest = try? bundle.readManifest() else { return nil }
        if let cached = cached(bundle: bundle, manifest: manifest) { return cached }
        let key = bundle.url.standardizedFileURL.path
        let task = inflight.withLock { running in
            if let t = running[key] { return t }
            let t = Task.detached(priority: .userInitiated) { await measureAndStore(bundle: bundle, manifest: manifest) }
            running[key] = t
            return t
        }
        let result = await task.value
        inflight.withLock { _ = $0.removeValue(forKey: key) }
        return result
    }

    /// The bundle-relative file that carries the voice: the raw microphone track today.
    ///
    /// Extension point: when a processed voice stem exists (denoise/EQ/compression rendered after Stop), return it
    /// here, and loudness is measured on the processed voice; the cache keys on this file, so a new stem is
    /// measured again automatically.
    public static func voiceFile(bundle: ProjectBundle, manifest: ProjectManifest) -> String? {
        manifest.track(.microphone)?.file
    }

    /// `analysis.json` when it exists and was measured from the current voice file.
    public static func cached(bundle: ProjectBundle, manifest: ProjectManifest) -> AudioAnalysis? {
        guard let a = bundle.readAnalysis() else { return nil }
        guard let file = voiceFile(bundle: bundle, manifest: manifest) else { return a.microphone == nil ? a : nil }
        guard let mic = a.microphone, mic.file == file, mic.fileSize == fileSize(bundle.resolve(file)) else { return nil }
        return a
    }

    private static func measureAndStore(bundle: ProjectBundle, manifest: ProjectManifest) async -> AudioAnalysis? {
        guard let file = voiceFile(bundle: bundle, manifest: manifest) else { return nil }
        let url = bundle.resolve(file)
        guard let meter = try? await measure(url: url) else { return nil }
        let a = AudioAnalysis(microphone: TrackLoudness(
            file: file, fileSize: fileSize(url),
            integratedLUFS: meter.integratedLUFS.map { $0 + AutoLevel.monoOnStereoDB },
            peakDBFS: meter.peakDBFS, duration: meter.duration))
        try? bundle.writeAnalysis(a)
        return a
    }

    /// Decodes `url`'s first audio track to mono at 16 kHz and meters it (mono loudness).
    static func measure(url: URL) async throws -> LoudnessMeter {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw RenderError.unreadableMedia("no audio track") }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw RenderError.readerFailed(reader.error?.localizedDescription ?? "audio") }
        var meter = LoudnessMeter(sampleRate: sampleRate, channels: 1)
        var scratch: [Float] = []
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let n = CMBlockBufferGetDataLength(bb) / 4
            guard n > 0 else { continue }
            if scratch.count < n { scratch = [Float](repeating: 0, count: n) }
            scratch.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
            scratch.withUnsafeBufferPointer { meter.process($0, frameCount: n) }
        }
        if reader.status == .failed { throw RenderError.readerFailed(reader.error?.localizedDescription ?? "audio") }
        return meter
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? -1
    }
}
