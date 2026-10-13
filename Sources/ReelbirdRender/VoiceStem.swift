import Accelerate
@preconcurrency import AVFoundation
import Foundation
import ReelbirdCore

/// Renders the voice stem: the microphone track cleaned up offline, faster than real time, into `voice/` (see
/// docs/FORMAT.md). Preview, export and auto level use the stem instead of the raw microphone; the raw track is
/// never changed, and transcription keeps using it.
///
/// Chain (mono, at the microphone's own sample rate):
/// high-pass (80 Hz, 100 Hz for ≤ 24 kHz Bluetooth-class inputs; 18 dB/oct) → noise removal (`VoiceDenoiser`,
/// blended with its aligned input so noise drops by at most the strength's cap) → expander → compressor →
/// de-esser → presence EQ (`VoiceDynamics`) → mix with the raw microphone by `enhanceMix`. Every stage but the
/// denoiser is zero-latency, and the denoiser's latency is removed exactly, so the stem lines up sample for sample
/// with the raw track (and mix 0 reproduces it).
public enum VoiceStem {
    /// The stem's status for these settings (cheap: reads `stem.json` and file sizes).
    public static func status(bundle: ProjectBundle, settings: AudioSettings) -> VoiceStemStatus {
        guard let manifest = try? bundle.readManifest() else { return .off }
        return bundle.voiceStemStatus(manifest: manifest, settings: settings)
    }

    /// Renders the stem unless one matching `settings` exists. `nil` when enhance is off or there's no microphone.
    @discardableResult
    public static func ensure(bundle: ProjectBundle, settings: AudioSettings,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> VoiceStemInfo? {
        let manifest = try bundle.readManifest()
        switch bundle.voiceStemStatus(manifest: manifest, settings: settings) {
        case .off: return nil
        case .ready: return bundle.readVoiceStem()
        case .missing, .stale: return try await render(bundle: bundle, settings: settings, progress: progress)
        }
    }

    /// Renders the stem for `settings` now (even when one matches) and records it in `stem.json`. Runs on the
    /// calling task; cancelling it stops the render and leaves the previous stem in place.
    public static func render(bundle: ProjectBundle, settings: AudioSettings,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> VoiceStemInfo {
        let manifest = try bundle.readManifest()
        guard let raw = manifest.track(.microphone)?.file else { throw RenderError.unreadableMedia("This recording has no microphone track.") }
        let rawURL = bundle.resolve(raw)
        let sourceSize = bundle.fileSize(raw)
        guard sourceSize > 0 else { throw RenderError.unreadableMedia("microphone: file is missing") }
        let started = Date()
        let levels = await rawLevels(bundle: bundle, raw: raw)
        try Task.checkCancellation()

        let fm = FileManager.default
        try fm.createDirectory(at: bundle.voiceDirectory, withIntermediateDirectories: true)
        let hash = VoiceStemInfo.settingsHash(strength: settings.enhanceStrength, mix: settings.enhanceMix, sourceFile: raw, sourceSize: sourceSize)
        let name = "voice-\(hash.prefix(10)).caf"
        let temp = bundle.voiceDirectory.appendingPathComponent(".render-\(UUID().uuidString).caf")
        defer { try? fm.removeItem(at: temp) }

        let result = try await process(source: rawURL, destination: temp, strength: settings.enhanceStrength,
                                       mix: VoiceStemInfo.quantizedMix(settings.enhanceMix), speechLevelDB: levels.speech,
                                       noiseFloorDB: levels.noiseFloor, progress: progress)
        try Task.checkCancellation()
        let final = bundle.voiceDirectory.appendingPathComponent(name)
        try? fm.removeItem(at: final)
        try fm.moveItem(at: temp, to: final)
        let info = VoiceStemInfo(engine: result.engine, settingsHash: hash, strength: settings.enhanceStrength,
                                 mix: VoiceStemInfo.quantizedMix(settings.enhanceMix), sourceFile: raw, sourceSize: sourceSize,
                                 file: "voice/\(name)", sampleRate: result.sampleRate, frames: result.frames,
                                 latencyFrames: result.latency, highPassHz: result.highPassHz,
                                 renderSeconds: Date().timeIntervalSince(started))
        try bundle.writeVoiceStem(info)
        // Older stems: an open player keeps reading its file after the unlink.
        for item in (try? fm.contentsOfDirectory(atPath: bundle.voiceDirectory.path)) ?? []
        where item.hasPrefix("voice-") && item.hasSuffix(".caf") && item != name {
            try? fm.removeItem(at: bundle.voiceDirectory.appendingPathComponent(item))
        }
        progress(1)
        return info
    }

    /// The raw voice's speech level (mono integrated loudness) and noise floor in dB, from `analysis.json` when it
    /// measured the raw file, else measured now (a fast 16 kHz decode).
    static func rawLevels(bundle: ProjectBundle, raw: String) async -> (speech: Double, noiseFloor: Double) {
        let size = bundle.fileSize(raw)
        if let a = bundle.readAnalysis(),
           let t = [a.rawMicrophone, a.microphone].compactMap({ $0 }).first(where: { $0.file == raw && $0.fileSize == size }),
           let floor = t.noiseFloorDB {
            return ((t.integratedLUFS ?? -70) - AutoLevel.monoOnStereoDB, floor)
        }
        let m = try? await AudioAnalyzer.measure(url: bundle.resolve(raw))
        return (m?.meter.integratedLUFS ?? -70, m?.noiseFloorDB ?? -90)
    }

    struct Result {
        var engine: String
        var sampleRate: Double
        var frames: Int
        var latency: Int
        var highPassHz: Double
    }

    /// High-pass corner: 100 Hz for band-limited (Bluetooth headset class) inputs, else 80 Hz.
    static func highPassFrequency(sampleRate: Double) -> Double { sampleRate <= 24_000 ? 100 : 80 }

    /// Runs the chain from `source` (first audio track, any format) into `destination` (mono ALAC 24-bit CAF at the
    /// source's sample rate, same length as the source).
    static func process(source: URL, destination: URL, strength: EnhanceStrength, mix: Double, speechLevelDB: Double, noiseFloorDB: Double,
                        denoiser makeDenoiser: ((Double) -> (any VoiceDenoiser)?) = VoiceDenoisers.make(sampleRate:),
                        progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw RenderError.unreadableMedia("microphone: no audio track") }
        let (formats, range) = try await track.load(.formatDescriptions, .timeRange)
        let nativeRate = formats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? 48_000
        let rate = nativeRate > 0 ? nativeRate : 48_000
        let expectedFrames = max(1, Int(range.duration.seconds * rate))

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw RenderError.readerFailed(reader.error?.localizedDescription ?? "microphone") }

        let writer = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitDepthHintKey: 24,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)

