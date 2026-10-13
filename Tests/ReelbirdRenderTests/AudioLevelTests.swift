@preconcurrency import AVFoundation
import Foundation
import Testing
import ReelbirdCore
@testable import ReelbirdRender

/// Speech-like test signal at 48 kHz: voiced "syllables" (harmonics of a gliding 140 Hz fundamental under a
/// Hann envelope) with short gaps, longer pauses between phrases, and a few plosive spikes 20 dB over the
/// voice, scaled so the voiced parts sit at `voicedRMSDB`.
private func speech(seconds: Double, voicedRMSDB: Double) -> [Float] {
    let rate = 48_000.0
    var out = [Float](repeating: 0, count: Int(seconds * rate))
    var t = 0.1
    var syllable = 0
    var seed: UInt32 = 7
    func rnd() -> Double { seed = seed &* 1_664_525 &+ 1_013_904_223; return Double(seed >> 8) / Double(1 << 24) }
    var voiced: [ClosedRange<Int>] = []
    while t < seconds - 0.4 {
        let len = 0.14 + 0.12 * rnd()
        let start = Int(t * rate), n = Int(len * rate)
        let f0 = 120 + 50 * rnd()
        for i in 0..<n where start + i < out.count {
            let tt = Double(i) / rate
            let env = 0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(n))
            var v = 0.0
            for h in 1...8 { v += sin(2 * .pi * f0 * Double(h) * (1 + 0.1 * tt) * tt) / Double(h) }
            out[start + i] = Float(v * env * (0.6 + 0.4 * rnd()))
        }
        voiced.append(start...min(out.count - 1, start + n))
        syllable += 1
        t += len + (syllable % 4 == 0 ? 0.45 : 0.06)
    }
    var sum = 0.0, count = 0
    for r in voiced { for i in r { sum += Double(out[i] * out[i]) }; count += r.count }
    let scale = Float(pow(10, voicedRMSDB / 20) / (sum / Double(max(1, count))).squareRoot())
    for i in out.indices { out[i] *= scale }
    // Plosives: 3 ms spikes 20 dB over the voiced RMS.
    let spike = Float(pow(10, (voicedRMSDB + 20) / 20))
    for (k, r) in voiced.enumerated() where k % 5 == 2 {
        for i in 0..<144 where r.lowerBound + i < out.count { out[r.lowerBound + i] += spike * (i % 24 < 12 ? 1 : -1) * Float(1 - Double(i) / 144) }
    }
    return out
}

