@preconcurrency import AVFoundation
import Accelerate
import Foundation
import Testing

/// Which pitch-preserving time stretch to use for speed segments: `RB_EXP=1 scripts/test.sh --filter speedAudioExperiment`.
///
/// A synthetic voice (gliding 105–190 Hz fundamental, 30 harmonics under two formants, 4 Hz syllables with pauses)
/// is stretched through an `AVMutableComposition` (`scaleTimeRange`, read by `AVAssetReaderAudioMixOutput`, the
/// export path) with each algorithm and compared with the ideal: the same voice synthesised directly at the new
/// speed (same pitch, faster syllables). Scores: mean log-spectrum error in dB over voiced frames (lower is
/// better), median fundamental error in cents, output length error, and decode time.
@Test func speedAudioExperiment() async throws {
    guard ProcessInfo.processInfo.environment["RB_EXP"] != nil else { return }
    let seconds = 6.0, sr = 48_000.0
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rb-speedexp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("voice.wav")
    try writeWAV(SpeechLike.render(seconds: seconds, rate: 1, sampleRate: sr), url: src, sampleRate: sr)

    for rate in [0.5, 1.5, 2.0, 4.0] {
        let ideal = SpeechLike.render(seconds: seconds / rate, rate: rate, sampleRate: sr)
        for (name, algo) in [("timeDomain", AVAudioTimePitchAlgorithm.timeDomain), ("spectral", .spectral)] {
            let t0 = Date()
            let out = try await stretch(src, rate: rate, algorithm: algo, sampleRate: sr)
            let dt = Date().timeIntervalSince(t0)
            let (specErr, cents, lag) = compare(out, ideal, sampleRate: sr)
            let lengthErr = (Double(out.count) - Double(ideal.count)) / sr * 1000
            print(String(format: "SPEEDEXP %.2fx %-10@ spectrum %.2f dB, f0 %.1f cents, offset %+.1f ms, length %+.1f ms, %.0f ms",
                         rate, name as NSString, specErr, cents, lag * 1000, lengthErr, dt * 1000))
        }
    }
}

/// A deterministic voice-like signal whose time can be scaled: f(t) uses `t * rate` for everything but the pitch.
enum SpeechLike {
    static func f0(_ u: Double) -> Double { 105 + 85 * (0.5 + 0.5 * sin(2 * .pi * 0.31 * u)) + 6 * sin(2 * .pi * 5.1 * u) }
    static func envelope(_ u: Double) -> Double {
        let syll = max(0, sin(2 * .pi * 4 * u))
        let phrase = (u.truncatingRemainder(dividingBy: 2.5) < 2.0) ? 1.0 : 0.0
        return pow(syll, 0.6) * phrase
    }
    static func formantGain(_ f: Double, _ u: Double) -> Double {
        let f1 = 500 + 250 * sin(2 * .pi * 2 * u), f2 = 1500 + 600 * sin(2 * .pi * 1.3 * u)
        return exp(-pow((f - f1) / 180, 2)) + 0.6 * exp(-pow((f - f2) / 260, 2)) + 0.02
    }
    /// `seconds` of output at `rate` (rate 2 = the content of 2·seconds of the original).
    static func render(seconds: Double, rate: Double, sampleRate sr: Double) -> [Float] {
        let n = Int(seconds * sr)
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / sr
            let u = t * rate // content time
            let f = f0(u)
            phase += 2 * .pi * f / sr
            var s = 0.0
            for h in 1...30 where Double(h) * f < sr / 2 - 1000 {
                s += formantGain(Double(h) * f, u) * sin(Double(h) * phase) / Double(h).squareRoot()
            }
            out[i] = Float(0.12 * envelope(u) * s)
        }
        return out
    }
}

private func writeWAV(_ samples: [Float], url: URL, sampleRate: Double) throws {
    let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                                                          AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true],
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))!
    buf.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buf)
}

