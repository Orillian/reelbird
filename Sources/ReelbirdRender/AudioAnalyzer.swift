@preconcurrency import AVFoundation
import Foundation
import ReelbirdCore
import Synchronization

/// Measures a recording's voice loudness once and caches it in the bundle (`analysis.json`).
public enum AudioAnalyzer {
    /// Analysis sample rate: plenty for speech loudness, and decoding to it is fast.
    static let sampleRate = 16_000.0

    private static let inflight = Mutex<[String: Task<AudioAnalysis?, Never>]>([:])

    /// The cached analysis when it still matches the media, else measures now (one fast decode of the voice
    /// file, well under a second per 10 minutes, plus the raw microphone and system audio when not measured yet)
    /// and writes `analysis.json`. `nil` when the recording has no audio or it can't be read. Concurrent calls for
    /// one bundle and voice file share one pass. `settings` choose the voice file (the stem when enhance is on).
    public static func analysis(bundle: ProjectBundle, settings: AudioSettings = AudioSettings()) async -> AudioAnalysis? {
        guard let manifest = try? bundle.readManifest() else { return nil }
        if let cached = cached(bundle: bundle, manifest: manifest, settings: settings) { return cached }
        let voice = voiceFile(bundle: bundle, manifest: manifest, settings: settings)
        let key = bundle.url.standardizedFileURL.path + "|" + (voice ?? "")
        let task = inflight.withLock { running in
            if let t = running[key] { return t }
            let t = Task.detached(priority: .userInitiated) { await measureAndStore(bundle: bundle, manifest: manifest, voice: voice) }
            running[key] = t
            return t
        }
        let result = await task.value
        inflight.withLock { _ = $0.removeValue(forKey: key) }
        return result
    }

    /// The bundle-relative file that carries the voice: the voice stem when enhance is on and a stem has been
    /// rendered from the current microphone file, else the raw microphone track. Loudness and voice activity are
    /// measured on this file, and the cache keys on it (stems get a new name per render), so a new stem is
    /// measured again automatically.
    public static func voiceFile(bundle: ProjectBundle, manifest: ProjectManifest, settings: AudioSettings = AudioSettings()) -> String? {
        bundle.voiceFile(manifest: manifest, settings: settings)
    }

    /// `analysis.json` when it exists and was measured from the current voice file (and the other tracks).
    public static func cached(bundle: ProjectBundle, manifest: ProjectManifest, settings: AudioSettings = AudioSettings()) -> AudioAnalysis? {
        guard let a = bundle.readAnalysis() else { return nil }
        func current(_ t: TrackLoudness?, _ file: String) -> Bool {
            guard let t else { return false }
            return t.file == file && t.fileSize == fileSize(bundle.resolve(file))
        }
        let raw = manifest.track(.microphone)?.file
        if let file = voiceFile(bundle: bundle, manifest: manifest, settings: settings) {
            guard current(a.microphone, file) else { return nil }
            if let raw, raw != file, !current(a.rawMicrophone, raw) { return nil }
        } else if a.microphone != nil {
            return nil
        }
        if let sys = manifest.track(.systemAudio)?.file, FileManager.default.fileExists(atPath: bundle.resolve(sys).path),
           !current(a.systemAudio, sys) { return nil }
        return a
    }

    private static func measureAndStore(bundle: ProjectBundle, manifest: ProjectManifest, voice: String?) async -> AudioAnalysis? {
        let previous = bundle.readAnalysis()
        func reuse(_ t: TrackLoudness?, _ file: String) -> TrackLoudness? {
            guard let t, t.file == file, t.fileSize == fileSize(bundle.resolve(file)) else { return nil }
            return t
        }
        func measured(_ file: String, speech: Bool) async -> TrackLoudness? {
            let url = bundle.resolve(file)
            guard let m = try? await measure(url: url, voiceActivity: speech) else { return nil }
            return TrackLoudness(file: file, fileSize: fileSize(url), integratedLUFS: m.meter.integratedLUFS.map { $0 + AutoLevel.monoOnStereoDB },
                                 peakDBFS: m.meter.peakDBFS, duration: m.meter.duration, speech: speech ? m.speech : nil,
                                 noiseFloorDB: m.noiseFloorDB)
        }
        var a = AudioAnalysis()
        let candidates = [previous?.microphone, previous?.rawMicrophone]
        if let voice {
            if let mic = candidates.compactMap({ reuse($0, voice) }).first(where: { $0.speech != nil }) {
                a.microphone = mic
            } else {
                guard let mic = await measured(voice, speech: true) else { return nil }
                a.microphone = mic
            }
            if let raw = manifest.track(.microphone)?.file, raw != voice {
                if let t = candidates.compactMap({ reuse($0, raw) }).first { a.rawMicrophone = t } else { a.rawMicrophone = await measured(raw, speech: false) }
            }
        }
        if let sys = manifest.track(.systemAudio)?.file, FileManager.default.fileExists(atPath: bundle.resolve(sys).path) {
            if let t = reuse(previous?.systemAudio, sys) { a.systemAudio = t } else { a.systemAudio = await measured(sys, speech: false) }
        }
        guard a.microphone != nil || a.systemAudio != nil else { return nil }
        try? bundle.writeAnalysis(a)
        return a
    }

    /// Decodes `url`'s first audio track to mono at 16 kHz and meters it (mono loudness) and its noise floor (10th
    /// percentile of 10 ms frame levels after a 100 Hz high-pass, so rumble doesn't count). With `voiceActivity`, also
    /// finds speech ranges from those frame levels.
    static func measure(url: URL, voiceActivity: Bool = false) async throws -> (meter: LoudnessMeter, speech: [TimeRange], noiseFloorDB: Double?) {
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
        let frameLength = Int(sampleRate * VoiceActivity.frameDuration)
        var highPass = Biquad.highPass(frequency: 100, q: 0.7071, sampleRate: sampleRate)
        var frameDB: [Float] = []
        var frameSum = 0.0, frameFill = 0
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let n = CMBlockBufferGetDataLength(bb) / 4
            guard n > 0 else { continue }
            if scratch.count < n { scratch = [Float](repeating: 0, count: n) }
            scratch.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
            scratch.withUnsafeBufferPointer { meter.process($0, frameCount: n) }
            do {
                for i in 0..<n {
                    let y = highPass.run(Double(scratch[i]))
                    frameSum += y * y
                    frameFill += 1
                    if frameFill == frameLength {
                        frameDB.append(Float(10 * log10(frameSum / Double(frameLength) + 1e-12)))
                        frameSum = 0; frameFill = 0
                    }
                }
            }
        }
        if reader.status == .failed { throw RenderError.readerFailed(reader.error?.localizedDescription ?? "audio") }
        let floor = frameDB.isEmpty ? nil : Double(frameDB.sorted()[frameDB.count / 10])
        return (meter, voiceActivity ? VoiceActivity.detect(frameDB: frameDB) : [], floor)
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? -1
    }
}
