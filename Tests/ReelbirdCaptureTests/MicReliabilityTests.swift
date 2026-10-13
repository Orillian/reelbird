import Foundation
import ReelbirdCore
import Testing
@testable import ReelbirdCapture

// MARK: Synthetic PCM

/// Deterministic white noise (LCG) at a given RMS.
private struct Noise {
    var state: UInt32 = 0x1234_5678
    mutating func next() -> Float {
        state = state &* 1_664_525 &+ 1_013_904_223
        return Float(Int32(bitPattern: state)) / Float(Int32.max)   // uniform −1...1, RMS ≈ 0.577
    }
}

/// Feeds an analyzer 20 ms buffers of synthetic microphone input.
private struct MicFeeder {
    var analyzer = MicrophoneAnalyzer()
    var time = 100.0
    private var noise = Noise()
    private var phase = 0.0
    private var index = 0
    private var buffer = [Float](repeating: 0, count: 960)

    /// `speech`: amplitude of a 220 Hz "voice" gated 300 ms on / 200 ms off (nil = none).
    /// `noiseDB`: RMS of the background noise (nil = digital silence).
    mutating func run(seconds: Double, speech: Double? = nil, noiseDB: Double? = -70, paused: Bool = false,
                      every step: (MicrophoneAnalyzer, Double) -> Void = { _, _ in }) {
        let frames = buffer.count
        let noiseAmp = noiseDB.map { Float(pow(10, $0 / 20) / 0.577) } ?? 0
        let count = Int((seconds * 48_000 / Double(frames)).rounded())
        for _ in 0..<count {
            let gateOn = index % 25 < 15     // 20 ms buffers: 300 ms on, 200 ms off
            index += 1
            for k in 0..<frames {
                var v = noiseAmp * noise.next()
                if let speech, gateOn { v += Float(speech * sin(phase)) }
                phase += 2 * .pi * 220 / 48_000
                buffer[k] = max(-1, min(1, v))
            }
            buffer.withUnsafeBufferPointer { analyzer.ingest($0.baseAddress!, frames: frames, channels: 1, at: time, paused: paused) }
            time += Double(frames) / 48_000
            step(analyzer, time)
        }
    }
}

private func inputs(_ a: MicrophoneAnalyzer, now: Double, paused: Bool = false) -> HealthInputs {
    var i = HealthInputs(now: now)
    i.microphoneEnabled = true
    i.paused = paused
    i.microphoneClipEvents = a.clipEvents()
    i.microphoneTooQuiet = a.isTooQuiet()
    i.talkingWhilePaused = a.isTalkingWhilePaused()
    return i
}

// MARK: Ranking

@Suite struct MicRankingTests {
    let builtIn = MicCandidate(id: "bi", name: "MacBook Pro Microphone", transport: .builtIn, sampleRate: 48_000, isSystemDefault: true)
    let usb = MicCandidate(id: "usb", name: "Shure MV7+", transport: .interface, sampleRate: 48_000)
    let airpods = MicCandidate(id: "ap", name: "AirPods Pro", transport: .bluetooth, sampleRate: 24_000)
    let iphone = MicCandidate(id: "ip", name: "Sam's iPhone Microphone", transport: .continuity, sampleRate: 48_000)
    let zoom = MicCandidate(id: "zm", name: "ZoomAudioDevice", transport: .virtual, sampleRate: 48_000)
    let blackhole = MicCandidate(id: "bh", name: "BlackHole 2ch", transport: .unknown, sampleRate: 48_000)
    let webcam = MicCandidate(id: "cam", name: "C920 HD Pro Webcam", transport: .interface, sampleRate: 32_000, isCameraMic: true)

    @Test func interfaceBeatsBuiltInBeatsContinuityBeatsBluetooth() {
        let ranked = MicPolicy.rank([airpods, zoom, iphone, builtIn, usb, blackhole])
        #expect(ranked.map(\.id) == ["usb", "bi", "ip", "ap"])
        #expect(MicPolicy.best([airpods, builtIn])?.id == "bi")
        #expect(MicPolicy.best([airpods, iphone])?.id == "ip")
    }

