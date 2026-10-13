import Foundation

/// `analysis.json`: measurements of the recorded media, made once per recording and cached in the bundle.
/// Regenerable: deleting the file only means the next export or editor session measures again.
public struct AudioAnalysis: Codable, Hashable, Sendable {
    /// Bumped when the measurement changes; files with another version are measured again.
    /// 2: voice activity (`speech`), the raw microphone next to the stem, and system audio.
    public static let currentVersion = 2

    public var version: Int = AudioAnalysis.currentVersion
    /// The voice as it plays: the voice stem when enhance is on and rendered, else the raw microphone track.
    public var microphone: TrackLoudness?
    /// The raw microphone track, measured too when `microphone` is the stem (for "Hear original").
    public var rawMicrophone: TrackLoudness?
    /// The system audio track, when there is one.
    public var systemAudio: TrackLoudness?

    public init(microphone: TrackLoudness? = nil, rawMicrophone: TrackLoudness? = nil, systemAudio: TrackLoudness? = nil) {
        self.microphone = microphone; self.rawMicrophone = rawMicrophone; self.systemAudio = systemAudio
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        microphone = try c.decodeIfPresent(TrackLoudness.self, forKey: .microphone)
        rawMicrophone = try c.decodeIfPresent(TrackLoudness.self, forKey: .rawMicrophone)
        systemAudio = try c.decodeIfPresent(TrackLoudness.self, forKey: .systemAudio)
    }

    /// The raw microphone's loudness: `rawMicrophone` when the voice is the stem, else `microphone`.
    public var originalVoice: TrackLoudness? { rawMicrophone ?? microphone }
}

/// Loudness of one audio track.
public struct TrackLoudness: Codable, Hashable, Sendable {
    /// Bundle-relative media file that was measured.
    public var file: String
    /// Size of `file` in bytes when measured. A different size means the file changed, so it is measured again.
    public var fileSize: Int64
    /// Integrated loudness (ITU-R BS.1770 K-weighting and gating) as heard on two speakers, in LUFS.
    /// A mono track plays on both channels, so this is the mono measurement + 3 dB. `nil` = silent.
    public var integratedLUFS: Double?
    /// Highest sample magnitude in dBFS (measured at the analysis rate). `nil` = silent.
    public var peakDBFS: Double?
    /// Seconds of audio measured.
    public var duration: Double
    /// Where someone is speaking, in seconds from the file's first sample (`VoiceActivity`). Voice tracks only.
    public var speech: [TimeRange]?
    /// Noise floor in dBFS (mono): the 10th percentile of 10 ms frame levels. `nil` when not measured.
    public var noiseFloorDB: Double?

    public init(file: String, fileSize: Int64, integratedLUFS: Double?, peakDBFS: Double?, duration: Double,
                speech: [TimeRange]? = nil, noiseFloorDB: Double? = nil) {
        self.file = file; self.fileSize = fileSize; self.integratedLUFS = integratedLUFS
        self.peakDBFS = peakDBFS; self.duration = duration; self.speech = speech; self.noiseFloorDB = noiseFloorDB
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decodeIfPresent(String.self, forKey: .file) ?? ""
        fileSize = try c.decodeIfPresent(Int64.self, forKey: .fileSize) ?? -1
        integratedLUFS = try c.decodeIfPresent(Double.self, forKey: .integratedLUFS)
        peakDBFS = try c.decodeIfPresent(Double.self, forKey: .peakDBFS)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        speech = try c.decodeIfPresent([TimeRange].self, forKey: .speech)
        noiseFloorDB = try c.decodeIfPresent(Double.self, forKey: .noiseFloorDB)
    }
}

/// Auto level: one make-up gain that brings speech to a steady target loudness.
public enum AutoLevel {
    /// Target integrated loudness of the voice in the exported (stereo) file, in LUFS. Apple Podcasts and
    /// AES TD1008 recommend −16 LUFS for spoken word on stereo.
    public static let targetLUFS = -16.0
    /// Most auto level will lift a quiet voice.
    public static let maxBoostDB = 18.0
    /// Most auto level will turn down a hot voice.
    public static let maxCutDB = -6.0
    /// A mono track heard on two speakers measures this much louder than the mono signal.
    public static let monoOnStereoDB = 10 * log10(2.0)

    /// Make-up gain in dB for a track at `integratedLUFS` (0 when silent or unknown).
    public static func gainDB(integratedLUFS: Double?) -> Double {
        guard let l = integratedLUFS, l.isFinite else { return 0 }
        return min(maxBoostDB, max(maxCutDB, targetLUFS - l))
    }
}

extension AudioSettings {
    /// The auto level gain for the voice in dB, or `nil` when auto level is off or the voice hasn't been measured.
    public func autoLevelGainDB(_ analysis: AudioAnalysis?) -> Double? {
        guard autoLevel, let mic = analysis?.microphone else { return nil }
        return AutoLevel.gainDB(integratedLUFS: mic.integratedLUFS)
    }

    /// Total gain in dB for a track (auto level + the user's boost for the voice), or `nil` when it is muted.
    public func gainDB(for kind: TrackKind, analysis: AudioAnalysis?) -> Double? {
        switch kind {
        case .microphone:
            return microphoneMuted ? nil : microphoneGainDB + (autoLevelGainDB(analysis) ?? 0)
        case .systemAudio:
            return systemMuted ? nil : systemGainDB
        default:
            return nil
        }
    }

