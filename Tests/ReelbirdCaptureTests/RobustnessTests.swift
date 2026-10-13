import AVFoundation
import Foundation
import ReelbirdCore
import Synchronization
import Testing
@testable import ReelbirdCapture

/// Polls `session.currentStatus` until `phase` is one of `phases` (or the timeout passes).
func waitForPhase(_ session: RecordingSession, _ phases: Set<RecorderStatus.Phase>, timeout: Double = 8) async -> RecorderStatus.Phase {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let p = session.currentStatus.phase
        if phases.contains(p) { return p }
        await sleep(0.05)
    }
    return session.currentStatus.phase
}

// Failure handling end to end. Extends the serialized suite so encoder-heavy tests never overlap.
extension RecordingTests {
    /// A segment that can't be written (disk full, volume gone) must stop the recording by itself,
    /// keep every segment already on disk and leave the project recoverable.
    @Test func diskErrorStopsTheRecordingAndKeepsTheSegments() async throws {
        let url = tempBundleURL("diskerror")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.appendingPathComponent("screen").path)
            try? FileManager.default.removeItem(at: url)
        }
        let session = RecordingSession(options: options(), bundleURL: url, frameSource: SyntheticFrameSource())
        try await session.start()
        await sleep(2.6)
        let screenDir = session.bundle.directory(for: .screen)
        let before = SegmentStore.segmentFiles(in: screenDir).count
        #expect(before >= 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: screenDir.path)

        // Stops on its own within a segment or two; nobody calls stop().
        let phase = await waitForPhase(session, [.failed, .finished], timeout: 6)
        #expect(phase == .failed)
        let message = session.currentStatus.warnings.map(\.message).joined(separator: " | ")
        #expect(message.contains("screen"), "warnings: \(message)")
        // The screen folder is still read-only, so finishing can't consolidate: it says so and keeps the take.
        await #expect(throws: CaptureError.self) { _ = try await session.stop() }
        let m = try session.bundle.readManifest()
        #expect(m.status == .recording)
        #expect(SegmentStore.segmentFiles(in: screenDir).count >= before)
        // No temporary files left behind by the failed writes.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: screenDir.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty, "\(leftovers)")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: screenDir.path)
        #expect(try ProjectRecovery.recoverIfNeeded(session.bundle))
        let recovered = try session.bundle.readManifest()
        let screen = try #require(recovered.track(.screen))
        let (duration, _) = try await loadAsset(session.bundle.resolve(try #require(screen.file)))
        #expect(duration >= 1.9, "recovered \(duration) s")
        #expect(recovered.track(.microphone)?.file != nil)
    }

    /// When free space drops below the reserve, the recording finishes normally instead of
    /// running the disk full mid-segment.
    @Test func lowDiskSpaceFinishesTheRecordingGracefully() async throws {
        let url = tempBundleURL("lowdisk")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = RecordingSession(options: options(), bundleURL: url, frameSource: SyntheticFrameSource())
        let started = Date()
        await session.setFreeDiskProbe { Date().timeIntervalSince(started) > 2.5 ? 250_000_000 : 50_000_000_000 }
        try await session.start()
        let phase = await waitForPhase(session, [.failed, .finished], timeout: 8)
        #expect(phase == .failed)
        let bundle = try await session.stop()
        let m = try bundle.readManifest()
        #expect(m.status == .complete)
        #expect(m.duration > 2 && m.duration < 4.5, "duration \(m.duration)")
        #expect(session.currentStatus.warnings.contains { $0.kind == .lowDisk && $0.message.contains("disk is full") })
        let (duration, _) = try await loadAsset(bundle.resolve(try #require(m.track(.screen)?.file)))
        #expect(abs(duration - m.duration) < 0.1)
    }
}

@Test func durableWriteReplacesAtomicallyAndCleansUpOnFailure() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rb-durable-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }
    let url = dir.appendingPathComponent("seg_00001.m4s")
    try DurableFile.write(Data("one".utf8), to: url)
    try DurableFile.write(Data("two".utf8), to: url)
    #expect(try String(contentsOf: url, encoding: .utf8) == "two")
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["seg_00001.m4s"])

    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    #expect(throws: (any Error).self) { try DurableFile.write(Data("three".utf8), to: url) }
    #expect(try String(contentsOf: url, encoding: .utf8) == "two")
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["seg_00001.m4s"])

    #expect(DurableFile.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
    #expect(DurableFile.isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                             userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])))
    #expect(!DurableFile.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
}

