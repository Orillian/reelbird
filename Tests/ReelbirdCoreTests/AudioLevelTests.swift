import Foundation
import Testing
@testable import ReelbirdCore

/// A sine with the given RMS level in dBFS.
private func sine(rmsDB: Double, freq: Double = 997, seconds: Double, rate: Double) -> [Float] {
    let amp = pow(10, rmsDB / 20) * 2.0.squareRoot()
    return (0..<Int(seconds * rate)).map { Float(amp * sin(2 * .pi * freq * Double($0) / rate)) }
}

private func loudness(_ samples: [Float], rate: Double, channels: Int = 1) -> Double? {
    var m = LoudnessMeter(sampleRate: rate, channels: channels)
    // Odd chunk sizes: streaming must not depend on how buffers are cut.
    var i = 0
    while i < samples.count {
        let n = min(samples.count - i, 1_013 * channels)
        samples[i..<(i + n)].withUnsafeBufferPointer { m.process($0, frameCount: n / channels) }
        i += n
    }
    return m.integratedLUFS
}

@Test func sineMeasuresItsRMSLevel() throws {
    // BS.1770 is calibrated so a 997 Hz sine reads its RMS level in LUFS (mono).
    for rate in [16_000.0, 48_000.0] {
        for db in [-30.0, -20.0, -12.0] {
            let l = try #require(loudness(sine(rmsDB: db, seconds: 3, rate: rate), rate: rate))
            #expect(abs(l - db) < 0.2, "\(rate) Hz: \(db) dBFS sine measured \(l) LUFS")
        }
    }
    // A low hum counts for much less (K-weighting high-pass).
    let hum = try #require(loudness(sine(rmsDB: -20, freq: 30, seconds: 3, rate: 48_000), rate: 48_000))
    #expect(hum < -22, "30 Hz hum \(hum)")
}

@Test func quietVoiceGetsTheExpectedMakeUpGain() throws {
    // −30 dBFS RMS mono → −30 LUFS mono → −27 LUFS on two speakers → +11 dB to reach −16.
    let mono = try #require(loudness(sine(rmsDB: -30, seconds: 4, rate: 16_000), rate: 16_000))
    let gain = AutoLevel.gainDB(integratedLUFS: mono + AutoLevel.monoOnStereoDB)
    #expect(abs(gain - 11) <= 1, "gain \(gain)")
    // Caps: never more than +18, never less than −6, and nothing for silence.
    #expect(AutoLevel.gainDB(integratedLUFS: -60) == 18)
    #expect(AutoLevel.gainDB(integratedLUFS: -3) == -6)
    #expect(AutoLevel.gainDB(integratedLUFS: nil) == 0)
}

@Test func gatingIgnoresPausesBetweenWords() throws {
    let rate = 16_000.0
    let tone = sine(rmsDB: -24, seconds: 1, rate: rate)
    let pause = [Float](repeating: 0, count: Int(2 * rate))
    var speech: [Float] = []
    for _ in 0..<5 { speech += tone + pause }
    let gated = try #require(loudness(speech, rate: rate))
    // Ungated, the pauses would pull this to −28.8; blocks that straddle a word's edge still count (≈ −1 dB).
    #expect(abs(gated - -24) < 1.5, "speech with pauses measured \(gated)")
    // Faint room noise in the pauses (−60 dBFS) is gated out too.
    var noisy = speech
    var seed: UInt32 = 1
    for i in noisy.indices where noisy[i] == 0 {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        noisy[i] = (Float(seed >> 8) / Float(1 << 24) * 2 - 1) * 0.0017
    }
    let withNoise = try #require(loudness(noisy, rate: rate))
    #expect(abs(withNoise - gated) < 0.5, "noise \(withNoise) vs clean \(gated)")
    // Silence is nil.
    #expect(loudness([Float](repeating: 0, count: Int(rate * 2)), rate: rate) == nil)
}

@Test func stereoMeasuresTwoChannels() throws {
    let rate = 48_000.0
    let mono = sine(rmsDB: -26, seconds: 2, rate: rate)
    var stereo: [Float] = []
    stereo.reserveCapacity(mono.count * 2)
    for x in mono { stereo.append(x); stereo.append(x) }
    let m = try #require(loudness(mono, rate: rate))
    let s = try #require(loudness(stereo, rate: rate, channels: 2))
    #expect(abs(s - m - AutoLevel.monoOnStereoDB) < 0.05)
}

@Test func audioSettingsAutoLevelAndGains() throws {
    // Old files (with the retired `denoise` key) load with auto level on; the key round-trips.
    let old = try JSONCoding.decoder.decode(AudioSettings.self, from: Data(#"{"denoise":true,"microphoneGainDB":3}"#.utf8))
    #expect(old.autoLevel && old.microphoneGainDB == 3)
    let off = try JSONCoding.decoder.decode(AudioSettings.self, from: Data(#"{"autoLevel":false}"#.utf8))
    #expect(!off.autoLevel)

    let analysis = AudioAnalysis(microphone: TrackLoudness(file: "microphone/microphone.m4a", fileSize: 10, integratedLUFS: -27,
                                                           peakDBFS: -12, duration: 3))
    var a = AudioSettings()
    a.microphoneGainDB = 2
    #expect(a.autoLevelGainDB(analysis) == 11)
    #expect(a.gainDB(for: .microphone, analysis: analysis) == 13)
    #expect(a.gainDB(for: .microphone, analysis: nil) == 2)
    a.autoLevel = false
    #expect(a.gainDB(for: .microphone, analysis: analysis) == 2)
    a.microphoneMuted = true
    #expect(a.gainDB(for: .microphone, analysis: analysis) == nil)
    #expect(a.linearGain(for: .microphone, analysis: analysis) == 0)
    a.systemGainDB = -6
    #expect(abs(a.linearGain(for: .systemAudio, analysis: nil) - 0.501) < 0.001)

    // analysis.json round-trips through the bundle; another version reads as missing.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rb-\(UUID().uuidString).reelbird")
    defer { try? FileManager.default.removeItem(at: dir) }
    let b = try ProjectBundle.create(at: dir)
    try b.writeAnalysis(analysis)
    #expect(b.readAnalysis() == analysis)
    var stale = analysis
    stale.version = 0
    try b.writeAnalysis(stale)
    #expect(b.readAnalysis() == nil)
}