    @Test func virtualDevicesAreNeverAutoPickedButCanBeChosen() {
        #expect(MicPolicy.rank([zoom, blackhole]).isEmpty)
        #expect(MicPolicy.best([zoom, builtIn])?.id == "bi")
        // Only virtual devices: something is better than nothing.
        #expect(MicPolicy.best([zoom, blackhole]) != nil)
        #expect(MicPolicy.resolve("zm", in: [zoom, builtIn])?.id == "zm")
    }

    @Test func webcamMicsRankBelowTheBuiltInArray() {
        #expect(MicPolicy.rank([webcam, builtIn, airpods]).map(\.id) == ["bi", "cam", "ap"])
    }

    @Test func resolveLocksAnExplicitDeviceAndFallsBackWhenItIsGone() {
        let all = [builtIn, usb, airpods]
        #expect(MicPolicy.resolve(MicPolicy.automaticID, in: all)?.id == "usb")
        #expect(MicPolicy.resolve(nil, in: all)?.id == "usb")
        #expect(MicPolicy.resolve("ap", in: all)?.id == "ap")
        #expect(MicPolicy.resolve(MicPolicy.systemDefaultID, in: all)?.id == "bi")
        #expect(MicPolicy.resolve("unplugged", in: all)?.id == "usb")
        #expect(MicPolicy.isMissing("unplugged", in: all))
        #expect(!MicPolicy.isMissing(MicPolicy.automaticID, in: all))
        // macOS making AirPods the default doesn't change Automatic.
        var apDefault = airpods; apDefault.isSystemDefault = true
        var biNot = builtIn; biNot.isSystemDefault = false
        #expect(MicPolicy.resolve(MicPolicy.automaticID, in: [biNot, apDefault])?.id == "bi")
    }

    @Test func callQualityAndAlternatives() {
        #expect(MicPolicy.isCallQuality(airpods))
        #expect(MicPolicy.isCallQuality(MicCandidate(id: "x", name: "Headset", transport: .bluetooth, sampleRate: 48_000)))
        #expect(MicPolicy.isCallQuality(MicCandidate(id: "y", name: "Odd USB", transport: .interface, sampleRate: 16_000)))
        #expect(!MicPolicy.isCallQuality(builtIn))
        #expect(MicPolicy.bestAlternative(to: airpods, in: [airpods, builtIn, usb])?.id == "usb")
        #expect(MicPolicy.bestAlternative(to: airpods, in: [airpods, zoom]) == nil)
        // Ties: system default first, then sample rate, then name.
        let a = MicCandidate(id: "a", name: "B Interface", transport: .interface, sampleRate: 44_100)
        let b = MicCandidate(id: "b", name: "A Interface", transport: .interface, sampleRate: 96_000)
        #expect(MicPolicy.rank([a, b]).map(\.id) == ["b", "a"])
    }

    @Test func transportCodesMap() {
        func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
        #expect(MicTransport(coreAudio: code("bltn")) == .builtIn)
        #expect(MicTransport(coreAudio: code("usb ")) == .interface)
        #expect(MicTransport(coreAudio: code("thun")) == .interface)
        #expect(MicTransport(coreAudio: code("blue")) == .bluetooth)
        #expect(MicTransport(coreAudio: code("blea")) == .bluetooth)
        #expect(MicTransport(coreAudio: code("ccwl")) == .continuity)
        #expect(MicTransport(coreAudio: code("virt")) == .virtual)
        #expect(MicTransport(coreAudio: code("grup")) == .virtual)
        #expect(MicTransport(coreAudio: 0) == .unknown)
    }

    @Test func mediaDeviceArrayHelpers() {
        let devices = [MediaDevice(id: "ap", name: "AirPods Pro", isDefault: true, transport: .bluetooth, sampleRate: 24_000),
                       MediaDevice(id: "bi", name: "MacBook Pro Microphone", isDefault: false, transport: .builtIn, sampleRate: 48_000)]
        #expect(devices.bestMicrophone?.id == "bi")
        #expect(devices[0].isCallQuality)
        #expect(devices.alternative(to: devices[0])?.id == "bi")
    }
}

