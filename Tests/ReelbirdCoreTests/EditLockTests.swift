import Foundation
import Testing
@testable import ReelbirdCore

// Concurrent writers of edit.json: every check-and-write runs under `EditLock`, so of the writers starting
// from one revision exactly one wins, and read-modify-write (`updateEdit`) never loses a change.

private func editBundle() throws -> ProjectBundle {
    let b = try ProjectBundle.create(at: testTemporaryDirectory.appendingPathComponent("rb-lock-\(UUID().uuidString).reelbird"))
    try b.writeManifest(ProjectManifest(title: "L", appVersion: "test",
                                        capture: CaptureInfo(source: .synthetic(name: "t"), pixelSize: PixelSize(width: 640, height: 360),
                                                             scale: 1, frameRate: 30),
                                        clock: ClockInfo(originHostTime: 0)))
    return b
}

private final class Wins: @unchecked Sendable {
    private let lock = NSLock()
    private var titles: [String] = []
    private var conflicts = 0
    private var failures: [String] = []
    func won(_ t: String) { lock.withLock { titles.append(t) } }
    func lost() { lock.withLock { conflicts += 1 } }
    func failed(_ s: String) { lock.withLock { failures.append(s) } }
    var result: (titles: [String], conflicts: Int, failures: [String]) { lock.withLock { (titles, conflicts, failures) } }
}

@Test func concurrentWritersFromOneRevisionHaveExactlyOneWinner() throws {
    let b = try editBundle()
    defer { try? FileManager.default.removeItem(at: b.url) }
    let writers = 8, rounds = 30
    for round in 0..<rounds {
        let revision = b.readEditRevision()
        #expect(revision == round)
        let wins = Wins()
        DispatchQueue.concurrentPerform(iterations: writers) { i in
            var e = EditDocument()
            e.title = "writer \(i) round \(round)"
            do {
                let written = try b.writeEdit(e, ifRevision: revision)
                if written != revision + 1 { wins.failed("wrote revision \(written)") }
                wins.won(e.title ?? "")
            } catch is EditConflict { wins.lost() } catch { wins.failed("\(error)") }
        }
        let (titles, conflicts, failures) = wins.result
        #expect(failures.isEmpty, "\(failures)")
        #expect(titles.count == 1 && conflicts == writers - 1, "round \(round): \(titles.count) winners")
        let (saved, savedRevision) = try b.readEditStamped()
        #expect(savedRevision == revision + 1 && saved.title == titles.first)
    }
}

@Test func concurrentUpdatesKeepEveryChange() throws {
    let b = try editBundle()
    defer { try? FileManager.default.removeItem(at: b.url) }
    let writers = 8, each = 20
    let log = Wins()
    DispatchQueue.concurrentPerform(iterations: writers) { i in
        for n in 0..<each {
            do { try b.updateEdit { $0.chapters.append(Chapter(time: Double(i * each + n), title: "w\(i)-\(n)")) } } catch {
                log.failed("\(error)")
            }
        }
    }
    #expect(log.result.failures.isEmpty, "\(log.result.failures)")
    let (edit, revision) = try b.readEditStamped()
    #expect(revision == writers * each)
    #expect(Set(edit.chapters.map(\.title)).count == writers * each)
}

@Test func editLockWaitsAtMostItsTimeout() throws {
    let b = try editBundle()
    defer { try? FileManager.default.removeItem(at: b.url) }
    // Another process holding the lock looks the same: a separate open file description.
    let fd = open(EditLock.url(for: b).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
    #expect(fd >= 0 && flock(fd, LOCK_EX) == 0)
    let start = Date()
    #expect(throws: (any Error).self) { try EditLock.withLock(b, timeout: 0.3) {} }
    #expect(Date().timeIntervalSince(start) < 2)
    #expect(b.readEditRevision() == 0)
    flock(fd, LOCK_UN)
    close(fd)
    #expect(try b.writeEdit(EditDocument(), ifRevision: 0) == 1)
}
