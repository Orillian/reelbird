import AVFoundation
import Foundation
import ReelbirdCore
import Synchronization
import Testing
@testable import ReelbirdCapture

/// Feeds 6 s of a 440 Hz tone through an `AudioTrackFeed` whose encoder refuses `refusals` appends at
/// 2 s, and returns the consolidated file plus the feed.
private func feedThroughBusyEncoder(refusals: Int, capacity: Int) async throws -> (URL, AudioTrackFeed, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rb-busy-\(UUID().uuidString)/microphone")
    let writer = try SegmentedWriter(kind: .microphone, directory: dir, video: nil, audio: EncoderSettings.microphone, realTime: false)
    try writer.start(at: 0)
    let feed = AudioTrackFeed(writer: writer, channels: 1, pendingCapacity: capacity)
    let source = PCMBufferFactory(channels: 1)
    let chunk = 960
    var samples = [Float](repeating: 0, count: chunk)
    for i in 0..<300 {
        for k in 0..<chunk { samples[k] = 0.25 * Float(sin(2 * Double.pi * 440 * Double(i * chunk + k) / 48_000)) }
        if i == 100 { writer.injectAudioRefusals(refusals) }
        let sb = try #require(samples.withUnsafeBufferPointer { source.make(frame: Int64(i * chunk), samples: $0.baseAddress, frames: chunk) })
        feed.ingest(sb, at: Double(i * chunk) / 48_000, origin: 0, muted: false)
    }
    feed.pad(to: 6)
    feed.flushPending(timeout: 1)
    try await writer.finish()
    _ = try #require(try SegmentStore.consolidate(directory: dir, kind: .microphone))
    return (dir.appendingPathComponent("microphone.mp4"), feed, dir.deletingLastPathComponent())
}

/// A busy encoder (`.notReady`) used to drop the chunk; AAC in fMP4 then closed the hole and every later
/// sample played early. Now chunks wait in a queue, and only a queue overflow loses audio, which becomes
/// silence of the same length and is reported as a correction.
@Test func busyEncoderNeverShiftsAudio() async throws {
    // A short hiccup: the queue absorbs it, nothing is lost.
    let (url, feed, root) = try await feedThroughBusyEncoder(refusals: 25, capacity: 256)
    defer { try? FileManager.default.removeItem(at: root) }
    let (duration, _) = try await loadAsset(url)
    #expect(abs(duration - 6) < 0.05, "duration \(duration)")
    #expect(feed.lostFrames == 0 && feed.correctionSeconds == 0 && feed.pendingChunks == 0)
    let windows = try await audioWindows(url)
    let quiet = windows.dropFirst().dropLast().filter { $0.rms < 0.1 }
    #expect(quiet.isEmpty, "silent windows at \(quiet.map(\.t))")

    // A long stall that overflows a small queue: the lost stretch is silence, timing after it is unchanged.
    let (url2, feed2, root2) = try await feedThroughBusyEncoder(refusals: 60, capacity: 8)
    defer { try? FileManager.default.removeItem(at: root2) }
    let (duration2, _) = try await loadAsset(url2)
    #expect(abs(duration2 - 6) < 0.05, "duration \(duration2)")
    let lost = Double(feed2.lostFrames) / 48_000
    #expect(lost > 0.2, "lost \(lost) s")
    #expect(abs(feed2.correctionSeconds - lost) < 1e-9)
    let w2 = try await audioWindows(url2)
    let silent = w2.filter { $0.rms < 0.01 }
    #expect(abs(Double(silent.count) * 0.05 - lost) < 0.15, "\(silent.count) silent windows for \(lost) s lost")
    #expect(silent.allSatisfy { $0.t > 1.9 && $0.t < 4 }, "silence at \(silent.map(\.t))")
    #expect((w2.last?.rms ?? 0) > 0.1)   // the tone runs to the very end: nothing after the gap moved
}

extension RecordingTests {
    /// A microphone stamping buffers on another clock (here zero-based) is put on arrival time like
    /// video; before, the feed re-read the raw timestamp and dropped every buffer as "before zero".
    @Test func microphoneOnAnotherClockStillRecords() async throws {
        let url = tempBundleURL("micclock")
        defer { try? FileManager.default.removeItem(at: url) }
        var config = SyntheticFrameSource.Configuration()
        config.microphoneClockOffset = -10_000_000
        let session = RecordingSession(options: options(system: false), bundleURL: url, frameSource: SyntheticFrameSource(configuration: config))
        try await session.start()
        await sleep(3)
        let metrics = try #require(await session.metrics())
        let bundle = try await session.stop()
        #expect(metrics.clockFallbacks > 50)
        let m = try bundle.readManifest()
        let mic = bundle.resolve(try #require(m.track(.microphone)?.file))
        let (d, _) = try await loadAsset(mic)
        #expect(abs(d - m.duration) < 0.15, "mic \(d) vs \(m.duration)")
        let windows = try await audioWindows(mic)
        let loud = windows.filter { $0.rms > 0.1 }.count
        #expect(Double(loud) > Double(windows.count) * 0.8, "\(loud) of \(windows.count) windows carry the tone")
    }

    /// A camera whose writer can't start used to vanish without a word (`onCameraError` wasn't wired).
    @Test func cameraThatCannotStartIsReported() async throws {
        let url = tempBundleURL("nocamera")
        defer { try? FileManager.default.removeItem(at: url) }
        // A file where the camera folder goes: the camera writer can't create its directory.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data().write(to: url.appendingPathComponent("camera"))
        var config = SyntheticFrameSource.Configuration()
        config.camera = PixelSize(width: 640, height: 360)
        let session = RecordingSession(options: options(), bundleURL: url, frameSource: SyntheticFrameSource(configuration: config))
        try await session.start()
        await sleep(1.5)
        let live = session.currentStatus.warnings.map(\.message).joined(separator: " | ")
        #expect(live.contains("camera"), "warnings while recording: \(live)")
        let bundle = try await session.stop()
        let issues = await session.trackIssues
        #expect(issues[.camera]?.contains("couldn't start") == true, "\(issues)")
        let m = try bundle.readManifest()
        #expect(m.status == .complete && m.track(.camera) == nil && m.track(.screen)?.file != nil)
        #expect(session.currentStatus.warnings.contains { $0.message.contains("camera") && $0.message.contains("saved") })
    }

    /// A track whose finished file doesn't open is left out, but reported, and its segments are kept.
    @Test func trackThatFailsVerificationIsReportedAndKept() async throws {
        let url = tempBundleURL("badmic")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = RecordingSession(options: options(), bundleURL: url, frameSource: SyntheticFrameSource())
        try await session.start()
        await sleep(2.5)
        await session.failVerification([.microphone])
        let bundle = try await session.stop()
        let m = try bundle.readManifest()
        #expect(m.status == .complete)
        #expect(m.track(.microphone) == nil && m.track(.systemAudio)?.file != nil)
        let issues = await session.trackIssues
        #expect(issues[.microphone]?.contains("segments are kept") == true, "\(issues)")
        #expect(SegmentStore.hasSegments(bundle.directory(for: .microphone)))
        #expect(!SegmentStore.hasSegments(bundle.directory(for: .systemAudio)))
        #expect(session.currentStatus.warnings.contains { $0.message.contains("microphone") })
    }
}