// MARK: Health monitor on synthetic PCM

@Suite struct MicHealthTests {
    @Test func meterReadsPeakAndRMSInDBFS() {
        var f = MicFeeder()
        f.run(seconds: 0.3, speech: 0.5, noiseDB: nil)   // gate is on for the first 300 ms
        let r = f.analyzer.reading
        #expect(abs(r.peakDB - (-6.02)) < 0.5, "peak \(r.peakDB)")
        #expect(abs(r.rmsDB - (-9.03)) < 0.6, "rms \(r.rmsDB)")
        #expect(MicLevelReading.targetPeakRange.contains(r.peakDB))
        #expect(abs(MicLevelReading.meterPosition(-18) - 0.7) < 1e-9)
    }

    @Test func silenceThresholdSeparatesDeadInputsFromQuietRooms() {
        // −72 dBFS: digital silence and a muted interface are below; a quiet room (−65 dBFS) is above.
        #expect(Double(HealthMonitor.silenceRMS) < pow(10, -65.0 / 20))
        #expect(Double(HealthMonitor.silenceRMS) > pow(10, -80.0 / 20))
        var h = HealthMonitor()
        var i = HealthInputs(now: 2.9)
        i.microphoneEnabled = true
        i.microphoneSilentFor = 2.9
        #expect(h.evaluate(i).isEmpty, "not before 3 s")
        i.now = 3.2; i.microphoneSilentFor = 3.2
        #expect(h.evaluate(i).map(\.kind) == [.microphoneSilent])
        i.paused = true
        #expect(h.evaluate(i).isEmpty, "never while paused")
    }

    @Test func repeatedClippingWarnsAndASingleClipDoesNot() throws {
        var f = MicFeeder()
        var h = HealthMonitor()
        // One loud plosive (one burst) then normal speech.
        f.run(seconds: 0.3, speech: 1.0)
        f.run(seconds: 2.5, speech: 0.3)
        #expect(f.analyzer.clipEvents() == 0)
        var warned: Double?
        // Clipping on every syllable (bursts every 0.5 s).
        f.run(seconds: 2.5, speech: 1.0) { a, t in
            let w = h.evaluate(inputs(a, now: t))
            if warned == nil, w.contains(where: { $0.kind == .microphoneClipping }) { warned = t }
        }
        let after = try #require(warned) - 102.8
        #expect(after > 0.9 && after < 1.6, "warned after \(after) s")
        // Held while speech continues cleanly for a moment, then gone; `since` stays the same meanwhile.
        let since = h.evaluate(inputs(f.analyzer, now: f.time)).first { $0.kind == .microphoneClipping }?.since
        f.run(seconds: 3, speech: 0.3)
        let held = h.evaluate(inputs(f.analyzer, now: f.time)).first { $0.kind == .microphoneClipping }
        #expect(held?.since == since, "held for a few seconds")
        f.run(seconds: 3, speech: 0.3)
        #expect(!h.evaluate(inputs(f.analyzer, now: f.time)).contains { $0.kind == .microphoneClipping })
        // A new episode is a new warning.
        f.run(seconds: 2, speech: 1.0)
        let again = h.evaluate(inputs(f.analyzer, now: f.time)).first { $0.kind == .microphoneClipping }
        #expect(again != nil && again?.since != since)
    }

    @Test func quietSpeechWarnsAfterTenSeconds() {
        var f = MicFeeder()
        var h = HealthMonitor()
        var warnedAt: Double?
        // Speech peaking around −34 dBFS over a −75 dBFS room.
        f.run(seconds: 13, speech: 0.02, noiseDB: -75) { a, t in
            if warnedAt == nil, h.evaluate(inputs(a, now: t)).contains(where: { $0.kind == .microphoneTooQuiet }) { warnedAt = t - 100 }
        }
        #expect(warnedAt.map { $0 >= 10 && $0 < 11 } == true, "warned at \(String(describing: warnedAt))")
        // Speaking up clears it (after the short hold).
        f.run(seconds: 4, speech: 0.25, noiseDB: -75)
        #expect(!h.evaluate(inputs(f.analyzer, now: f.time)).contains { $0.kind == .microphoneTooQuiet })
    }

