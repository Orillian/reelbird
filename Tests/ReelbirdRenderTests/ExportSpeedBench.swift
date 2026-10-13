@preconcurrency import AVFoundation
import Foundation
import Testing
import ReelbirdCore
@testable import ReelbirdRender

/// Export speed on a 1080p60 synthetic take with microphone and camera, end to end through `Exporter.export`:
/// the first export also renders the voice stem and measures loudness; the rest are warm. Compare before/after
/// threading changes on an otherwise idle machine: `RB_BENCH=1 scripts/test.sh --filter exportSpeedBench`.
@Test func exportSpeedBench() async throws {
    guard ProcessInfo.processInfo.environment["RB_BENCH"] != nil else { return }
    var o = Synthetic.Options()
    o.width = 1920; o.height = 1080; o.fps = 60; o.seconds = 10; o.codec = .hevc; o.camera = true
    let bundle = try await Synthetic.makeBundle(o)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let edit = try bundle.readEdit()
    let frames = 600.0
    let clock = ContinuousClock()
    let cold = try await clock.measure {
        _ = try await Exporter.export(bundle: bundle, edit: edit, options: ExportOptions(format: .mp4H264)) { _ in }
    }
    print(String(format: "BENCH export 1080p60 10 s cold (stem + analysis + H.264): %.2f s", cold.secs))
    for format in [ExportOptions.Format.mp4H264, .mp4HEVC] {
        var runs: [Double] = []
        for _ in 0..<3 {
            let t = try await clock.measure {
                _ = try await Exporter.export(bundle: bundle, edit: edit, options: ExportOptions(format: format)) { _ in }
            }
            runs.append(t.secs)
        }
        let median = runs.sorted()[1]
        print(String(format: "BENCH export 1080p60 10 s warm %@: median %.2f s, %.0f fps (runs %@)", format.rawValue, median,
                     frames / median, runs.map { String(format: "%.2f", $0) }.joined(separator: " ")))
    }
}
