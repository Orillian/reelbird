import Foundation
import Testing
@testable import ReelbirdCore

private func tempBundle() throws -> ProjectBundle {
    try ProjectBundle.create(at: FileManager.default.temporaryDirectory.appendingPathComponent("rb-\(UUID().uuidString).reelbird"))
}

@Test func bundleLockIsExclusiveAcrossHoldersAndSaysWhy() throws {
    let b = try tempBundle()
    defer { try? FileManager.default.removeItem(at: b.url) }
    #expect(!BundleLock.isHeld(b) && BundleLock.holder(b) == nil)
    let first = try #require(try BundleLock.acquire(b, purpose: .recovering, wait: false))
    #expect(BundleLock.isHeld(b))
    #expect(BundleLock.holder(b) == .recovering)
    #expect(try BundleLock.acquire(b, purpose: .recording, wait: false) == nil)   // separate descriptor, same process

    // A waiter gets it as soon as the holder lets go.
    let got = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        if let l = try? BundleLock.acquire(b, purpose: .recording, wait: true) { got.signal(); l.release() }
    }
    #expect(got.wait(timeout: .now() + 0.2) == .timedOut)
    first.release()
    #expect(got.wait(timeout: .now() + 5) == .success)
    #expect(!BundleLock.isHeld(b))

    // A recorder's lock marks the take live even when project.json looks old.
    var m = ProjectManifest(title: "Live", appVersion: "test",
                            capture: CaptureInfo(source: .synthetic(name: "t"), pixelSize: PixelSize(width: 640, height: 360), scale: 1, frameRate: 30),
                            clock: ClockInfo(originHostTime: 0))
    m.status = .recording
    try b.writeManifest(m)
    let later = Date().addingTimeInterval(600)
    #expect(!b.isBeingRecorded(m, now: later))
    let rec = try #require(try BundleLock.acquire(b, purpose: .recording, wait: false))
    #expect(b.isBeingRecorded(m, now: later))
    rec.release()
    let recovery = try #require(try BundleLock.acquire(b, purpose: .recovering, wait: false))
    #expect(!b.isBeingRecorded(m, now: later))   // a recovery isn't a recorder
    recovery.release()
}

@Test func durableWritesLeaveOnlyTheFinalFile() throws {
    let b = try tempBundle()
    defer { try? FileManager.default.removeItem(at: b.url) }
    var m = ProjectManifest(title: "D", appVersion: "test",
                            capture: CaptureInfo(source: .synthetic(name: "t"), pixelSize: PixelSize(width: 640, height: 360), scale: 1, frameRate: 30),
                            clock: ClockInfo(originHostTime: 0))
    m.status = .recording
    try b.writeManifest(m)          // barrier while recording
    m.status = .complete
    try b.writeManifest(m)          // full flush when finished
    try b.writeEdit(EditDocument())
    #expect(try b.readManifest().status == .complete)
    let names = try FileManager.default.contentsOfDirectory(atPath: b.url.path).filter { $0.hasSuffix(".tmp") }
    #expect(names.isEmpty, "\(names)")
    try DurableFile.write(Data("x".utf8), to: b.url.appendingPathComponent("f"), sync: .full)
    #expect(try String(contentsOf: b.url.appendingPathComponent("f"), encoding: .utf8) == "x")
}

@Test func segmentsAreRemovedOnlyNextToAConsolidatedFile() throws {
    let b = try tempBundle()
    defer { try? FileManager.default.removeItem(at: b.url) }
    let dir = b.directory(for: .microphone)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for name in ["init.mp4", "seg_00001.m4s", "seg_00002.m4s", "index.m3u8", ".seg_00003.m4s.7.tmp", ".microphone.mp4.9.partial", "notes.txt"] {
        try Data(repeating: 1, count: 10).write(to: dir.appendingPathComponent(name))
    }
    #expect(b.removeSegments(of: .microphone) == 0)   // no microphone.mp4 yet: nothing is touched
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 7)
    try Data(repeating: 2, count: 10).write(to: dir.appendingPathComponent("microphone.mp4"))
    #expect(b.removeSegments(of: .microphone) == 60)
    #expect(try Set(FileManager.default.contentsOfDirectory(atPath: dir.path)) == ["microphone.mp4", "notes.txt"])
}