    @Test func goodLevelsAndSilentRoomsAreNotTooQuiet() {
        var good = MicFeeder()
        good.run(seconds: 12, speech: 0.2, noiseDB: -70)
        #expect(!good.analyzer.isTooQuiet())
        #expect(good.analyzer.clipEvents() == 0)
        var room = MicFeeder()
        room.run(seconds: 12, speech: nil, noiseDB: -62)    // nobody talking: nothing to judge
        #expect(!room.analyzer.isTooQuiet())
    }

    @Test func talkingWhilePausedWarnsAndClearsOnResume() {
        var f = MicFeeder()
        var h = HealthMonitor()
        f.run(seconds: 3, speech: 0.2, noiseDB: -70)
        f.run(seconds: 2, speech: nil, noiseDB: -70, paused: true)
        #expect(!h.evaluate(inputs(f.analyzer, now: f.time, paused: true)).contains { $0.kind == .talkingWhilePaused },
                "room noise alone is not talking")
        var warnedAfter: Double?
        let start = f.time
        f.run(seconds: 2, speech: 0.2, noiseDB: -70, paused: true) { a, t in
            if warnedAfter == nil, h.evaluate(inputs(a, now: t, paused: true)).contains(where: { $0.kind == .talkingWhilePaused }) {
                warnedAfter = t - start
            }
        }
        #expect(warnedAfter.map { $0 < 1.5 } == true, "warned after \(String(describing: warnedAfter))")
        // Resuming clears it at once (no hold), and talking while recording is fine.
        f.run(seconds: 0.2, speech: 0.2, noiseDB: -70)
        #expect(!h.evaluate(inputs(f.analyzer, now: f.time)).contains { $0.kind == .talkingWhilePaused })
    }

    @Test func disconnectedMicWarnsInsteadOfSilent() {
        var h = HealthMonitor()
        var i = HealthInputs(now: 10)
        i.microphoneEnabled = true
        i.lockedMicrophoneID = "usb"
        i.lockedMicrophoneName = "Shure MV7+"
        i.microphoneMissing = true
        i.microphoneSilentFor = 5
        let w = h.evaluate(i)
        #expect(w.map(\.kind) == [.microphoneDisconnected])
        #expect(w.first?.message == "Shure MV7+ disconnected. Your voice may be missing until it's back.")
        i.microphoneMissing = false
        i.microphoneSilentFor = 0
        #expect(h.evaluate(i).isEmpty, "reconnecting clears it")
    }

    @Test func systemInputSwitchIsANoticeThatEndsByItself() {
        var h = HealthMonitor()
        var i = HealthInputs(now: 1)
        i.microphoneEnabled = true
        i.lockedMicrophoneID = "bi"
        i.lockedMicrophoneName = "MacBook Pro Microphone"
        i.systemDefaultMicrophoneID = "usb"           // already different at start: no notice
        i.systemDefaultMicrophoneName = "Shure MV7+"
        #expect(h.evaluate(i).isEmpty)
        i.now = 5
        i.systemDefaultMicrophoneID = "ap"            // AirPods reconnect and macOS switches to them
        i.systemDefaultMicrophoneName = "AirPods Pro"
        let w = h.evaluate(i)
        #expect(w.map(\.kind) == [.microphoneChanged])
        #expect(w.first?.message == "macOS switched to AirPods Pro. Still recording from MacBook Pro Microphone.")
        i.now = 12
        #expect(h.evaluate(i).first?.since == 5)
        i.now = 13.1
        #expect(h.evaluate(i).isEmpty)
    }
}

// MARK: Silent-take detection

@Suite struct SilentTakeTests {
    private func summary(_ f: MicFeeder, active: Double) -> MicTakeSummary {
        MicTakeSummary(activeSeconds: active, soundSeconds: f.analyzer.soundSeconds)
    }

