import Accelerate
import AudioToolbox
@preconcurrency import AVFoundation
import Foundation

/// One second-order IIR section in transposed direct form II, in Double (filters near 80 Hz at 48 kHz need it).
/// Coefficients are normalised (a0 = 1). Designs follow the RBJ Audio EQ Cookbook.
struct Biquad: Sendable {
    var b0, b1, b2, a1, a2: Double
    var z1 = 0.0, z2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    private init(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) {
        self.init(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    @inline(__always) mutating func run(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    static func highPass(frequency f: Double, q: Double, sampleRate fs: Double) -> Biquad {
        let w = 2 * Double.pi * f / fs, c = cos(w), alpha = sin(w) / (2 * q)
        return Biquad((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha)
    }

    static func lowPass(frequency f: Double, q: Double, sampleRate fs: Double) -> Biquad {
        let w = 2 * Double.pi * f / fs, c = cos(w), alpha = sin(w) / (2 * q)
        return Biquad((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + alpha, -2 * c, 1 - alpha)
    }

    /// First-order high-pass (bilinear transform) as a degenerate biquad.
    static func highPass1(frequency f: Double, sampleRate fs: Double) -> Biquad {
        let k = tan(Double.pi * f / fs)
        return Biquad(b0: 1 / (1 + k), b1: -1 / (1 + k), b2: 0, a1: (k - 1) / (k + 1), a2: 0)
    }

    static func peaking(frequency f: Double, q: Double, gainDB: Double, sampleRate fs: Double) -> Biquad {
        let a = pow(10, gainDB / 40), w = 2 * Double.pi * f / fs, c = cos(w), alpha = sin(w) / (2 * q)
        return Biquad(1 + alpha * a, -2 * c, 1 - alpha * a, 1 + alpha / a, -2 * c, 1 - alpha / a)
    }

    /// High shelf with slope S = 1.
    static func highShelf(frequency f: Double, gainDB: Double, sampleRate fs: Double) -> Biquad {
        let a = pow(10, gainDB / 40), w = 2 * Double.pi * f / fs, c = cos(w)
        let alpha = sin(w) / 2 * 2.0.squareRoot(), sa = 2 * a.squareRoot() * alpha
        return Biquad(a * ((a + 1) + (a - 1) * c + sa), -2 * a * ((a - 1) + (a + 1) * c), a * ((a + 1) + (a - 1) * c - sa),
                      (a + 1) - (a - 1) * c + sa, 2 * ((a - 1) - (a + 1) * c), (a + 1) - (a - 1) * c - sa)
    }
}

/// A cascade of biquads run by Accelerate in Double precision, keeping its state between blocks.
final class BiquadCascade {
    private let setup: vDSP_biquad_SetupD
    private var delay: [Double]
    let sections: Int

    init?(_ sections: [Biquad]) {
        guard !sections.isEmpty else { return nil }
        let coeffs = sections.flatMap { [$0.b0, $0.b1, $0.b2, $0.a1, $0.a2] }
        guard let s = vDSP_biquad_CreateSetupD(coeffs, vDSP_Length(sections.count)) else { return nil }
        setup = s
        self.sections = sections.count
        delay = [Double](repeating: 0, count: 2 * sections.count + 2)
    }

    deinit { vDSP_biquad_DestroySetupD(setup) }

    /// Filters `count` samples from `x` into `y` (may be the same buffer).
    func run(_ x: UnsafePointer<Double>, _ y: UnsafeMutablePointer<Double>, count: Int) {
        guard count > 0 else { return }
        delay.withUnsafeMutableBufferPointer { vDSP_biquadD(setup, $0.baseAddress!, x, 1, y, 1, vDSP_Length(count)) }
    }
}

/// A fixed delay line (for aligning dry signals with a denoiser's latency).
struct DelayLine {
    private var buffer: [Float]
    private var pos = 0
    init(frames: Int) { buffer = [Float](repeating: 0, count: max(0, frames)) }

    /// Replaces `x[i]` with the sample from `frames` ago, in place.
    mutating func process(_ x: UnsafeMutablePointer<Float>, count: Int) {
        guard !buffer.isEmpty else { return }
        let n = buffer.count
        buffer.withUnsafeMutableBufferPointer { b in
            let base = b.baseAddress!
            var i = 0
            while i < count {
                // Swap a contiguous run with the ring buffer.
                let run = min(count - i, n - pos)
                for j in 0..<run { let t = base[pos + j]; base[pos + j] = x[i + j]; x[i + j] = t }
                i += run
                pos += run
                if pos == n { pos = 0 }
            }
        }
    }
}

/// The voice chain after noise removal, all zero-latency (no look-ahead), so the only delay in the stem is the
/// denoiser's: gentle downward expander → compressor → split-band de-esser → presence EQ. Levels are set relative
/// to the recording: the compressor to its speech level, the expander just above the noise left after denoising,
/// so quiet and loud mics, clean and noisy rooms are treated alike. Mono; one instance per render.
///
/// Gain computers run every `step` samples (0.33 ms at 48 kHz) and gains ramp linearly in between; detectors and
/// filters run per sample (filters in Accelerate).
final class VoiceDynamics {
    struct Settings {
        /// Expander: 2:1 below its threshold, at most `expanderRangeDB` of reduction (never a hard gate). The threshold
        /// sits `expanderAboveNoiseDB` over the expected residual noise, within speech −40…−15 dB.
        var expanderAboveNoiseDB = 8.0
        var expanderRatio = 2.0
        var expanderRangeDB = 10.0
        /// Compressor: 3:1 above the speech level + `compressorAboveSpeechDB`, 6 dB soft knee, attack 8 ms, release 120 ms.
        var compressorAboveSpeechDB = 2.0
        var compressorRatio = 3.0
        var compressorKneeDB = 6.0
        var compressorAttack = 0.008
        var compressorRelease = 0.12
        /// Make-up gain so speech keeps about its level before loudness normalisation.
        var makeupDB = 2.0
        /// De-esser: everything above 5 kHz is turned down (at most `deEssMaxDB`) while the 5–9 kHz band holds more
        /// than about 1/6 of the energy.
        var deEssMaxDB = 6.0
        var deEssRatioThresholdDB = -8.0
        /// Presence: +2 dB at 4 kHz, +1.5 dB shelf from 10 kHz (skipped when the source has no content there).
        var presenceDB = 2.0
        var airDB = 1.5
    }

    static let step = 16
    static let block = 4096
    let sampleRate: Double
    let settings: Settings
    let expanderThreshold: Double
    let compressorThreshold: Double
    private let sibilanceFloor: Double
    private var expEnv = 1e-12, expGainDB = 0.0
    private var compEnv = 1e-12
    private var sibEnv = 1e-12, fullEnv = 1e-12, deEssDB = 0.0
    private var lastGain = 1.0, lastDeEss = 1.0
    private let expAttack, expRelease, gainOpen, gainClose: Double
    private let compAtt, compRel, sibAtt, sibRel, deEssSmooth: Double
    private let makeup: Double
    private let sibBand: BiquadCascade?
    private let sibHigh: BiquadCascade?
    private let eq: BiquadCascade?
    private var v: [Double], band: [Double], high: [Double]
    /// Highest compressor and de-esser reductions seen, in dB (diagnostics, tests).
    private(set) var maxCompressionDB = 0.0
    private(set) var maxDeEssDB = 0.0

    /// `speechLevelDB`: integrated loudness of the voice (mono). `residualNoiseDB`: expected noise level after denoising.
    init(sampleRate fs: Double, speechLevelDB: Double, residualNoiseDB: Double, settings: Settings = Settings()) {
        sampleRate = fs
        self.settings = settings
        let speech = speechLevelDB.isFinite && speechLevelDB > -70 ? speechLevelDB : -26
        let noise = residualNoiseDB.isFinite ? residualNoiseDB : speech - 50
        expanderThreshold = min(speech - 15, max(speech - 40, noise + settings.expanderAboveNoiseDB))
        compressorThreshold = speech + settings.compressorAboveSpeechDB
        sibilanceFloor = speech - 25
        func coeff(_ seconds: Double, every n: Int = 1) -> Double { 1 - exp(-Double(n) / (seconds * fs)) }
        expAttack = coeff(0.002); expRelease = coeff(0.015)
        gainOpen = coeff(0.002, every: Self.step); gainClose = coeff(0.06, every: Self.step)
        compAtt = coeff(settings.compressorAttack); compRel = coeff(settings.compressorRelease)
        sibAtt = coeff(0.001); sibRel = coeff(0.05); deEssSmooth = coeff(0.002, every: Self.step)
        makeup = pow(10, settings.makeupDB / 20)
        let nyquist = fs / 2
        if nyquist > 7_000 {
            sibHigh = BiquadCascade([.highPass(frequency: 5_000, q: 0.7071, sampleRate: fs)])
            var bandSections: [Biquad] = [.highPass(frequency: 5_000, q: 0.7071, sampleRate: fs)]
            if 9_000 < nyquist * 0.9 { bandSections.append(.lowPass(frequency: 9_000, q: 0.7071, sampleRate: fs)) }
            sibBand = BiquadCascade(bandSections)
        } else {
            sibHigh = nil; sibBand = nil
        }
        var eqSections: [Biquad] = []
        if 4_000 < nyquist * 0.8 { eqSections.append(.peaking(frequency: 4_000, q: 0.9, gainDB: settings.presenceDB, sampleRate: fs)) }
        if 10_000 < nyquist * 0.8 { eqSections.append(.highShelf(frequency: 10_000, gainDB: settings.airDB, sampleRate: fs)) }
        eq = BiquadCascade(eqSections)
        v = [Double](repeating: 0, count: Self.block)
        band = v; high = v
    }

    @inline(__always) private static func db(_ power: Double) -> Double { 10 * log10(power + 1e-20) }

    /// Processes up to `block` samples in place.
    func process(_ x: UnsafeMutablePointer<Float>, count: Int) {
        var done = 0
        while done < count {
            let n = min(Self.block, count - done)
            processBlock(x + done, count: n)
            done += n
        }
    }

    private func processBlock(_ x: UnsafeMutablePointer<Float>, count n: Int) {
        let s = settings
        let step = Self.step
        let knee = s.compressorKneeDB, slope = 1 - 1 / s.compressorRatio
        v.withUnsafeMutableBufferPointer { vb in
            band.withUnsafeMutableBufferPointer { bb in
                high.withUnsafeMutableBufferPointer { hb in
                    let v = vb.baseAddress!, b = bb.baseAddress!, h = hb.baseAddress!
                    vDSP_vspdp(x, 1, v, 1, vDSP_Length(n))
                    // Expander + compressor.
                    var i = 0
                    while i < n {
                        let m = min(step, n - i)
                        var ee = expEnv, ce = compEnv
                        for j in i..<(i + m) {
                            let p = v[j] * v[j]
                            ee += (p > ee ? expAttack : expRelease) * (p - ee)
                            ce += (p > ce ? compAtt : compRel) * (p - ce)
                        }
                        expEnv = ee; compEnv = ce
                        let el = Self.db(ee)
                        let expTarget = el < expanderThreshold ? -min(s.expanderRangeDB, (expanderThreshold - el) * (s.expanderRatio - 1)) : 0
                        expGainDB += (expTarget > expGainDB ? gainOpen : gainClose) * (expTarget - expGainDB)
                        let over = Self.db(ce) - compressorThreshold
                        let gr: Double = over <= -knee / 2 ? 0 : (over >= knee / 2 ? over * slope : slope * (over + knee / 2) * (over + knee / 2) / (2 * knee))
                        if gr > maxCompressionDB { maxCompressionDB = gr }
                        let g = pow(10, (expGainDB - gr) / 20) * makeup
                        let g0 = lastGain, dg = (g - g0) / Double(m)
                        for j in 0..<m { v[i + j] *= g0 + dg * Double(j + 1) }
                        lastGain = g
                        i += m
                    }
                    // De-esser: detect on 5–9 kHz; x − (1 − g)·HP5k(x) is exactly x when g = 1.
                    if let sibBand, let sibHigh {
                        sibBand.run(v, b, count: n)
                        sibHigh.run(v, h, count: n)
                        i = 0
                        while i < n {
                            let m = min(step, n - i)
                            var se = sibEnv, fe = fullEnv
                            for j in i..<(i + m) {
                                let bp = b[j] * b[j], fp = v[j] * v[j]
                                se += (bp > se ? sibAtt : sibRel) * (bp - se)
                                fe += (fp > fe ? sibAtt : sibRel) * (fp - fe)
                            }
                            sibEnv = se; fullEnv = fe
                            let ratio = Self.db(se) - Self.db(fe)
                            let cut = ratio > s.deEssRatioThresholdDB && Self.db(se) > sibilanceFloor
                                ? min(s.deEssMaxDB, (ratio - s.deEssRatioThresholdDB) * 1.5) : 0
                            deEssDB += deEssSmooth * (cut - deEssDB)
                            if deEssDB > maxDeEssDB { maxDeEssDB = deEssDB }
                            let g = pow(10, -deEssDB / 20)
                            let g0 = lastDeEss, dg = (g - g0) / Double(m)
                            for j in 0..<m { v[i + j] -= (1 - (g0 + dg * Double(j + 1))) * h[i + j] }
                            lastDeEss = g
                            i += m
                        }
                    }
                    eq?.run(v, v, count: n)
                    vDSP_vdpsp(v, 1, x, 1, vDSP_Length(n))
                }
            }
        }
    }
}

/// A noise remover for the voice stem. Implementations: `SoundIsolationDenoiser` (Apple's AUSoundIsolation)
/// today; ML models (DPDFNet, DeepFilterNet) slot in later behind the same protocol.
///
/// Contract: mono Float32 at the sample rate it was created for, streamed in blocks of at most `maximumFrames`.
/// Output is fully "wet" (strength blending happens outside, against the input delayed by `latency`) and is the
/// input delayed by exactly `latency` frames. Not thread-safe: one render owns it.
protocol VoiceDenoiser: AnyObject {
    /// Stable name written to `stem.json`, e.g. "AUSoundIsolation.hq".
    var engineID: String { get }
    var sampleRate: Double { get }
    /// Delay between input and output, in frames.
    var latency: Int { get }
    var maximumFrames: Int { get }
    /// Denoises `count` frames from `input` into `output` (they may not alias).
    func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, count: Int) throws
}

enum VoiceDenoisers {
    /// The best denoiser available at `sampleRate`, or `nil` when none can run (the chain then skips noise removal).
    static func make(sampleRate: Double) -> (any VoiceDenoiser)? {
        if let d = try? SoundIsolationDenoiser(sampleRate: sampleRate) { return d }
        return nil
    }
}

/// Apple's on-device neural voice isolation (`kAudioUnitSubType_AUSoundIsolation`, the HighQualityVoice model on
/// macOS 15+), run faster than real time in an offline `AVAudioEngine` (manual rendering).
///
/// Measured on an M4 Pro (macOS 27): accepts any rate 16–96 kHz, mono or stereo; about 95× real time mono;
/// reports `latency` 0.0925 s (4440 frames at 48 kHz) for HighQualityVoice and 0.0564 s for Voice, and a click
/// comes out exactly that many frames later. Fully wet it removes ~27 dB of pink noise (HQ) without moving speech.
final class SoundIsolationDenoiser: VoiceDenoiser {
    let engineID: String
    let sampleRate: Double
    let latency: Int
    let maximumFrames = 4096
    private let engine = AVAudioEngine()
    private let feed = Feed()
    private let out: AVAudioPCMBuffer

    /// The input the source node hands the engine; set before each render, on the render's own thread.
    private final class Feed: @unchecked Sendable {
        var pointer: UnsafePointer<Float>?
        var count = 0
        var position = 0
    }

    static let description = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
                                                       componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)

    static var isAvailable: Bool {
        var d = description
        return AudioComponentFindNext(nil, &d) != nil
    }

    init(sampleRate: Double, highQuality: Bool = true) throws {
        guard Self.isAvailable else { throw RenderError.unreadableMedia("AUSoundIsolation is not available on this Mac") }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw RenderError.unreadableMedia("unsupported sample rate \(sampleRate)")
        }
        self.sampleRate = sampleRate
        let effect = AVAudioUnitEffect(audioComponentDescription: Self.description)
        let params = effect.auAudioUnit.parameterTree
        params?.parameter(withAddress: AUParameterAddress(kAUSoundIsolationParam_WetDryMixPercent))?.value = 100
        let model = highQuality ? kAUSoundIsolationSoundType_HighQualityVoice : kAUSoundIsolationSoundType_Voice
        params?.parameter(withAddress: AUParameterAddress(kAUSoundIsolationParam_SoundToIsolate))?.value = AUValue(model)
        engineID = highQuality ? "AUSoundIsolation.hq" : "AUSoundIsolation.voice"
        let feed = self.feed
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, list -> OSStatus in
            let n = Int(frameCount)
            for buffer in UnsafeMutableAudioBufferListPointer(list) {
                guard let dst = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let available = max(0, min(n, feed.count - feed.position))
                if available > 0, let p = feed.pointer { dst.update(from: p + feed.position, count: available) }
                if available < n { (dst + available).update(repeating: 0, count: n - available) }
            }
            feed.position += n
            return noErr
        }
        engine.attach(source)
        engine.attach(effect)
        engine.connect(source, to: effect, format: format)
        engine.connect(effect, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: AVAudioFrameCount(maximumFrames))
        try engine.start()
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(maximumFrames)) else {
            throw RenderError.unreadableMedia("couldn't allocate the denoiser buffer")
        }
        out = buffer
        latency = Int((effect.auAudioUnit.latency * sampleRate).rounded())
    }

    deinit { engine.stop() }

    func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, count: Int) throws {
        var done = 0
        while done < count {
            let n = min(maximumFrames, count - done)
            feed.pointer = input + done
            feed.count = n
            feed.position = 0
            let status = try engine.renderOffline(AVAudioFrameCount(n), to: out)
            guard status == .success, Int(out.frameLength) == n, let src = out.floatChannelData?[0] else {
                throw RenderError.readerFailed("voice isolation stopped (\(status.rawValue))")
            }
            (output + done).update(from: src, count: n)
            done += n
        }
        feed.pointer = nil
    }
}
