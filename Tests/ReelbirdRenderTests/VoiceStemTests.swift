@preconcurrency import AVFoundation
import Foundation
import Testing
import ReelbirdCore
@testable import ReelbirdRender

private func settings(_ strength: EnhanceStrength, mix: Double = 1) -> AudioSettings {
    var s = AudioSettings()
    s.enhanceStrength = strength
    s.enhanceMix = mix
    return s
}

/// Lag (frames) of `y` against `x` with the highest correlation over `range`, searched within ±`maxLag`.
private func bestLag(_ x: [Float], _ y: [Float], range: Range<Int>, maxLag: Int) -> Int {
    var best = 0, bv = -Double.infinity
    for lag in -maxLag...maxLag {
        var s = 0.0
        for i in range where i + lag >= 0 && i + lag < y.count { s += Double(x[i]) * Double(y[i + lag]) }
        if s > bv { bv = s; best = lag }
    }
    return best
}

/// 1–3 kHz band (two cascaded second-order sections each side).
private func bandPass(_ x: [Float]) -> [Float] {
    var f = [Biquad.highPass(frequency: 1_000, q: 0.7071, sampleRate: 48_000), .highPass(frequency: 1_000, q: 0.7071, sampleRate: 48_000),
             .lowPass(frequency: 3_000, q: 0.7071, sampleRate: 48_000), .lowPass(frequency: 3_000, q: 0.7071, sampleRate: 48_000)]
    return x.map { v in
        var y = Double(v)
        for k in f.indices { y = f[k].run(y) }
        return Float(y)
    }
}

@Test func soundIsolationDelaysByItsReportedLatencyExactly() throws {
    guard SoundIsolationDenoiser.isAvailable else {
        print("AUSoundIsolation not available on this Mac: skipped")
        return
    }
    for rate in [48_000.0, 44_100.0] {
        let d = try SoundIsolationDenoiser(sampleRate: rate)
        let n = Int(rate) * 2
        var x = VoiceFixture.pink(count: n, rmsDB: -60)
        let at = Int(rate / 2) + 123
        x[at] += 0.9
        var y = [Float](repeating: 0, count: n)
        // Uneven block sizes, like a real render.
        var done = 0, k = 0
        try x.withUnsafeBufferPointer { xp in
            try y.withUnsafeMutableBufferPointer { yp in
                while done < n {
                    let c = min(n - done, [4096, 1000, 333, 4096][k % 4])
                    try d.process(xp.baseAddress! + done, yp.baseAddress! + done, count: c)
                    done += c; k += 1
                }
            }
        }
        var peak = 0
        for i in 0..<n where abs(y[i]) > abs(y[peak]) { peak = i }
        print(String(format: "AUSoundIsolation @ %.0f Hz: latency %d frames (%.4f s), click in at %d, out at %d (%.3f)",
                     rate, d.latency, Double(d.latency) / rate, at, peak, y[peak]))
        #expect(abs(peak - (at + d.latency)) <= 1, "click at \(peak), expected \(at + d.latency)")
    }
}

