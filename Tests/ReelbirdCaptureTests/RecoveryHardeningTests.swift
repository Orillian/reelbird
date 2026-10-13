import AVFoundation
import Foundation
import ReelbirdCore
import Synchronization
import Testing
@testable import ReelbirdCapture

/// A crashed synthetic take (status `.recording`, segments on disk, lock released) of about `seconds`.
func crashedTake(_ name: String, seconds: Double = 4, pause: Bool = false) async throws -> ProjectBundle {
    let url = tempBundleURL(name)
    let session = RecordingSession(options: options(), bundleURL: url, frameSource: SyntheticFrameSource())
    try await session.start()
    if pause {
        await sleep(1.2)
        await session.pause()
        await sleep(0.8)
        await session.resume()
        await sleep(max(0.5, seconds - 2))
    } else {
        await sleep(seconds)
    }
    await session.simulateCrash()
    return ProjectBundle(url: url)
}

extension RecordingTests {
    /// The share stream's segments stay until its upload is confirmed done, then go.
    @Test func shareSegmentsGoOnceTheUploadIsDone() async throws {
        let url = tempBundleURL("share-done")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = MockShareSink()
        sink.uploadCompletes.withLock { $0 = true }
        let session = RecordingSession(options: options(), bundleURL: url, shareSink: sink, frameSource: SyntheticFrameSource())
        try await session.start()
        await sleep(3)
        let bundle = try await session.stop()
        let shareDir = bundle.directory(for: .share)
        for _ in 0..<40 where SegmentStore.hasSegments(shareDir) { await sleep(0.1) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: shareDir.path) == ["share.mp4"])
        let m = try bundle.readManifest()
        let (d, _) = try await loadAsset(bundle.resolve(try #require(m.track(.share)?.file)))
        #expect(d > 2)
    }

    /// A take's lock shows it is live even when project.json looks stale, and recovery leaves it alone.
    @Test func liveTakeHoldsTheBundleLock() async throws {
        let url = tempBundleURL("locked")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = RecordingSession(options: options(), bundleURL: url, frameSource: SyntheticFrameSource())
        try await session.start()
        await sleep(1)
        let bundle = session.bundle
        let live = try bundle.readManifest()
        #expect(BundleLock.isHeld(bundle))
        #expect(bundle.isBeingRecorded(live, now: Date().addingTimeInterval(120)))
        #expect(try ProjectRecovery.recoverIfNeeded(bundle, waitForLock: false) == false)
        #expect(throws: ProjectRecovery.Failure.stillRecording) { try ProjectRecovery.recoverIfNeeded(bundle) }
        _ = try await session.stop()
        #expect(!BundleLock.isHeld(bundle))
        #expect(try bundle.readManifest().status == .complete)
        #expect(try ProjectRecovery.recoverIfNeeded(bundle) == false)
    }

    /// Two recoveries at once (app launch scan + editor, or app + CLI): exactly one does the work, the
    /// other waits and finds it done, and the result plays.
    @Test func concurrentRecoveriesDoTheWorkOnce() async throws {
        let bundle = try await crashedTake("concurrent")
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<3 {
                group.addTask { await Task.detached { (try? ProjectRecovery.recoverIfNeeded(bundle)) ?? false }.value }
            }
            var out: [Bool] = []
            for await r in group { out.append(r) }
            return out
        }
        #expect(results.filter { $0 }.count == 1, "\(results)")
        let m = try bundle.readManifest()
        #expect(m.status == .recovered)
        let (d, tracks) = try await loadAsset(bundle.resolve(try #require(m.track(.screen)?.file)))
        #expect(d >= 1.5 && tracks.contains { $0.mediaType == .video }, "\(d)")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: bundle.directory(for: .screen).path).filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty, "\(leftovers)")
    }

    /// A project.json torn by a power cut is rebuilt from the track folders and events.jsonl.
    @Test func recoveryRebuildsADamagedProjectFile() async throws {
        let bundle = try await crashedTake("torn", seconds: 4.5, pause: true)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let good = try bundle.readManifest()
        #expect(good.pauses.count == 1)
        let bytes = try Data(contentsOf: bundle.manifestURL)
        try bytes.prefix(bytes.count / 3).write(to: bundle.manifestURL)
        #expect(throws: (any Error).self) { try bundle.readManifest() }
        #expect(ProjectRecovery.needsRecovery(bundle))

        #expect(try ProjectRecovery.recoverIfNeeded(bundle))
        let m = try bundle.readManifest()
        #expect(m.status == .recovered)
        #expect(m.track(.screen)?.pixelSize == good.track(.screen)?.pixelSize)
        for kind in [TrackKind.screen, .microphone, .systemAudio] {
            let t = try #require(m.track(kind), "\(kind)")
            let (d, _) = try await loadAsset(bundle.resolve(try #require(t.file)))
            #expect(d > 2.5, "\(kind) \(d)")
        }
        #expect(m.pauses.count == 1)
        if let p = m.pauses.first, let g = good.pauses.first { #expect(abs(p.start - g.start) < 0.05 && abs(p.end - g.end) < 0.05) }
        #expect(m.duration > 3)
    }

    /// A finished take (segments already deleted) whose project.json is damaged is rebuilt from its
    /// consolidated files.
    @Test func damagedProjectFileOfAFinishedTakeIsRebuiltFromItsFiles() async throws {
        let url = tempBundleURL("torn-done")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = RecordingSession(options: options(), bundleURL: url, frameSource: SyntheticFrameSource())
        try await session.start()
        await sleep(3)
        let bundle = try await session.stop()
        let good = try bundle.readManifest()
        try Data("{\"formatVersion\":1,\"id\":".utf8).write(to: bundle.manifestURL)
        #expect(try ProjectRecovery.recoverIfNeeded(bundle))
        let m = try bundle.readManifest()
        #expect(m.status == .recovered)
        #expect(Set(m.tracks.map(\.kind)) == Set(good.tracks.map(\.kind)))
        #expect(abs(m.duration - good.duration) < 0.1, "\(m.duration) vs \(good.duration)")
        #expect(m.tracks.allSatisfy { $0.file != nil })
    }
}

@Test func consolidationVerifiesWhatItWroteAndUsesAUniqueTemporaryName() throws {
    let dir = testTemporaryDirectory.appendingPathComponent("rb-verify-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // An old-style leftover partial from an interrupted run must not be clobbered or confused for output.
    let stale = dir.appendingPathComponent(".screen.mp4.partial")
    try Data("stale".utf8).write(to: stale)
    #expect(SegmentStore.verify(stale, expectedBytes: 5) == false)   // not an MP4
    #expect(SegmentStore.verify(stale, expectedBytes: 4) == false)   // wrong size
    #expect(try SegmentStore.consolidate(directory: dir, kind: .screen) == nil)   // no init segment
    #expect(FileManager.default.fileExists(atPath: stale.path))
}
