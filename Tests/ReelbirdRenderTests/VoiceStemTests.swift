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
    // Speed is measured on 60 s (medium); the other strengths run on the first 20 s to keep the suite light.
    let seconds = 60.0
    let take = try VoiceFixture.take(seconds: seconds, speechDB: -24, snrDB: 20)
    let b = try await VoiceFixture.bundle(microphone: take.noisy, seconds: seconds)
    defer { try? FileManager.default.removeItem(at: b.url) }
    let rawURL = b.resolve("microphone/microphone.m4a")
    let raw = try await VoiceFixture.decodeMono(rawURL)
    let rawFloor = VoiceFixture.floorDB(raw, frames: take.noiseFrames)
    let rawSpeech = VoiceFixture.levelDB(raw, frames: take.speechFrames)
    print(String(format: "RAW noise floor %.1f dB, speech %.1f dB", rawFloor, rawSpeech))

    let shortSeconds = 20.0
    let short = try await VoiceFixture.bundle(microphone: Array(take.noisy.prefix(Int(shortSeconds * 48_000))), seconds: shortSeconds)
    defer { try? FileManager.default.removeItem(at: short.url) }
    var results: [EnhanceStrength: Double] = [:]
    for strength in [EnhanceStrength.medium, .light, .strong, .max] {
        let full = strength == .medium
        let b = full ? b : short
        let seconds = full ? seconds : shortSeconds
        let raw = full ? raw : Array(raw.prefix(Int(shortSeconds * 48_000)))
        let take = full ? take : VoiceFixture.Take(clean: [], noise: [], noisy: [], speechFrames: take.speechFrames.filter { $0 < Int(shortSeconds * 100) - 1 },
                                                   noiseFrames: take.noiseFrames.filter { $0 < Int(shortSeconds * 100) - 1 },
                                                   phrases: take.phrases)
        let rawFloor = VoiceFixture.floorDB(raw, frames: take.noiseFrames)
        let rawSpeech = VoiceFixture.levelDB(raw, frames: take.speechFrames)
        let started = Date()
        let info = try await VoiceStem.render(bundle: b, settings: settings(strength))
        let elapsed = Date().timeIntervalSince(started)
        let stem = try await VoiceFixture.decodeMono(b.resolve(info.file))
        #expect(abs(stem.count - raw.count) <= 1, "stem \(stem.count) frames vs raw \(raw.count)")
        let floor = VoiceFixture.floorDB(stem, frames: take.noiseFrames)
        let speech = VoiceFixture.levelDB(stem, frames: take.speechFrames)
        let drop = rawFloor - floor
        results[strength] = drop
        print(String(format: "STEM %@ (%@): noise floor %.1f dB (−%.1f dB), speech %.1f dB (%+.1f), %.2f s for %.0f s = %.0f× real time",
                     strength.rawValue, info.engine, floor, drop, speech, speech - rawSpeech, elapsed, seconds, seconds / elapsed))
        if full { #expect(seconds / elapsed > 10, "render speed \(seconds / elapsed)× real time") }
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
    let files = try FileManager.default.contentsOfDirectory(atPath: short.voiceDirectory.path).filter { $0.hasSuffix(".caf") }
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

// MARK: - Voice activity and ducking

@Test func voiceActivityFindsThePhrases() throws {
    let take = try VoiceFixture.take(seconds: 30, speechDB: -24, snrDB: 15)
    // 10 ms frame levels at 48 kHz (the analyzer works at 16 kHz; the detector only sees levels).
    let frame = 480
    var levels: [Float] = []
    var hp = Biquad.highPass(frequency: 100, q: 0.7071, sampleRate: 48_000)
    for f in 0..<(take.noisy.count / frame) {
        var s = 0.0
        for i in (f * frame)..<((f + 1) * frame) { let y = hp.run(Double(take.noisy[i])); s += y * y }
        levels.append(Float(10 * log10(s / Double(frame) + 1e-12)))
    }
    let speech = VoiceActivity.detect(frameDB: levels)
    func covered(_ t: Double) -> Bool { speech.contains { $0.contains(t) } }
    var inPhrase = 0, hit = 0, inPause = 0, falseHit = 0
    var t = 0.0
    while t < 30 {
        if take.phrases.contains(where: { $0.contains(t) }) { inPhrase += 1; if covered(t) { hit += 1 } }
        else if !take.phrases.contains(where: { t > $0.start - 0.3 && t < $0.end + 0.5 }) { inPause += 1; if covered(t) { falseHit += 1 } }
        t += 0.01
    }
    let recall = Double(hit) / Double(max(1, inPhrase)), falseRate = Double(falseHit) / Double(max(1, inPause))
    print(String(format: "VAD: %d ranges, recall %.1f%%, speech found in pauses %.1f%%", speech.count, recall * 100, falseRate * 100))
    #expect(recall > 0.85)
    #expect(falseRate < 0.1)
}

@Test func duckCurveRampsAroundSpeechAndFollowsTheEdit() {
    let curve = DuckCurve(outputRanges: [TimeRange(start: 2, end: 4), TimeRange(start: 4.2, end: 5)])
    #expect(curve.ranges.count == 2)
    func db(_ t: Double) -> Double { 20 * log10(Double(curve.gain(at: t))) }
    #expect(abs(db(1.9)) < 1e-4)
    #expect(abs(db(1.99) + 6) < 0.01)          // halfway through the 20 ms attack, which ends at the onset
    #expect(abs(db(3) + 12) < 1e-4)
    #expect(db(4.1) < -9.5)                     // a short gap stays mostly ducked
    #expect(abs(db(5.3) + 6) < 0.01)            // halfway through the 600 ms release
    #expect(abs(db(5.61)) < 1e-4)
    // Mapping through a cut: speech at 10–12 s on the recording, 9–11 s cut out of a 0–20 s recording.
    let timeline = EditTimeline(duration: 20, trim: nil, cuts: [TimeRange(start: 9, end: 11)])
    let mapped = DuckCurve(recordingRanges: [TimeRange(start: 10, end: 12)], timeline: timeline)
    #expect(mapped.ranges == [TimeRange(start: 9, end: 10)])
}

@Test func trackProcessorDucksOnTheOutputClock() {
    let rate = 48_000.0
    let p = AudioTrackProcessor(kind: .systemAudio, gain: 1)
    p.prepare(format: AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                  mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                                  mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
                                                  mBitsPerChannel: 32, mReserved: 0))
    p.duck = DuckCurve(outputRanges: [TimeRange(start: 1, end: 2)])
    let frames = 1_024
    let data = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    defer { data.deallocate() }
    let list = AudioBufferList.allocate(maximumBuffers: 1)
    defer { free(list.unsafeMutablePointer) }
    func level(at t: Double) -> Double {
        for i in 0..<frames { data[i] = 0.1 }
        list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: data)
        p.process(list.unsafeMutablePointer, frames: frames, time: t)
        return 20 * log10(Double(data[frames - 1]) / 0.1)
    }
    _ = level(at: 0.5)
    #expect(abs(level(at: 0.5)) < 0.01)
    _ = level(at: 1.5)
    #expect(abs(level(at: 1.5) + 12) < 0.05)
    _ = level(at: 3)
    #expect(abs(level(at: 3)) < 0.01)
}