    /// Linear gain for the raw microphone when it stands in for the voice ("Hear original"): auto level from the
    /// raw track's own loudness plus the boost, so the comparison is loudness-matched. 0 when muted.
    public func linearGainForOriginalVoice(analysis: AudioAnalysis?) -> Float {
        guard !microphoneMuted else { return 0 }
        let auto = autoLevel ? (analysis?.originalVoice).map { AutoLevel.gainDB(integratedLUFS: $0.integratedLUFS) } ?? 0 : 0
        return Float(pow(10, min(30, max(-60, microphoneGainDB + auto)) / 20))
    }

    /// `gainDB(for:analysis:)` as a linear factor, clamped to −60…+30 dB (0 when muted).
    public func linearGain(for kind: TrackKind, analysis: AudioAnalysis?) -> Float {
        guard let db = gainDB(for: kind, analysis: analysis) else { return 0 }
        return Float(pow(10, min(30, max(-60, db)) / 20))
    }
}

/// Integrated loudness per ITU-R BS.1770-4: K-weighting, 400 ms blocks with 75% overlap, an absolute gate
/// at −70 LUFS and a relative gate 10 LU below the gated mean (which drops pauses between words).
/// Streaming: feed interleaved Float32 in any chunk size, then read `integratedLUFS`.
public struct LoudnessMeter: Sendable {
    public let sampleRate: Double
    public let channels: Int
    private var stage1: [Biquad]
    private var stage2: [Biquad]
    private let hop: Int
    private var hopFill = 0
    private var hopSum = 0.0
    /// Sum of squares of each 100 ms hop (all channels).
    private var hops: [Double] = []
    private var peak: Float = 0
    public private(set) var frames = 0

    public init(sampleRate: Double, channels: Int = 1) {
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        let (shelf, highpass) = Self.kWeighting(sampleRate: sampleRate)
        stage1 = Array(repeating: shelf, count: self.channels)
        stage2 = Array(repeating: highpass, count: self.channels)
        hop = max(1, Int((sampleRate / 10).rounded()))
    }

    /// Adds `frameCount` interleaved frames.
    public mutating func process(_ samples: UnsafeBufferPointer<Float>, frameCount: Int) {
        let n = min(frameCount, samples.count / channels)
        guard n > 0, let base = samples.baseAddress else { return }
        for f in 0..<n {
            var energy = 0.0
            for c in 0..<channels {
                let x = base[f * channels + c]
                let a = abs(x)
                if a > peak { peak = a }
                let y = stage2[c].run(stage1[c].run(Double(x)))
                energy += y * y
            }
            hopSum += energy
            hopFill += 1
            if hopFill == hop {
                hops.append(hopSum)
                hopSum = 0; hopFill = 0
            }
        }
        frames += n
    }

    public mutating func process(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { process($0, frameCount: $0.count / channels) }
    }

    /// Mean square of each gating block (400 ms, hop 100 ms). A clip shorter than one block is one block.
    private var blocks: [Double] {
        if hops.count < 4 {
            let n = hops.count * hop + hopFill
            return n > 0 ? [(hops.reduce(0, +) + hopSum) / Double(n)] : []
        }
        var out: [Double] = []
        out.reserveCapacity(hops.count - 3)
        var window = hops[0] + hops[1] + hops[2]
        for j in 3..<hops.count {
            window += hops[j]
            out.append(window / Double(4 * hop))
            window -= hops[j - 3]
        }
        return out
    }

    /// Gated integrated loudness in LUFS, or `nil` when nothing is above the absolute gate (silence).
    public var integratedLUFS: Double? {
        func lufs(_ z: Double) -> Double { -0.691 + 10 * log10(z) }
        let absolute = blocks.filter { $0 > 0 && lufs($0) > -70 }
        guard !absolute.isEmpty else { return nil }
        let relative = lufs(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { lufs($0) > relative }
        guard !gated.isEmpty else { return nil }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }

    /// Highest sample magnitude in dBFS, or `nil` for digital silence.
    public var peakDBFS: Double? { peak > 0 ? 20 * log10(Double(peak)) : nil }

    /// Duration fed so far in seconds.
    public var duration: Double { Double(frames) / sampleRate }

    struct Biquad: Sendable {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0
        init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
            self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
        }
        /// Transposed direct form II.
        @inline(__always) mutating func run(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    /// The BS.1770 pre-filter (high shelf, +4 dB above ~1.7 kHz) and RLB high-pass (~38 Hz), designed for any
    /// sample rate by the bilinear transform (the published 48 kHz coefficients fall out exactly).
    static func kWeighting(sampleRate: Double) -> (Biquad, Biquad) {
        var f0 = 1681.974450955533, q = 0.7071752369554196
        let g = 3.999843853973347
        var k = tan(Double.pi * f0 / sampleRate)
        let vh = pow(10, g / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
                           a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        f0 = 38.13547087602444; q = 0.5003270373238773
        k = tan(Double.pi * f0 / sampleRate)
        a0 = 1 + k / q + k * k
        let highpass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        return (shelf, highpass)
    }
}