    @Test func deadAndMutedInputsAreSilentTakes() {
        var zeros = MicFeeder()
        zeros.run(seconds: 10, speech: nil, noiseDB: nil)
        #expect(summary(zeros, active: 10).isEssentiallySilent)
        var muted = MicFeeder()
        muted.run(seconds: 10, speech: nil, noiseDB: -85)
        #expect(summary(muted, active: 10).isEssentiallySilent)
        // Unplugged after 1 s: no buffers for the rest still counts as silent.
        var gone = MicFeeder()
        gone.run(seconds: 1, speech: 0.2)
        #expect(summary(gone, active: 20).isEssentiallySilent)
    }

    @Test func takesWithSomeSpeechAreKept() {
        var f = MicFeeder()
        f.run(seconds: 7, speech: nil, noiseDB: -75)
        f.run(seconds: 3, speech: 0.15, noiseDB: -75)   // talking 3 s of 10 (gated: ~18 % voiced)
        let s = summary(f, active: 10)
        #expect(!s.isEssentiallySilent, "silent fraction \(s.silentFraction)")
        var room = MicFeeder()
        room.run(seconds: 10, speech: nil, noiseDB: -55)  // a noisy room is not "nothing"
        #expect(!summary(room, active: 10).isEssentiallySilent)
        #expect(!MicTakeSummary(activeSeconds: 1.5, soundSeconds: 0).isEssentiallySilent, "too short to judge")
    }

    @Test func pausedTimeIsLeftOut() {
        var f = MicFeeder()
        f.run(seconds: 3, speech: 0.2)
        f.run(seconds: 30, speech: nil, noiseDB: nil, paused: true)
        #expect(abs(f.analyzer.activeSeconds - 3) < 0.05)
    }

    @Test func recordingSessionReportsLevelsAndTheTakeSummary() async throws {
        for (signal, silent) in [(SyntheticFrameSource.AudioSignal.sine(frequency: 440, amplitude: 0.25), false), (.silence, true)] {
            let url = tempBundleURL("mic-summary")
            defer { try? FileManager.default.removeItem(at: url) }
            var config = SyntheticFrameSource.Configuration()
            config.microphone = signal
            config.systemAudio = nil
            let session = RecordingSession(options: options(system: false), bundleURL: url, frameSource: SyntheticFrameSource(configuration: config))
            #expect(session.microphoneTakeSummary == nil)
            try await session.start()
            await sleep(2.6)
            let levels = session.microphoneLevels
            if silent {
                #expect(levels.peakDB == MicLevelReading.floorDB)
            } else {
                #expect(abs(levels.peakDB - (-12.04)) < 0.5, "peak \(levels.peakDB)")
            }
            _ = try await session.stop()
            let s = try #require(session.microphoneTakeSummary)
            #expect(s.activeSeconds > 2.4)
            #expect(s.isEssentiallySilent == silent, "silent fraction \(s.silentFraction)")
        }
    }

    @Test func recordingSessionWarnsWhenTheLockedMicDisappears() async throws {
        let url = tempBundleURL("mic-gone")
        defer { try? FileManager.default.removeItem(at: url) }
        var config = SyntheticFrameSource.Configuration()
        config.systemAudio = nil
        let session = RecordingSession(options: options(system: false), bundleURL: url, frameSource: SyntheticFrameSource(configuration: config))
        let start = Date()
        await session.setMicrophoneProbe(id: "usb", name: "Shure MV7+") {
            MicrophonePresence(connected: Date().timeIntervalSince(start) < 1.2, systemDefaultID: "bi", systemDefaultName: "MacBook Pro Microphone")
        }
        try await session.start()
        await sleep(3)
        let w = session.currentStatus.warnings
        #expect(w.contains { $0.kind == .microphoneDisconnected }, "warnings: \(w.map(\.kind))")
        #expect(session.currentStatus.phase == .recording, "the take keeps recording")
        _ = try await session.stop()
    }
}