/// Decodes a file's audio to interleaved stereo Float32 at 48 kHz.
private func decodeStereo(_ url: URL) async throws -> [Float] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    // Blocking decode: off the cooperative pool (see BlockingWork).
    return try await BlockingWork.run("test.decode") { _ in
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

private func measure(_ stereo: [Float]) -> (lufs: Double?, peakDB: Double) {
    var m = LoudnessMeter(sampleRate: 48_000, channels: 2)
    m.process(stereo)
    let peak = stereo.reduce(Float(0)) { max($0, abs($1)) }
    return (m.integratedLUFS, 20 * log10(Double(max(peak, 1e-9))))
}

/// A synthetic bundle whose microphone holds `samples`.
private func bundle(microphone samples: [Float], seconds: Double) async throws -> ProjectBundle {
    var o = Synthetic.Options()
    o.width = 320; o.height = 180; o.seconds = seconds
    let b = try await Synthetic.makeBundle(o)
    try await DemoFixture.writePCM(url: b.directory(for: .microphone).appendingPathComponent("microphone.m4a"), samples: samples)
    return b
}

// MARK: - Limiter

@Test func limiterHoldsTheCeilingAndDelaysByItsLatency() {
    let rate = 48_000.0
    let limiter = PeakLimiter(channels: 2, sampleRate: rate)
    #expect(limiter.latency == 240)
    // Speech-like signal boosted 24 dB: far over full scale.
    let mono = speech(seconds: 3, voicedRMSDB: -20)
    var stereo: [Float] = []
    for x in mono { stereo.append(x * 15.85); stereo.append(-x * 15.85) }
    let inPeak = stereo.reduce(Float(0)) { max($0, abs($1)) }
    #expect(inPeak > 2)
    // Uneven buffer sizes, like a real audio thread.
    var pos = 0
    stereo.withUnsafeMutableBufferPointer { p in
        var k = 0
        while pos < mono.count {
            let n = min(mono.count - pos, [512, 37, 1024, 480][k % 4])
            let base = p.baseAddress! + pos * 2
            limiter.process(frames: n, stride: 2) { base + $0 }
            pos += n; k += 1
        }
    }
    var maxSample: Float = 0, maxInter: Float = 0
    for i in 2..<(stereo.count / 2 - 1) {
        maxSample = max(maxSample, abs(stereo[2 * i]))
        maxInter = max(maxInter, PeakLimiter.interSamplePeak(stereo[2 * i - 4], stereo[2 * i - 2], stereo[2 * i], stereo[2 * i + 2]))
    }
    #expect(maxSample <= AudioDSP.ceiling * 1.0001, "sample peak \(maxSample)")
    #expect(maxInter <= AudioDSP.ceiling * 1.02, "inter-sample peak \(maxInter)")

    // Quiet audio passes untouched, delayed by exactly `latency` frames.
    let quiet = PeakLimiter(channels: 1, sampleRate: rate)
    var x = (0..<4_800).map { Float(0.3 * sin(Double($0) * 0.05)) }
    let original = x
    x.withUnsafeMutableBufferPointer { p in quiet.process(frames: p.count, stride: 1) { _ in p.baseAddress! } }
    #expect(x.prefix(240).allSatisfy { $0 == 0 })
    let maxError = (240..<4_800).map { abs(x[$0] - original[$0 - 240]) }.max() ?? 1
    #expect(maxError < 1e-6, "quiet audio changed by \(maxError)")
    #expect(quiet.takeMinimumGain() == 1)
}

// MARK: - Track processor (the preview/export tap)

@Test func trackProcessorAppliesGainLiveAndLimits() throws {
    let rate = 48_000.0
    let processor = AudioTrackProcessor(kind: .microphone, gain: 2)
    var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                           mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                           mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
                                           mBitsPerChannel: 32, mReserved: 0)
    processor.prepare(format: asbd)
    let frames = 1_024
    let data = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    defer { data.deallocate() }
    let list = AudioBufferList.allocate(maximumBuffers: 1)
    defer { free(list.unsafeMutablePointer) }
    func run(_ fill: (Int) -> Float) -> [Float] {
        for i in 0..<frames { data[i] = fill(i) }
        list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: data)
        processor.process(list.unsafeMutablePointer, frames: frames)
        return Array(UnsafeBufferPointer(start: data, count: frames))
    }
    // Constant 0.1 at gain 2 → 0.2 once the look-ahead delay has passed.
    _ = run { _ in 0.1 }
    let steady = run { _ in 0.1 }
    #expect(steady.allSatisfy { abs($0 - 0.2) < 1e-5 }, "steady \(steady[0])…\(steady[frames - 1])")
    // A live gain change ramps across one buffer, then holds.
    processor.gain = 4
    _ = run { _ in 0.1 }
    let after = run { _ in 0.1 }
    #expect(after.suffix(700).allSatisfy { abs($0 - 0.4) < 1e-5 }, "after change \(after[frames - 1])")
    // Gain that would clip is limited to the ceiling.
    processor.gain = 30
    for _ in 0..<4 { _ = run { _ in 0.1 } }
    let limited = run { _ in 0.1 }
    #expect(limited.allSatisfy { $0 <= AudioDSP.ceiling * 1.0001 }, "limited \(limited.max() ?? 0)")
    #expect(limited.last.map { $0 > AudioDSP.ceiling * 0.98 } == true)

    // Interleaved stereo works too.
    asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
    asbd.mChannelsPerFrame = 2; asbd.mBytesPerFrame = 8; asbd.mBytesPerPacket = 8
    let stereo = AudioTrackProcessor(kind: .systemAudio, gain: 0.5)
    stereo.prepare(format: asbd)
    let sdata = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
    defer { sdata.deallocate() }
    for _ in 0..<2 {
        for i in 0..<(frames * 2) { sdata[i] = 0.8 }
        list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: sdata)
        stereo.process(list.unsafeMutablePointer, frames: frames)
    }
    #expect(abs(sdata[frames * 2 - 1] - 0.4) < 1e-5 && abs(sdata[0] - 0.4) < 1e-5)

    // Taps can be made and released (the tap owns a reference to its processor).
    weak var weakProcessor: AudioTrackProcessor?
    do {
        let p = AudioTrackProcessor(kind: .microphone, gain: 1)
        weakProcessor = p
        let tap = p.makeTap(forPlayback: true)
        #expect(tap != nil)
        _ = tap
    }
    #expect(weakProcessor == nil, "tap leaked its processor")
}

// MARK: - Analysis and export