/// Level (dB) of a sine at `frequency` in `x[range]` (Hann-windowed Goertzel, amplitude-calibrated).
private func toneDB(_ x: [Float], frequency: Double, range: Range<Int>, rate: Double = 48_000) -> Double {
    let n = range.count
    let w = 2 * Double.pi * frequency / rate
    var s1 = 0.0, s2 = 0.0, wsum = 0.0
    for (k, i) in range.enumerated() {
        let win = 0.5 - 0.5 * cos(2 * .pi * Double(k) / Double(n - 1))
        wsum += win
        let s0 = Double(x[i]) * win + 2 * cos(w) * s1 - s2
        s2 = s1; s1 = s0
    }
    let power = s1 * s1 + s2 * s2 - 2 * cos(w) * s1 * s2
    return 20 * log10(2 * power.squareRoot() / wsum + 1e-12)
}

private func stereoToMono(_ s: [Float]) -> [Float] { stride(from: 0, to: s.count - 1, by: 2).map { (s[$0] + s[$0 + 1]) / 2 } }

@Test func exportDucksSystemAudioUnderTheVoiceAndLandsOnTarget() async throws {
    let seconds = 20.0
    let take = try VoiceFixture.take(seconds: seconds, speechDB: -30, snrDB: 20)
    // System audio: a 55 Hz tone (below the voice's high-pass) at −20 dBFS throughout.
    let tone = (0..<Int(seconds * 48_000)).map { Float(0.1 * sin(2 * Double.pi * 55 * Double($0) / 48_000)) }
    let b = try await VoiceFixture.bundle(microphone: take.noisy, seconds: seconds, systemAudio: tone)
    defer { try? FileManager.default.removeItem(at: b.url) }
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent("rb-duck-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: dest) }

    var edit = try b.readEdit()
    edit.audio.systemMuted = true
    // Voice alone, enhanced: loudness on target, peaks under the ceiling.
    _ = try await Exporter.export(bundle: b, edit: edit, options: ExportOptions(format: .mp4H264, destination: dest)) { _ in }
    #expect(VoiceStem.status(bundle: b, settings: edit.audio) == .ready, "export renders the stem first")
    let voiceOnly = try await VoiceFixture.decodeStereo(dest)
    var meter = LoudnessMeter(sampleRate: 48_000, channels: 2)
    meter.process(voiceOnly)
    let lufs = try #require(meter.integratedLUFS)
    let peak = 20 * log10(Double(voiceOnly.reduce(Float(0)) { max($0, abs($1)) }))
    print(String(format: "EXPORT enhanced voice: %.2f LUFS, sample peak %.2f dBFS", lufs, peak))
    #expect(abs(lufs - AutoLevel.targetLUFS) <= 1, "loudness \(lufs)")
    #expect(peak <= -1.4, "peak \(peak) dBFS")

    // With system audio: the tone dips ~12 dB while speaking and comes back in pauses.
    func measureDuck(_ duck: Bool) async throws -> (speech: Double, pause: Double) {
        var e = edit
        e.audio.systemMuted = false
        e.audio.duckSystemAudio = duck
        try? FileManager.default.removeItem(at: dest)
        _ = try await Exporter.export(bundle: b, edit: e, options: ExportOptions(format: .mp4H264, destination: dest)) { _ in }
        let mono = stereoToMono(try await VoiceFixture.decodeStereo(dest))
        var speech: [Double] = [], pause: [Double] = []
        for (i, p) in take.phrases.enumerated() {
            let mid = Int((p.start + p.end) / 2 * 48_000)
            speech.append(toneDB(mono, frequency: 55, range: (mid - 4_800)..<(mid + 4_800)))
            let next = i + 1 < take.phrases.count ? take.phrases[i + 1].start : seconds
            if next - p.end > 1.2 {
                let a = Int((p.end + 0.9) * 48_000), z = Int((next - 0.1) * 48_000)
                if z - a > 9_600 { pause.append(toneDB(mono, frequency: 55, range: a..<z)) }
            }
        }
        return (speech.reduce(0, +) / Double(speech.count), pause.reduce(0, +) / Double(max(1, pause.count)))
    }
    let on = try await measureDuck(true)
    let off = try await measureDuck(false)
    print(String(format: "DUCK on: tone %.1f dB in speech, %.1f dB in pauses (dip %.1f dB); off: %.1f / %.1f dB",
                 on.speech, on.pause, on.pause - on.speech, off.speech, off.pause))
    #expect(abs((on.pause - on.speech) - 12) <= 2, "duck depth \(on.pause - on.speech) dB")
    #expect(abs(on.pause - off.pause) <= 1, "pauses recover: \(on.pause) vs \(off.pause)")
    #expect(abs(off.speech - off.pause) <= 1, "no duck when off")
}

// MARK: - Preview

@MainActor
@Test func previewSwitchesToTheStemAndHearsTheOriginal() async throws {
    let take = try VoiceFixture.take(seconds: 6)
    let b = try await VoiceFixture.bundle(microphone: take.noisy, seconds: 6)
    defer { try? FileManager.default.removeItem(at: b.url) }
    let player = try PreviewPlayer(bundle: b)
    let start = Date()
    while player.audioAnalysis == nil, Date().timeIntervalSince(start) < 10 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(player.voiceFile == "microphone/microphone.m4a", "raw microphone until the stem exists")
    player.play()
    try await Task.sleep(for: .milliseconds(300))

    let info = try await VoiceStem.render(bundle: b, settings: AudioSettings())
    player.voiceStemDidChange()
    while player.voiceFile != info.file, Date().timeIntervalSince(start) < 15 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(player.voiceFile == info.file)
    try await Task.sleep(for: .milliseconds(200))
    #expect(player.isPlaying, "keeps playing across the switch")
    #expect((player.audioGain(for: .microphone) ?? 0) > 0)
    #expect(player.audioGain(for: .microphone, original: true) == 0)
    player.hearOriginal = true
    #expect(player.audioGain(for: .microphone) == 0)
    #expect((player.audioGain(for: .microphone, original: true) ?? 0) > 0)
    player.hearOriginal = false
    player.pause()

    // Enhance off: back to the raw microphone only.
    var edit = try b.readEdit()
    edit.audio.enhance = false
    player.update(edit: edit)
    while player.voiceFile != "microphone/microphone.m4a", Date().timeIntervalSince(start) < 20 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(player.voiceFile == "microphone/microphone.m4a")
}
