@preconcurrency import AVFoundation
import Foundation
import ReelbirdCore
@testable import ReelbirdRender

/// Synthetic narration for voice-stem tests: real speech from `say` (48 kHz float), laid out as phrases with
/// pauses after a noise-only lead-in, plus pink noise and keyboard clicks at a known level.
enum VoiceFixture {
    static let rate = 48_000.0

    struct Take {
        /// Clean speech, the noise alone, and their sum (what the mic "recorded").
        var clean: [Float]
        var noise: [Float]
        var noisy: [Float]
        /// 10 ms frames where the clean speech is active (within 20 dB of its loud level).
        var speechFrames: [Int]
        /// 10 ms frames with no speech at least 300 ms away (lead-in and long pauses).
        var noiseFrames: [Int]
        /// Clean speech ranges (seconds).
        var phrases: [TimeRange]
    }

    private static let sentences = [
        "Hello and welcome. Today I will show you how to set up a new project and invite your team.",
        "Let's start with the dashboard, where you can see every project at a glance.",
        "Click the plus button, give the project a name, and choose who can see it.",
        "Now open settings, turn on notifications, and save your changes.",
    ]

    /// `say` output for each sentence, cached per process.
    private static let cache = Cache()
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var clips: [[Float]] = []
    }

    static func speechClips() throws -> [[Float]] {
        cache.lock.lock(); defer { cache.lock.unlock() }
        if !cache.clips.isEmpty { return cache.clips }
        var clips: [[Float]] = []
        for (i, s) in sentences.enumerated() {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("rb-say-\(getpid())-\(i).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-o", url.path, "--data-format=LEF32@48000", s]
            try p.run()
            p.waitUntilExit()
            let f = try AVAudioFile(forReading: url)
            let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
            try f.read(into: buf)
            clips.append(Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))))
        }
        cache.clips = clips
        return clips
    }

    /// Pink noise (Paul Kellet's filter) normalised to `rmsDB`.
    static func pink(count: Int, rmsDB: Double, seed: UInt64 = 1) -> [Float] {
        var s = seed, b0 = 0.0, b1 = 0.0, b2 = 0.0
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            let w = Double(Int64(bitPattern: s) >> 11) / Double(1 << 52)
            b0 = 0.99765 * b0 + w * 0.0990460; b1 = 0.96300 * b1 + w * 0.2965164; b2 = 0.57000 * b2 + w * 1.0526913
            out[i] = Float(b0 + b1 + b2 + w * 0.1848)
        }
        let rms = (out.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, count))).squareRoot()
        let g = Float(pow(10, rmsDB / 20) / max(rms, 1e-12))
        return out.map { $0 * g }
    }

    /// A take of about `seconds`: 2 s lead-in, then sentences separated by 1.6 s pauses. Speech sits at
    /// `speechDB` RMS (active frames), pink noise `snrDB` below it, and keyboard clicks (8 ms decaying bursts,
    /// about 3 a second, peaking near the speech level) throughout.
    static func take(seconds: Double, speechDB: Double = -24, snrDB: Double = 20, clicks: Bool = true) throws -> Take {
        let clips = try speechClips()
        let n = Int(seconds * rate)
        var clean = [Float](repeating: 0, count: n)
        var phrases: [TimeRange] = []
        var pos = Int(2 * rate), k = 0
        while pos < n - Int(rate) {
            let c = clips[k % clips.count]
            let len = min(c.count, n - pos - Int(0.5 * rate))
            guard len > Int(rate) else { break }
            for i in 0..<len { clean[pos + i] = c[i] }
            phrases.append(TimeRange(start: Double(pos) / rate, end: Double(pos + len) / rate))
            pos += len + Int(1.6 * rate)
            k += 1
        }
        // Speech level from active 10 ms frames.
        let frame = Int(rate / 100)
        let frames = n / frame
        var frameDB = [Double](repeating: -200, count: frames)
        for f in 0..<frames {
            var s = 0.0
            for i in (f * frame)..<((f + 1) * frame) { s += Double(clean[i] * clean[i]) }
            frameDB[f] = 10 * log10(s / Double(frame) + 1e-20)
        }
        let loud = frameDB.sorted()[Int(Double(frames) * 0.98)]
        var active = (0..<frames).filter { frameDB[$0] > loud - 20 }
        let activeRMS = 10 * log10(active.reduce(0.0) { $0 + pow(10, frameDB[$1] / 10) } / Double(max(1, active.count)))
        let g = Float(pow(10, (speechDB - activeRMS) / 20))
        for i in clean.indices { clean[i] *= g }
        active = active.filter { frameDB[$0] > loud - 20 }

        var noise = pink(count: n, rmsDB: speechDB - snrDB)
        if clicks {
            var s: UInt64 = 99
            func rnd() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) }
            var t = 0.2
            let peak = pow(10, (speechDB + 2) / 20)
            while t < seconds - 0.1 {
                let start = Int(t * rate), len = Int(0.008 * rate)
                for i in 0..<len where start + i < n {
                    let env = exp(-Double(i) / (0.0015 * rate))
                    noise[start + i] += Float(peak * env * (rnd() * 2 - 1))
                }
                t += 0.2 + 0.25 * rnd()
            }
        }
        let noisy = zip(clean, noise).map { $0 + $1 }
        let guardFrames = 30
        let noiseFrames = (0..<frames).filter { f in
            let t = Double(f) / 100
            return !phrases.contains { t > $0.start - Double(guardFrames) / 100 && t < $0.end + Double(guardFrames) / 100 } && t > 0.3
        }
        return Take(clean: clean, noise: noise, noisy: noisy, speechFrames: active, noiseFrames: noiseFrames, phrases: phrases)
    }

    /// Median of 50 ms window RMS levels (dB) over the given 10 ms frames: a noise-floor measure clicks don't skew.
    static func floorDB(_ x: [Float], frames: [Int], offset: Int = 0) -> Double {
        let frame = Int(rate / 100)
        var levels: [Double] = []
        var k = 0
        while k + 5 <= frames.count {
            let f0 = frames[k]
            guard frames[k + 4] == f0 + 4 else { k += 1; continue }
            var s = 0.0
            for i in (f0 * frame + offset)..<((f0 + 5) * frame + offset) where i >= 0 && i < x.count { s += Double(x[i] * x[i]) }
            levels.append(10 * log10(s / Double(5 * frame) + 1e-20))
            k += 5
        }
        levels.sort()
        return levels.isEmpty ? -200 : levels[levels.count / 2]
    }

    /// RMS level (dB) over the given 10 ms frames.
    static func levelDB(_ x: [Float], frames: [Int]) -> Double {
        let frame = Int(rate / 100)
        var s = 0.0, c = 0
        for f in frames { for i in (f * frame)..<min(x.count, (f + 1) * frame) { s += Double(x[i] * x[i]); c += 1 } }
        return 10 * log10(s / Double(max(1, c)) + 1e-20)
    }

    /// Decodes a file's first audio track to mono Float32 at 48 kHz.
    static func decodeMono(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(out)
        reader.startReading()
        var samples: [Float] = []
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let n = CMBlockBufferGetDataLength(bb) / 4
            var chunk = [Float](repeating: 0, count: n)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
            samples += chunk
        }
        return samples
    }

    /// A synthetic bundle (small screen video) whose microphone track holds `samples` (AAC, like a real take).
    static func bundle(microphone samples: [Float], seconds: Double, systemAudio: [Float]? = nil) async throws -> ProjectBundle {
        var o = Synthetic.Options()
        o.width = 320; o.height = 180; o.seconds = seconds
        let b = try await Synthetic.makeBundle(o)
        try await DemoFixture.writePCM(url: b.directory(for: .microphone).appendingPathComponent("microphone.m4a"), samples: samples)
        if let systemAudio {
            let dir = b.directory(for: .systemAudio)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try await DemoFixture.writePCM(url: dir.appendingPathComponent("systemAudio.m4a"), samples: systemAudio)
            var m = try b.readManifest()
            m.tracks.append(TrackInfo(kind: .systemAudio, directory: "systemAudio", file: "systemAudio/systemAudio.m4a", codec: "aac",
                                      sampleRate: 48_000, channels: 1, duration: seconds))
            try b.writeManifest(m)
        }
        return b
    }
}

extension VoiceFixture {
    /// Decodes a file's audio to interleaved stereo Float32 at 48 kHz.
    static func decodeStereo(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(out)
        reader.startReading()
        var samples: [Float] = []
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let n = CMBlockBufferGetDataLength(bb) / 4
            var chunk = [Float](repeating: 0, count: n)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
            samples += chunk
        }
        return samples
    }
}