@Test func segmentsSortNumericallyPastFiveDigits() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rb-sort-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for name in ["seg_99999.m4s", "seg_100000.m4s", "seg_00002.m4s", "init.mp4", ".seg_00003.m4s.1.tmp"] {
        FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
    }
    #expect(SegmentStore.segmentFiles(in: dir).map(\.lastPathComponent) == ["seg_00002.m4s", "seg_99999.m4s", "seg_100000.m4s"])
}

@Test func playlistTargetDurationIsStable() {
    // Keyframe jitter (2.03 s) must not bump the target mid-stream; a long segment still fits.
    #expect(SegmentedWriter.targetDuration([2.0, 2.03, 1.98], interval: 2) == 4)
    #expect(SegmentedWriter.targetDuration([], interval: 2) == 4)
    #expect(SegmentedWriter.targetDuration([2.0, 6.6], interval: 2) == 7)
}

extension RecordingTests {
    /// ScreenCaptureKit sends no system audio while nothing plays. The track must keep growing with
    /// silence in small steps (no burst when sound returns), stay aligned, and not raise a drift warning.
    @Test func quietSystemAudioStaysAlignedWithoutDriftWarnings() async throws {
        let url = tempBundleURL("quiet")
        defer { try? FileManager.default.removeItem(at: url) }
        var config = SyntheticFrameSource.Configuration()
        config.systemAudioGaps = [TimeRange(start: 1, end: 3.4)]
        let session = RecordingSession(options: options(), bundleURL: url, frameSource: SyntheticFrameSource(configuration: config))
        let drift = Mutex(false)
        let watcher = Task {
            for await s in session.status where s.warnings.contains(where: { $0.kind == .avDrift }) { drift.withLock { $0 = true } }
        }
        try await session.start()
        await sleep(3.0)
        // Inside the gap: the system track has advanced well past where its audio stopped (1 s).
        let during = try #require(await session.written(.systemAudio))
        #expect(during.end > 2.0, "system audio written up to \(during.end) s during the quiet stretch")
        await sleep(2.0)
        let after = try #require(await session.written(.systemAudio))
        #expect(after.correction < 0.05, "correction \(after.correction) s")
        let bundle = try await session.stop()
        watcher.cancel()
        #expect(!drift.withLock { $0 }, "a quiet source is not drift")

        let m = try bundle.readManifest()
        let file = bundle.resolve(try #require(m.track(.systemAudio)?.file))
        let (duration, _) = try await loadAsset(file)
        #expect(abs(duration - m.duration) < 0.15, "system \(duration) vs \(m.duration)")
        let windows = try await audioWindows(file)
        #expect(windows.filter { $0.t > 0.2 && $0.t < 0.9 }.allSatisfy { $0.rms > 0.1 }, "tone before the gap")
        #expect(windows.filter { $0.t > 1.2 && $0.t < 3.2 }.allSatisfy { $0.rms < 0.001 }, "silence in the gap")
        // Sound comes back at the right time: within one 50 ms window of 3.4 s.
        let back = try #require(windows.first { $0.t > 3.0 && $0.rms > 0.1 })
        #expect(abs(back.t - 3.4) < 0.08, "audio came back at \(back.t)")
        #expect(windows.filter { $0.t > 3.5 && $0.t < m.duration - 0.2 }.allSatisfy { $0.rms > 0.1 }, "tone after the gap")
    }
}

@Test func encoderFallsBackFromHEVCToH264ToSoftware() throws {
    let hevc = EncoderSettings.screen(size: PixelSize(width: 2560, height: 1440), frameRate: 60, quality: .high)
    #expect(hevc.codec == .hevc && hevc.requireHardware)
    // HEVC session creation fails: H.264 hardware, with more bits for the same quality.
    let h264 = EncoderSettings.resolve(hevc) { !($0.codec == .hevc && $0.requireHardware) }
    #expect(h264.codec == .h264 && h264.requireHardware)
    #expect(h264.bitrate > hevc.bitrate)
    // Nothing in hardware: software HEVC rather than no recording.
    let soft = EncoderSettings.resolve(hevc) { !$0.requireHardware }
    #expect(soft.codec == .hevc && !soft.requireHardware)
    // 5K is beyond H.264 hardware, so its chain skips straight to software HEVC.
    let fiveK = EncoderSettings.screen(size: PixelSize(width: 5120, height: 2880), frameRate: 60, quality: .max)
    #expect(EncoderSettings.candidates(for: fiveK).map(\.codec) == [.hevc, .hevc])
    #expect(EncoderSettings.candidates(for: fiveK).map(\.requireHardware) == [true, false])
    // The real probe on this Mac: hardware HEVC at 1080p exists; a 16K frame does not.
    #expect(EncoderSettings.canEncode(VideoSpec(codec: .hevc, size: PixelSize(width: 1920, height: 1080), frameRate: 60, bitrate: 8_000_000)))
    #expect(!EncoderSettings.canEncode(VideoSpec(codec: .h264, size: PixelSize(width: 16_384, height: 16_384), frameRate: 30, bitrate: 8_000_000)))
}

@Test func writerFallsThroughWhenTheFirstEncoderFailsToStart() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rb-fallback-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let spec = EncoderSettings.screen(size: PixelSize(width: 1280, height: 720), frameRate: 30, quality: .high)
    var tried: [VideoSpec.Codec] = []
    let (writer, chosen) = try EncoderSettings.makeWriter(spec, probe: { _ in true }) { candidate in
        tried.append(candidate.codec)
        if candidate.codec == .hevc && candidate.requireHardware { throw CaptureError.encoderUnavailable("simulated") }
        let w = try SegmentedWriter(kind: .screen, directory: dir, video: candidate, audio: nil, realTime: false)
        try w.start(at: 0)
        return w
    }
    #expect(tried == [.hevc, .h264])
    #expect(chosen.codec == .h264)
    writer.abandon()
}

