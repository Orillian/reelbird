import Foundation
import ReelbirdCore
import Testing
@testable import ReelbirdCapture

/// Opt-in timing check: `RB_PERF=1 scripts/test.sh --filter perfSyntheticMinute`. Records 60 s of 1080p60
/// with microphone and system audio in real time and prints CPU use, dropped frames, how long stop
/// takes (consolidate + verify + cleanup) and the project's size on disk. Compare against an older
/// build to catch regressions in the capture path.
extension RecordingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RB_PERF"] == "1"), .timeLimit(.minutes(5)))
    func perfSyntheticMinute() async throws {
        let seconds = Double(ProcessInfo.processInfo.environment["RB_PERF_SECONDS"] ?? "") ?? 60
        let url = tempBundleURL("perf")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = RecordingSession(options: options(), bundleURL: url, frameSource: SyntheticFrameSource())
        try await session.start()
        let cpu0 = cpuSeconds(), wall0 = Date()
        await sleep(seconds)
        let metrics = try #require(await session.metrics())
        let cpu = cpuSeconds() - cpu0, wall = Date().timeIntervalSince(wall0)
        let stop0 = Date()
        let bundle = try await session.stop()
        let stopTime = Date().timeIntervalSince(stop0)
        let bytes = Self.diskSize(bundle.url)
        print(String(format: "PERF %.0f s 1080p60+mic+system: CPU %.2f s (%.1f%% of one core), frames %d, dropped %d, stop %.2f s, bundle %.1f MB",
                     wall, cpu, cpu / wall * 100, metrics.framesWritten, metrics.droppedFrames, stopTime, Double(bytes) / 1e6))
        #expect(metrics.droppedFrames < metrics.framesWritten / 100)
    }

    static func diskSize(_ url: URL) -> Int64 {
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