@Test func analysisIsCachedAndAutoLevelBringsAQuietVoiceToTarget() async throws {
    let seconds = 8.0
    let b = try await bundle(microphone: speech(seconds: seconds, voicedRMSDB: -34), seconds: seconds)
    defer { try? FileManager.default.removeItem(at: b.url) }

    let started = Date()
    let analysis = try #require(await AudioAnalyzer.analysis(bundle: b))
    let elapsed = Date().timeIntervalSince(started)
    let mic = try #require(analysis.microphone)
    let lufs = try #require(mic.integratedLUFS)
    let gain = try #require(EditDocument().audio.autoLevelGainDB(analysis))
    print(String(format: "ANALYSIS voice %.1f LUFS, peak %.1f dBFS, auto level %+.1f dB, %.0f ms", lufs, mic.peakDBFS ?? -999, gain, elapsed * 1000))
    #expect(lufs < -30 && lufs > -45)
    #expect(gain > 12)
    // Written once, then read back from analysis.json.
    #expect(FileManager.default.fileExists(atPath: b.analysisURL.path))
    #expect(AudioAnalyzer.cached(bundle: b, manifest: try b.readManifest()) == analysis)
    #expect(await AudioAnalyzer.analysis(bundle: b) == analysis)

    // Export with auto level on: the voice lands near −16 LUFS and peaks stay under −1 dBFS.
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent("rb-level-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: dest) }
    // Enhance off: this test is about auto level on the raw voice (VoiceStemTests cover the enhanced path).
    var plain = try b.readEdit()
    plain.audio.enhance = false
    _ = try await Exporter.export(bundle: b, edit: plain, options: ExportOptions(format: .mp4H264, destination: dest)) { _ in }
    let on = measure(try await decodeStereo(dest))
    let onLUFS = try #require(on.lufs)
    print(String(format: "EXPORT auto level: %.2f LUFS, peak %.2f dBFS", onLUFS, on.peakDB))
    #expect(abs(onLUFS - AutoLevel.targetLUFS) <= 1.5, "export loudness \(onLUFS)")
    #expect(on.peakDB <= -0.9, "export peak \(on.peakDB) dBFS")

    // Auto level off: the recording's own (quiet) level.
    var edit = plain
    edit.audio.autoLevel = false
    try FileManager.default.removeItem(at: dest)
    _ = try await Exporter.export(bundle: b, edit: edit, options: ExportOptions(format: .mp4H264, destination: dest)) { _ in }
    let off = measure(try await decodeStereo(dest))
    let offLUFS = try #require(off.lufs)
    print(String(format: "EXPORT auto level off: %.2f LUFS, peak %.2f dBFS", offLUFS, off.peakDB))
    #expect(abs(offLUFS - lufs) <= 1, "unprocessed export \(offLUFS) vs analysed \(lufs)")

    // A big manual boost on a loud voice still never clips.
    edit.audio.microphoneGainDB = 12
    edit.audio.autoLevel = true
    try FileManager.default.removeItem(at: dest)
    _ = try await Exporter.export(bundle: b, edit: edit, options: ExportOptions(format: .mp4H264, destination: dest)) { _ in }
    let hot = measure(try await decodeStereo(dest))
    print(String(format: "EXPORT +12 dB boost on top: %.2f LUFS, peak %.2f dBFS", hot.lufs ?? -99, hot.peakDB))
    #expect(hot.peakDB <= -0.9, "boosted export peak \(hot.peakDB) dBFS")
}

@Test func analysisRemeasuresWhenTheMicrophoneFileChanges() async throws {
    let b = try await bundle(microphone: speech(seconds: 3, voicedRMSDB: -30), seconds: 3)
    defer { try? FileManager.default.removeItem(at: b.url) }
    let first = try #require(await AudioAnalyzer.analysis(bundle: b)?.microphone?.integratedLUFS)
    try await DemoFixture.writePCM(url: b.directory(for: .microphone).appendingPathComponent("microphone.m4a"),
                                   samples: speech(seconds: 3.5, voicedRMSDB: -20))
    let second = try #require(await AudioAnalyzer.analysis(bundle: b)?.microphone?.integratedLUFS)
    #expect(second - first > 8, "first \(first), second \(second)")
}

// MARK: - Preview

@MainActor
@Test func previewAppliesTheSameGainsLive() async throws {
    let b = try await bundle(microphone: speech(seconds: 3, voicedRMSDB: -36), seconds: 3)
    defer { try? FileManager.default.removeItem(at: b.url) }
    let player = try PreviewPlayer(bundle: b)
    let start = Date()
    while player.audioAnalysis == nil, Date().timeIntervalSince(start) < 10 { try await Task.sleep(for: .milliseconds(20)) }
    let analysis = try #require(player.audioAnalysis)
    var edit = try b.readEdit()
    let expected = edit.audio.linearGain(for: .microphone, analysis: analysis)
    #expect(expected > 4, "auto level gain \(expected)")
    #expect(abs((player.audioGain(for: .microphone) ?? 0) - expected) < 1e-4)

    // Boost and mute change the running tap's gain without rebuilding the item.
    let item = player.currentItemForTesting
    edit.audio.microphoneGainDB = 6
    player.update(edit: edit)
    #expect(abs((player.audioGain(for: .microphone) ?? 0) - expected * 1.9953) < 1e-3)
    edit.audio.microphoneMuted = true
    player.update(edit: edit)
    #expect(player.audioGain(for: .microphone) == 0)
    edit.audio.microphoneMuted = false
    edit.audio.autoLevel = false
    edit.audio.microphoneGainDB = 0
    player.update(edit: edit)
    #expect(player.audioGain(for: .microphone) == 1)
    #expect(player.currentItemForTesting === item)

    // Playing with the tap in place advances normally (once the item is ready: before that, AVPlayer starts ~0.3 s late).
    while player.currentItemForTesting?.status != .readyToPlay, Date().timeIntervalSince(start) < 10 { try await Task.sleep(for: .milliseconds(20)) }
    player.play()
    try await Task.sleep(for: .milliseconds(400))
    #expect(player.currentTime > 0.1, "played to \(player.currentTime)")
    player.pause()
}