// Control races: stop/discard while starting or finishing, stop twice, pause while stopping.
extension RecordingTests {
    func slowStartSession(_ name: String, delay: Double = 1) -> (RecordingSession, URL) {
        let url = tempBundleURL(name)
        var config = SyntheticFrameSource.Configuration()
        config.startDelay = delay
        return (RecordingSession(options: options(), bundleURL: url, frameSource: SyntheticFrameSource(configuration: config)), url)
    }

    @Test func stopWhileStartingFinishesTheTake() async throws {
        let (session, url) = slowStartSession("stopstarting")
        defer { try? FileManager.default.removeItem(at: url) }
        let starter = Task { try await session.start() }
        await sleep(0.2)   // still inside the 1 s start delay
        let bundle = try await session.stop()   // used to throw "Nothing is being recorded" and leave capture running
        try await starter.value
        #expect(try bundle.readManifest().status == .complete)
        #expect(session.currentStatus.phase == .finished)
        // Concurrent and repeated stops return the same bundle.
        async let a = session.stop()
        async let b = session.stop()
        let (ra, rb) = try await (a, b)
        #expect(ra == bundle && rb == bundle)
    }

    @Test func discardWhileStartingCancelsAndLeavesNothing() async throws {
        let (session, url) = slowStartSession("discardstarting")
        defer { try? FileManager.default.removeItem(at: url) }
        let starter = Task { try await session.start() }
        await sleep(0.2)
        await session.discard()
        await #expect(throws: (any Error).self) { try await starter.value }
        await sleep(1.2)
        #expect(!FileManager.default.fileExists(atPath: url.path), "nothing may be written after discard")
        await #expect(throws: CaptureError.self) { try await session.start() }
    }