        let pipeline = try Pipeline(sampleRate: rate, strength: strength, mix: mix, speechLevelDB: speechLevelDB, noiseFloorDB: noiseFloorDB,
                                    denoiser: mix > 0 ? makeDenoiser(rate) : nil, writer: writer)
        var scratch: [Float] = []
        var lastReport = 0
        while let sb = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let n = CMBlockBufferGetDataLength(bb) / 4
            guard n > 0 else { continue }
            if scratch.count < n { scratch = [Float](repeating: 0, count: n) }
            let ok = scratch.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) == noErr }
            guard ok else { throw RenderError.readerFailed("microphone: couldn't read samples") }
            try scratch.withUnsafeBufferPointer { try pipeline.push($0.baseAddress!, count: n) }
            if pipeline.inputFrames - lastReport > Int(rate) {
                lastReport = pipeline.inputFrames
                progress(min(0.99, Double(pipeline.inputFrames) / Double(expectedFrames)))
            }
        }
        if reader.status == .failed { throw RenderError.readerFailed(reader.error?.localizedDescription ?? "microphone") }
        try pipeline.finish()
        return Result(engine: pipeline.engineID, sampleRate: rate, frames: pipeline.inputFrames, latency: pipeline.latency,
                      highPassHz: pipeline.highPassHz)
    }

    /// Streaming state of one render.
    final class Pipeline {
        let latency: Int
        let engineID: String
        let highPassHz: Double
        private(set) var inputFrames = 0
        private var outputFrames = 0
        private let denoiser: (any VoiceDenoiser)?
        private let wet: Float
        private let mix: Float
        private let highPass: BiquadCascade?
        private let dynamics: VoiceDynamics
        private var dryDelay: DelayLine
        private var rawDelay: DelayLine
        private let writer: AVAudioFile
        private let block: Int
        private let out: AVAudioPCMBuffer
        private var raw: [Float], hp: [Float], den: [Float], wide: [Double]

        init(sampleRate: Double, strength: EnhanceStrength, mix: Double, speechLevelDB: Double, noiseFloorDB: Double,
             denoiser: (any VoiceDenoiser)?, writer: AVAudioFile) throws {
            self.denoiser = denoiser
            latency = denoiser?.latency ?? 0
            engineID = denoiser?.engineID ?? "none"
            wet = Float(strength.denoiseWet)
            self.mix = Float(mix)
            highPassHz = VoiceStem.highPassFrequency(sampleRate: sampleRate)
            // Third-order Butterworth (18 dB/octave): first-order section + Q = 1 biquad at the same corner.
            highPass = BiquadCascade([.highPass1(frequency: highPassHz, sampleRate: sampleRate),
                                      .highPass(frequency: highPassHz, q: 1.0, sampleRate: sampleRate)])
            // Noise expected after denoising: the raw floor lowered by the strength's cap (fully removed with no cap).
            let residual = denoiser == nil ? noiseFloorDB : noiseFloorDB - (strength.attenuationCapDB ?? 40)
            dynamics = VoiceDynamics(sampleRate: sampleRate, speechLevelDB: speechLevelDB, residualNoiseDB: residual)
            dryDelay = DelayLine(frames: latency)
            rawDelay = DelayLine(frames: latency)
            self.writer = writer
            block = denoiser?.maximumFrames ?? 4096
            guard let buffer = AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: AVAudioFrameCount(block)) else {
                throw RenderError.unreadableMedia("couldn't allocate the voice buffer")
            }
            out = buffer
            raw = [Float](repeating: 0, count: block)
            hp = [Float](repeating: 0, count: block)
            den = [Float](repeating: 0, count: block)
            wide = [Double](repeating: 0, count: block)
        }

        func push(_ input: UnsafePointer<Float>, count: Int) throws {
            var done = 0
            while done < count {
                let n = min(block, count - done)
                try run(input + done, count: n)
                done += n
            }
            inputFrames += count
        }

        /// Pushes `latency` frames of silence so the delayed tail comes out; output length = input length.
        func finish() throws {
            var remaining = latency
            let zeros = [Float](repeating: 0, count: block)
            while remaining > 0 {
                let n = min(block, remaining)
                try zeros.withUnsafeBufferPointer { try run($0.baseAddress!, count: n) }
                remaining -= n
            }
        }

        private func run(_ input: UnsafePointer<Float>, count n: Int) throws {
            guard mix > 0 else {
                // Original only: the raw samples, untouched.
                try write(input, count: n)
                return
            }
            try raw.withUnsafeMutableBufferPointer { rawP in
                try hp.withUnsafeMutableBufferPointer { hpP in
                    try den.withUnsafeMutableBufferPointer { denP in
                        let r = rawP.baseAddress!, h = hpP.baseAddress!, d = denP.baseAddress!
                        r.update(from: input, count: n)
                        wide.withUnsafeMutableBufferPointer { w in
                            vDSP_vspdp(r, 1, w.baseAddress!, 1, vDSP_Length(n))
                            highPass?.run(w.baseAddress!, w.baseAddress!, count: n)
                            vDSP_vdpsp(w.baseAddress!, 1, h, 1, vDSP_Length(n))
                        }
                        if let denoiser {
                            try denoiser.process(h, d, count: n)
                            dryDelay.process(h, count: n)
                            // d = wet·d + (1 − wet)·h
                            var w = wet, dry = 1 - wet
                            vDSP_vsmul(d, 1, &w, d, 1, vDSP_Length(n))
                            vDSP_vsma(h, 1, &dry, d, 1, d, 1, vDSP_Length(n))
                        } else {
                            d.update(from: h, count: n)
                        }
                        dynamics.process(d, count: n)
                        rawDelay.process(r, count: n)
                        var m = mix, keep = 1 - mix
                        vDSP_vsmul(d, 1, &m, d, 1, vDSP_Length(n))
                        vDSP_vsma(r, 1, &keep, d, 1, d, 1, vDSP_Length(n))
                        // Drop the first `latency` frames (the denoiser's delay).
                        let skip = max(0, min(n, latency - outputFrames))
                        outputFrames += skip
                        if n > skip { try write(d + skip, count: n - skip) }
                    }
                }
            }
        }

        private func write(_ p: UnsafePointer<Float>, count: Int) throws {
            guard count > 0, let dst = out.floatChannelData?[0] else { return }
            dst.update(from: p, count: count)
            out.frameLength = AVAudioFrameCount(count)
            try writer.write(from: out)
            outputFrames += count
        }

        /// Peak compressor and de-esser reduction so far (tests, diagnostics).
        var dynamicsReport: (compressionDB: Double, deEssDB: Double) { (dynamics.maxCompressionDB, dynamics.maxDeEssDB) }
    }
}
