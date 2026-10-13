import Foundation
import ReelbirdCore
import Testing
@testable import ReelbirdAI

// Find Sensitive Info end to end on a synthetic 60 s recording (SecretFixture): recognition, matching, linking
// across frames (including text that scrolls), timing, and speed.

@Suite(.serialized) struct SensitiveScanTests {

@Test func findsFakeSecretsInASixtySecondRecording() async throws {
    let fx = try await SecretFixture.shared()
    var o = SensitiveInfoScanner.Options()
    o.customWords = ["Project Bluebird"]
    let r = try await SensitiveInfoScanner.scan(video: fx.url, duration: fx.seconds, options: o)
    print("Find Sensitive Info: \(String(format: "%.2f", r.seconds)) s for \(Int(fx.seconds)) s of 1920×1200 video; "
          + "\(r.samples) samples, \(r.recognized) recognised, \(r.detections.count) detections")
    if let dir = ProcessInfo.processInfo.environment["RB_DUMP_DIR"] {
        let data = try JSONCoding.encoder.encode(r.detections)
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("detections.json"))
    }

    for truth in fx.truth {
        let candidates = r.detections.filter { $0.kind == truth.kind }
        // The detection that covers it at the middle of its visible time.
        let mid = (truth.visible.start + truth.visible.end) / 2
        let d = candidates.first { $0.range.contains(mid) && $0.annotation().rect(at: mid).intersection(truth.rect(mid)) != nil }
        #expect(d != nil, "\(truth.kind.rawValue) \(truth.text) not found")
        guard let d else { continue }
        // Hidden for the whole time it is on screen (to within one sample at each end).
        #expect(d.range.start <= truth.visible.start + 0.01, "\(truth.text) starts at \(d.range.start), visible from \(truth.visible.start)")
        #expect(d.range.end >= truth.visible.end - 0.55, "\(truth.text) ends at \(d.range.end), visible to \(truth.visible.end)")
        // And the blur covers it wherever it is, frame by frame.
        let a = d.annotation()
        var t = truth.visible.start
        var misses: [String] = []
        while t < min(truth.visible.end - 0.55, d.range.end) {
            let want = truth.rect(t), have = a.rect(at: t)
            let slack = 0.002
            if !(have.x <= want.x + slack && have.y <= want.y + slack && have.x + have.width >= want.x + want.width - slack
                 && have.y + have.height >= want.y + want.height - slack) {
                misses.append(String(format: "%.2f", t))
            }
            t += 1.0 / 30
        }
        #expect(misses.isEmpty, "\(truth.text) uncovered at \(misses.prefix(8))")
        #expect(r.thumbnails[d.id] != nil, "thumbnail for \(truth.text)")
        // The preview never shows the whole value.
        #expect(!d.preview.contains(truth.text) && d.preview.count < truth.text.count)
    }
    // Nothing else: no date, version or order number, and each secret once (allowing a stray second sighting).
    #expect(r.detections.count <= fx.truth.count + 2, "\(r.detections.map { "\($0.kind.rawValue) \($0.preview) \($0.range)" })")
    #expect(!r.detections.contains { $0.kind == .phone && $0.rect.y > 0.5 && $0.range.start < 20 })
    // Fast: a still screen is recognised once, not twice a second.
    #expect(r.recognized < r.samples)
    #expect(r.seconds < 45, "scan took \(r.seconds) s")
}

@Test func scanningOnlyTheKindsAskedFor() async throws {
    let fx = try await SecretFixture.shared(seconds: 20)
    var o = SensitiveInfoScanner.Options()
    o.kinds = [.card]
    let r = try await SensitiveInfoScanner.scan(video: fx.url, duration: fx.seconds, options: o)
    #expect(r.detections.count == 1 && r.detections.first?.kind == .card)
    #expect(r.detections.first?.preview == "•••• 4242")
}
}
