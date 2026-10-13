import AVFoundation
import Darwin
import Foundation
import ReelbirdCore
import Synchronization
import Testing
@testable import ReelbirdCapture

/// Physical memory footprint of this process (what Activity Monitor shows as Memory).
func memoryFootprint() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
}

/// Opt-in soak: `RB_SOAK=1 scripts/test.sh --filter soak` (run it through research/heavy.sh).
/// Records `RB_SOAK_MINUTES` (default 60) of 1080p30 media with microphone, system audio and the
/// share stream as fast as the encoders allow, sampling memory throughout, then checks that memory
/// stayed flat and that consolidation produced full-length, playable files.
extension RecordingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RB_SOAK"] == "1"), .timeLimit(.minutes(90)))
    func soakLongRecordingStaysFlatAndConsolidates() async throws {
        let minutes = Double(ProcessInfo.processInfo.environment["RB_SOAK_MINUTES"] ?? "") ?? 60
        let seconds = minutes * 60
        let url = tempBundleURL("soak")
        defer { if ProcessInfo.processInfo.environment["RB_SOAK_KEEP"] == nil { try? FileManager.default.removeItem(at: url) } }
        var config = SyntheticFrameSource.Configuration()
        config.pixelSize = PixelSize(width: 1920, height: 1080)
        config.frameRate = 30
        config.mode = .asFastAsPossible(duration: seconds)
        var opts = options()
        opts.frameRate = 30
        let source = SyntheticFrameSource(configuration: config)
        let sink = MockShareSink()
        let session = RecordingSession(options: opts, bundleURL: url, shareSink: sink, frameSource: source)

        let samples = Mutex<[(media: Double, bytes: Int64)]>([])
        let wall0 = Date()
        try await session.start()
        let sampler = Task {
            while !Task.isCancelled {
                let media = await session.written(.screen)?.end ?? 0
                samples.withLock { $0.append((media, memoryFootprint())) }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        await source.waitUntilFinished()
        let recordWall = Date().timeIntervalSince(wall0)
        let stop0 = Date()
        let bundle = try await session.stop()
        let stopWall = Date().timeIntervalSince(stop0)
        sampler.cancel()
        let metrics = await session.metrics()

        // Memory: compare the 10%–20% window (after warm-up) with the last 10% of the recording.
        let s = samples.withLock { $0 }.filter { $0.media > 0 }
        try #require(s.count >= 10, "too few samples: \(s.count)")
        func median(_ xs: [Int64]) -> Int64 { let v = xs.sorted(); return v[v.count / 2] }
        let early = median(s.filter { $0.media > seconds * 0.1 && $0.media < seconds * 0.2 }.map(\.bytes))
        let late = median(s.filter { $0.media > seconds * 0.9 }.map(\.bytes))
        let peak = s.map(\.bytes).max() ?? 0
        let growthMB = Double(late - early) / 1_048_576

        let m = try bundle.readManifest()
        #expect(m.status == .complete)
        var report = String(format: "soak: %.0f min of 1080p30 recorded in %.0f s (%.1fx real time), stop+consolidate %.1f s; memory early %.0f MB, late %.0f MB, growth %.1f MB, peak %.0f MB; frames %d dropped %d",
                            minutes, recordWall, seconds / recordWall, stopWall,
                            Double(early) / 1_048_576, Double(late) / 1_048_576, growthMB, Double(peak) / 1_048_576,
                            metrics?.framesWritten ?? 0, metrics?.droppedFrames ?? -1)
        for kind in [TrackKind.screen, .microphone, .systemAudio, .share] {
            let t = try #require(m.track(kind), "missing \(kind)")
            let file = bundle.resolve(try #require(t.file))
            let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            let (duration, tracks) = try await loadAsset(file)
            #expect(abs(duration - seconds) < 0.5, "\(kind) duration \(duration)")
            #expect(!tracks.isEmpty)
            #expect(t.segmentCount >= Int(seconds / 2) - 1, "\(kind) segments \(t.segmentCount)")
            report += String(format: "\n  %@: %.2f s, %d segments, %.0f MB", kind.rawValue, duration, t.segmentCount, Double(size) / 1_048_576)
        }
        // The consolidated screen file reads back at the very end (fragments stitched in order).
        let screenFile = bundle.resolve(try #require(m.track(.screen)?.file))
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: screenFile))
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        _ = try await gen.image(at: CMTime(seconds: seconds - 1, preferredTimescale: 600))
        let media = sink.calls.withLock { $0 }.filter { if case .media = $0 { true } else { false } }.count
        report += "\n  share sink segments: \(media)"
        print(report)
        #expect(metrics?.droppedFrames == 0)
        #expect(growthMB < 64, "memory grew \(growthMB) MB over the recording")
    }
}