private func stretch(_ url: URL, rate: Double, algorithm: AVAudioTimePitchAlgorithm, sampleRate: Double) async throws -> [Float] {
    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let range = try await track.load(.timeRange)
    let comp = AVMutableComposition()
    let ct = try #require(comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
    try ct.insertTimeRange(range, of: track, at: .zero)
    ct.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration),
                      toDuration: CMTime(seconds: range.duration.seconds / rate, preferredTimescale: 90_000))
    let reader = try AVAssetReader(asset: comp)
    let out = AVAssetReaderAudioMixOutput(audioTracks: [ct], audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
    ])
    out.audioTimePitchAlgorithm = algorithm
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

/// Mean absolute log-magnitude difference (dB) over frames where the ideal is voiced, after aligning by the best
/// lag (±100 ms); the median fundamental error in cents; and that lag in seconds (how late the sound is: A/V sync).
private func compare(_ out: [Float], _ ideal: [Float], sampleRate sr: Double) -> (Double, Double, Double) {
    let frame = 2048, hop = 512
    func spectra(_ x: [Float]) -> [[Float]] {
        let log2n = vDSP_Length(11)
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: frame)
        vDSP_hann_window(&window, vDSP_Length(frame), Int32(vDSP_HANN_NORM))
        var result: [[Float]] = []
        var start = 0
        while start + frame <= x.count {
            var seg = [Float](x[start..<start + frame])
            vDSP_vmul(seg, 1, window, 1, &seg, 1, vDSP_Length(frame))
            var re = [Float](repeating: 0, count: frame / 2), im = [Float](repeating: 0, count: frame / 2)
            var mag = [Float](repeating: 0, count: frame / 2)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    seg.withUnsafeBytes { raw in
                        vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(frame / 2))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(frame / 2))
                }
            }
            result.append(mag.map { 20 * log10(max($0, 1e-6)) })
            start += hop
        }
        return result
    }
    func f0(_ x: ArraySlice<Float>) -> Double? {
        let a = Array(x)
        let minLag = Int(sr / 400), maxLag = Int(sr / 70)
        var best = 0, bestV: Float = 0
        var e0: Float = 0
        vDSP_svesq(a, 1, &e0, vDSP_Length(a.count))
        guard e0 > 1e-4 else { return nil }
        for lag in minLag...maxLag {
            var v: Float = 0
            vDSP_dotpr(a, 1, Array(a[lag...]), 1, &v, vDSP_Length(a.count - lag))
            if v > bestV { bestV = v; best = lag }
        }
        return bestV / e0 > 0.3 ? sr / Double(best) : nil
    }
    // Align: best lag by envelope correlation.
    var bestLag = 0, bestScore = -Double.infinity
    for lag in stride(from: -4800, through: 4800, by: 24) {
        var s = 0.0
        for i in stride(from: max(0, -lag), to: min(ideal.count, out.count - lag), by: 16) { s += Double(abs(ideal[i]) * abs(out[i + lag])) }
        if s > bestScore { bestScore = s; bestLag = lag }
    }
    let aligned: [Float] = (0..<ideal.count).map { i in let j = i + bestLag; return j >= 0 && j < out.count ? out[j] : 0 }
    let so = spectra(aligned), si = spectra(ideal)
    var total = 0.0, count = 0
    for (a, b) in zip(so, si) where (b.max() ?? -120) > -10 {
        for k in 4..<(frame / 2) where b[k] > (b.max()! - 50) { total += Double(abs(a[k] - b[k])); count += 1 }
    }
    var cents: [Double] = []
    var start = 0
    while start + frame <= ideal.count {
        if let a = f0(aligned[start..<start + frame]), let b = f0(ideal[start..<start + frame]) { cents.append(abs(1200 * log2(a / b))) }
        start += hop * 4
    }
    cents.sort()
    return (count > 0 ? total / Double(count) : .nan, cents.isEmpty ? .nan : cents[cents.count / 2], Double(bestLag) / sr)
}
