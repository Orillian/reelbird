@preconcurrency import AVFoundation
import Foundation
import Synchronization
import Testing
import ReelbirdCore
@testable import ReelbirdRender

/// Blocking AVFoundation work must never run on Swift's cooperative pool (one thread per core): AVFoundation finishes
/// part of every read there, so when every pool thread blocks in `copyNextSampleBuffer` the process deadlocks. With
/// more concurrent decodes than cores, this test hung forever before audio analysis and thumbnails moved to
/// `BlockingWork`. A deadlocked pool can't run the test's own timeout, so a watchdog thread fails it loudly instead.
@Test func moreConcurrentDecodesThanCoresFinish() async throws {
    let bundle = try await Synthetic.makeBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    let mic = bundle.resolve(try #require(manifest.track(.microphone)?.file))
    let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: try bundle.readEdit())
    let sources = try await MediaSources.load(bundle: bundle, manifest: manifest)
    let jobs = 2 * ProcessInfo.processInfo.activeProcessorCount

    // The watchdog is a plain thread: a starved pool also stalls DispatchQueue.global() at the same QoS (measured).
    let finished = Atomic(false)
    Thread.detachNewThread {
        for _ in 0..<600 where !finished.load(ordering: .relaxed) { Thread.sleep(forTimeInterval: 0.1) }
        guard !finished.load(ordering: .relaxed) else { return }
        FileHandle.standardError.write(Data("moreConcurrentDecodesThanCoresFinish: \(jobs) decodes still blocked after 60 s; the cooperative pool is starved\n".utf8))
        abort()
    }
    let measured = try await withThrowingTaskGroup(of: Int.self) { group in
        for i in 0..<jobs {
            group.addTask {
                if i.isMultiple(of: 2) {
                    let m = try await AudioAnalyzer.measure(url: mic, voiceActivity: true)
                    return m.meter.duration > 2 ? 1 : 0
                }
                let img = try await Thumbnailer.render(plan: plan, sources: sources, at: Double(i % 5) * 0.5, maxWidth: 320)
                return img.width == 320 ? 1 : 0
            }
        }
        return try await group.reduce(0, +)
    }
    finished.store(true, ordering: .relaxed)
    #expect(measured == jobs)
}

/// Cancelling the task that runs blocking work stops it and throws `CancellationError`.
@Test func blockingWorkSeesCancellation() async throws {
    let started = Atomic(false)
    let task = Task {
        try await BlockingWork.run("test.cancel") { cancel in
            started.store(true, ordering: .relaxed)
            while !cancel.isCancelled { usleep(1_000) }
            try cancel.check()
            return 1
        }
    }
    while !started.load(ordering: .relaxed) { try await Task.sleep(for: .milliseconds(2)) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}