@Test func voiceStemCleansNoiseKeepsSpeechAndIsFast() async throws {
    let seconds = 60.0
    let take = try VoiceFixture.take(seconds: seconds, speechDB: -24, snrDB: 20)
    let b = try await VoiceFixture.bundle(microphone: take.noisy, seconds: seconds)
    defer { try? FileManager.default.removeItem(at: b.url) }
    let rawURL = b.resolve("microphone/microphone.m4a")
    let raw = try await VoiceFixture.decodeMono(rawURL)
    let rawFloor = VoiceFixture.floorDB(raw, frames: take.noiseFrames)
    let rawSpeech = VoiceFixture.levelDB(raw, frames: take.speechFrames)
    print(String(format: "RAW noise floor %.1f dB, speech %.1f dB", rawFloor, rawSpeech))

    var results: [EnhanceStrength: Double] = [:]
    for strength in EnhanceStrength.allCases {
        let started = Date()
        let info = try await VoiceStem.render(bundle: b, settings: settings(strength))
        let elapsed = Date().timeIntervalSince(started)
        let stem = try await VoiceFixture.decodeMono(b.resolve(info.file))
        #expect(stem.count == raw.count, "stem \(stem.count) frames vs raw \(raw.count)")
        let floor = VoiceFixture.floorDB(stem, frames: take.noiseFrames)
        let speech = VoiceFixture.levelDB(stem, frames: take.speechFrames)
        let drop = rawFloor - floor
        results[strength] = drop
        print(String(format: "STEM %@ (%@): noise floor %.1f dB (−%.1f dB), speech %.1f dB (%+.1f), %.2f s for %.0f s = %.0f× real time",
                     strength.rawValue, info.engine, floor, drop, speech, speech - rawSpeech, elapsed, seconds, seconds / elapsed))
        #expect(seconds / elapsed > 10, "render speed \(seconds / elapsed)× real time")
        #expect(abs(speech - rawSpeech) <= 2, "\(strength) speech level moved \(speech - rawSpeech) dB")
        if info.engine != "none" {
            #expect(drop >= (strength.attenuationCapDB ?? 24), "\(strength) noise floor dropped only \(drop) dB")
        }
        // Lined up with the raw take: compared in 1–3 kHz, where the high-pass and EQ shift phase by well under a sample.
        let range = Int(take.phrases[0].start * 48_000)..<Int((take.phrases[0].start + 3) * 48_000)
        let lag = bestLag(bandPass(raw), bandPass(stem), range: range, maxLag: 300)
        print("LAG \(strength.rawValue): \(lag) frames")
        #expect(abs(lag) <= 1, "stem is \(lag) frames off")
        #expect(VoiceStem.status(bundle: b, settings: settings(strength)) == .ready)
    }
    // Stronger never cleans less.
    #expect((results[.light] ?? 0) <= (results[.medium] ?? 0) + 0.5)
    #expect((results[.medium] ?? 0) <= (results[.strong] ?? 0) + 0.5)
    // Only the latest stem file is kept.
    let files = try FileManager.default.contentsOfDirectory(atPath: b.voiceDirectory.path).filter { $0.hasSuffix(".caf") }
    #expect(files.count == 1, "\(files)")
}

@Test func mixZeroReproducesTheRawMicrophone() async throws {
    let take = try VoiceFixture.take(seconds: 8)
    let b = try await VoiceFixture.bundle(microphone: take.noisy, seconds: 8)
    defer { try? FileManager.default.removeItem(at: b.url) }
    let info = try await VoiceStem.render(bundle: b, settings: settings(.max, mix: 0))
    let raw = try await VoiceFixture.decodeMono(b.resolve("microphone/microphone.m4a"))
    let stem = try await VoiceFixture.decodeMono(b.resolve(info.file))
    #expect(stem.count == raw.count)
    var signal = 0.0, residual = 0.0
    for i in 0..<min(raw.count, stem.count) { signal += Double(raw[i] * raw[i]); residual += Double((raw[i] - stem[i]) * (raw[i] - stem[i])) }
    let db = 10 * log10(residual / signal + 1e-30)
    print(String(format: "NULL mix 0: residual %.1f dB", db))
    #expect(db <= -60)

    // Half mix sits between: still aligned (the raw half carries a click at its exact place).
    var clicky = take.noisy
    let at = 48_000 + 77
    clicky[at] = 0.95
    try await DemoFixture.writePCM(url: b.resolve("microphone/microphone.m4a"), samples: clicky)
    let half = try await VoiceStem.render(bundle: b, settings: settings(.medium, mix: 0.5))
    let raw2 = try await VoiceFixture.decodeMono(b.resolve("microphone/microphone.m4a"))
    let stem2 = try await VoiceFixture.decodeMono(b.resolve(half.file))
    var rp = 0, sp = 0
    for i in 40_000..<60_000 { if abs(raw2[i]) > abs(raw2[rp]) { rp = i }; if abs(stem2[i]) > abs(stem2[sp]) { sp = i } }
    print("CLICK mix 0.5: raw peak at \(rp), stem peak at \(sp)")
    #expect(abs(rp - sp) <= 1)
}