    @Test func discardWhileStoppingDeletesAfterFinishing() async throws {
        let url = tempBundleURL("discardstopping")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = RecordingSession(options: options(), bundleURL: url, frameSource: SyntheticFrameSource())
        try await session.start()
        await sleep(2)
        let stopper = Task { try await session.stop() }
        await sleep(0.01)
        await session.pause()            // ignored while finishing
        await session.discard()
        _ = try? await stopper.value
        await sleep(0.5)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

@Test func shareTimeMapLeavesPausesOut() {
    let map = ShareTimeMap()
    #expect(map.time(1) == 1)
    map.pause(at: 2)
    #expect(map.time(2.5) == nil)
    map.resume(TimeRange(start: 2, end: 5))
    #expect(map.time(2.5) == nil)
    #expect(map.time(5) == 2)
    #expect(map.time(6) == 3)

    // Audio: a chunk spanning the pause keeps [1.9, 2) and [5, 5.1), placed back to back.
    var pieces: [(Int64, Int, Int)] = []
    map.mapAudio(frame: 91_200, frames: 153_600, rate: 48_000) { pieces.append(($0, $1, $2)) }
    #expect(pieces.count == 2)
    #expect(pieces[0] == (91_200, 0, 4_800))
    #expect(pieces[1] == (96_000, 148_800, 4_800))
    // After the pause everything shifts by 3 s; inside an open pause nothing is emitted.
    pieces = []
    map.mapAudio(frame: 288_000, frames: 960, rate: 48_000) { pieces.append(($0, $1, $2)) }
    #expect(pieces.count == 1 && pieces[0] == (144_000, 0, 960))
    map.pause(at: 7)
    pieces = []
    map.mapAudio(frame: 336_000 - 480, frames: 960, rate: 48_000) { pieces.append(($0, $1, $2)) }
    #expect(pieces.count == 1 && pieces[0] == (192_000 - 480, 0, 480))
}

extension RecordingTests {
    /// The live link plays straight through a pause: share media is the recording minus the pause,
    /// segments stay ~2 s (no giant segment), and audio and video have no gap at the cut.
    @Test func shareStreamPlaysStraightThroughPauses() async throws {
        let url = tempBundleURL("sharepause")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = MockShareSink()
        let session = RecordingSession(options: options(), bundleURL: url, shareSink: sink, frameSource: SyntheticFrameSource())
        try await session.start()
        await sleep(2.5)
        await session.pause()
        await sleep(3)
        await session.resume()
        await sleep(2.5)
        let bundle = try await session.stop()
        let m = try bundle.readManifest()
        let pause = try #require(m.pauses.first)
        let expected = m.duration - pause.duration

        let calls = sink.calls.withLock { $0 }
        let media = calls.compactMap { c -> Double? in if case .media(_, let d) = c { return d } else { return nil } }
        #expect(media.allSatisfy { $0 < 2.3 }, "segment durations \(media)")
        if case .finish(let total) = calls.last { #expect(abs(total - expected) < 0.15, "finish \(total) vs \(expected)") }

        let file = bundle.resolve(try #require(m.track(.share)?.file))
        let (duration, _) = try await loadAsset(file)
        #expect(abs(duration - expected) < 0.2, "share \(duration) s, recording \(m.duration) s minus pause \(pause.duration) s")
        let pts = try await samplePTS(file, type: .video).sorted()
        let maxGap = zip(pts, pts.dropFirst()).map { $1 - $0 }.max() ?? 0
        #expect(maxGap < 0.15, "largest video gap \(maxGap) s")
        let windows = try await audioWindows(file)
        #expect(windows.filter { $0.t > 0.3 && $0.t < expected - 0.3 }.allSatisfy { $0.rms > 0.15 }, "share audio has no silent pause")
        // The full-quality tracks still keep the pause on the recording timeline.
        let (screenDuration, _) = try await loadAsset(bundle.resolve(try #require(m.track(.screen)?.file)))
        #expect(abs(screenDuration - m.duration) < 0.1)
    }
}

@Test func timestampsOffTheHostClockFallBackToArrivalTime() {
    #expect(CapturePipeline.sanitizedHostTime(1000.01, now: 1000.05) == nil)
    #expect(CapturePipeline.sanitizedHostTime(0.02, now: 1000.05) == 1000.05)        // zero-based device clock
    #expect(CapturePipeline.sanitizedHostTime(98_000, now: 1000.05) == 1000.05)      // another clock domain
}
