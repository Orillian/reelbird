import Foundation
import ReelbirdCore
import Testing
@testable import ReelbirdShare

/// Opt-in tests against real infrastructure.
///
/// - `REELBIRD_DOGFOOD=1`: live upload + publish against the dogfood bucket. The destination
///   comes from `REELBIRD_S3_*` variables, or from `dogfood.json` + `dogfood.secret` in
///   `REELBIRD_DOGFOOD_DIR` (default: the package's `notes/` folder). Leaves the demo share in
///   place and prints its link, unless `REELBIRD_DOGFOOD_CLEANUP=1`.
/// - `REELBIRD_DEMO_SERVE=<seconds>`: serves demo shares from the local mock on
///   `REELBIRD_DEMO_PORT` (default 8765) for browser checks: a polished share, an HLS-only
///   share and one that is "recording" in real time.
enum Integration {
    static let env = ProcessInfo.processInfo.environment

    static func dogfood() -> (ShareDestination, String)? {
        if let d = ShareSettings.fromEnvironment(), let s = env["REELBIRD_S3_SECRET_ACCESS_KEY"] { return (d, s) }
        let dir = env["REELBIRD_DOGFOOD_DIR"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("notes")
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("dogfood.json")),
              let d = try? JSONDecoder().decode(ShareDestination.self, from: data),
              let secret = try? String(contentsOf: dir.appendingPathComponent("dogfood.secret"), encoding: .utf8)
        else { return nil }
        return (d, secret.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static let captions = """
    WEBVTT

    00:00.500 --> 00:03.500
    This is the onboarding flow as it ships today.

    00:04.000 --> 00:07.500
    First, the empty state asks for a project name.

    00:08.000 --> 00:12.000
    Then we jump straight to the editor, no extra steps.

    00:12.500 --> 00:16.000
    The fix is in the second step, where the button moved.
    """

    static func edit(chapters: Bool) -> EditDocument {
        var e = EditDocument()
        if chapters {
            e.chapters = [Chapter(time: 0, title: "Where we start"), Chapter(time: 6, title: "The editor"),
                          Chapter(time: 12, title: "What changed in step two")]
        }
        return e
    }

    /// Live-uploads `stream` (optionally in real time) and finishes.
    static func live(_ up: LiveShareUploader, title: String, stream: Synthetic.Stream, realTime: Bool) async throws -> ShareInfo {
        let info = try await up.begin(recordingID: ShortID.make(), title: title)
        await up.initSegment(stream.initSegment)
        for (i, s) in stream.segments.enumerated() {
            if realTime { try await Task.sleep(nanoseconds: UInt64(s.duration * 1e9)) }
            await up.mediaSegment(index: i + 1, data: s.data, duration: s.duration)
        }
        await up.finish(totalDuration: stream.totalDuration, timeout: 60)
        return info
    }
}

@Suite(.serialized) struct IntegrationTests {
    @Test(.enabled(if: Integration.env["REELBIRD_DOGFOOD"] == "1"), .timeLimit(.minutes(5)))
    func dogfoodBucketEndToEnd() async throws {
        let (dest, secret) = try #require(Integration.dogfood(), "no dogfood destination configured")
        try await ShareService.testConnection(dest, secret: secret)

        let dir = try TestSupport.tempDir("dogfood")
        let opts = Synthetic.Options(width: 1280, height: 720, fps: 30, seconds: 16, title: "Reelbird dogfood", bitrate: 2_500_000)
        let stream = try await Synthetic.cmaf(opts)
        let up = LiveShareUploader(destination: dest, secret: secret, journalDirectory: dir.appendingPathComponent("journal"))
        let info = try await Integration.live(up, title: "Reelbird dogfood check", stream: stream, realTime: false)
        #expect(await up.backlog == 0)
        let layout = try #require(ShareLayout(info: info, destination: ShareSettings.normalized(dest)))

        for url in [info.url, info.url + "index.html"] {
            let (d, r) = try await TestSupport.fetch(url)
            #expect(r.statusCode == 200, "\(url)")
            #expect(r.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") == true, "\(url)")
            #expect(String(decoding: d, as: UTF8.self).contains("Reelbird dogfood check"))
        }
        let (pl, plr) = try await TestSupport.fetch(layout.baseURL + "hls/index.m3u8")
        #expect(plr.value(forHTTPHeaderField: "Content-Type") == "application/vnd.apple.mpegurl")
        #expect(plr.value(forHTTPHeaderField: "Cache-Control")?.contains("no-store") == true)
        #expect(String(decoding: pl, as: UTF8.self).hasSuffix("#EXT-X-ENDLIST\n"))
        let (_, sr) = try await TestSupport.fetch(layout.baseURL + "hls/seg_00001.m4s")
        #expect(sr.statusCode == 200)
        #expect(sr.value(forHTTPHeaderField: "Content-Type") == "video/iso.segment")
        let (_, mr) = try await TestSupport.fetch(layout.baseURL + "meta.json")
        #expect(mr.value(forHTTPHeaderField: "Cache-Control")?.contains("no-store") == true)

        // Polish: same link, MP4 + chapters + captions.
        let bundle = try TestSupport.bundle(in: dir, title: "Reelbird dogfood check", duration: stream.totalDuration, share: info)
        try bundle.writeEdit(Integration.edit(chapters: true))
        let mp4 = dir.appendingPathComponent("polished.mp4")
        try await Synthetic.mp4(opts, to: mp4)
        let vtt = dir.appendingPathComponent("captions.vtt")
        try Integration.captions.write(to: vtt, atomically: true, encoding: .utf8)
        let polished = try await ShareService.publish(bundle: bundle, video: mp4, poster: nil, captions: vtt,
                                                      destination: dest, secret: secret) { _ in }
        #expect(polished.url == info.url)
        let (md, _) = try await TestSupport.fetch(layout.baseURL + "meta.json?t=\(Date().timeIntervalSince1970)")
        let meta = try JSONCoding.decoder.decode(ViewerMeta.self, from: md)
        #expect(meta.video != nil && meta.chapters.count == 3)
        var req = URLRequest(url: URL(string: layout.baseURL + (meta.video ?? ""))!)
        req.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        let (_, vr) = try await URLSession.shared.data(for: req)
        #expect((vr as? HTTPURLResponse)?.statusCode == 206)
        #expect((vr as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "video/mp4")
        print("DOGFOOD SHARE: \(info.url)")

        if Integration.env["REELBIRD_DOGFOOD_CLEANUP"] == "1" {
            try await ShareService.unpublish(polished, destination: dest, secret: secret)
        }
    }

    @Test(.enabled(if: Integration.env["REELBIRD_DEMO_SERVE"] != nil))
    func serveDemoShares() async throws {
        let seconds = Double(Integration.env["REELBIRD_DEMO_SERVE"] ?? "") ?? 600
        let port = UInt16(Integration.env["REELBIRD_DEMO_PORT"] ?? "") ?? 8765
        let server = MockS3Server(bucket: "reelbird-demo")
        try server.start(port: port)
        defer { server.stop() }
        let dest = server.destination()
        let dir = try TestSupport.tempDir("demo")
        var lines: [String] = []

        // 1. Recorded live, then polished with chapters and captions.
        let opts = Synthetic.Options(width: 1280, height: 720, fps: 30, seconds: 18, title: "Onboarding flow", bitrate: 2_500_000)
        let stream = try await Synthetic.cmaf(opts)
        let up1 = LiveShareUploader(destination: dest, secret: server.secret, journalDirectory: dir.appendingPathComponent("j1"))
        let info1 = try await Integration.live(up1, title: "Onboarding flow walkthrough", stream: stream, realTime: false)
        let b1 = try TestSupport.bundle(in: dir.appendingPathComponent("b1"), title: "Onboarding flow walkthrough",
                                        duration: stream.totalDuration, share: info1)
        try b1.writeEdit(Integration.edit(chapters: true))
        let mp4 = dir.appendingPathComponent("polished.mp4")
        try await Synthetic.mp4(opts, to: mp4)
        let vtt = dir.appendingPathComponent("captions.vtt")
        try Integration.captions.write(to: vtt, atomically: true, encoding: .utf8)
        _ = try await ShareService.publish(bundle: b1, video: mp4, poster: nil, captions: vtt, destination: dest,
                                           secret: server.secret) { _ in }
        lines.append("polished \(info1.url)")

        // 2. Quick share only (HLS), finished.
        let up2 = LiveShareUploader(destination: dest, secret: server.secret, journalDirectory: dir.appendingPathComponent("j2"))
        let info2 = try await Integration.live(up2, title: "Quick bug repro: export button", stream: stream, realTime: false)
        lines.append("hls \(info2.url)")

        // 3. Recording right now, in real time.
        let long = try await Synthetic.cmaf(Synthetic.Options(width: 1280, height: 720, fps: 30, seconds: 150, title: "Live recording", bitrate: 1_500_000))
        let up3 = LiveShareUploader(destination: dest, secret: server.secret, journalDirectory: dir.appendingPathComponent("j3"))
        let liveTask = Task { try await Integration.live(up3, title: "Design review, live", stream: long, realTime: true) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        if let info3 = await up3.shareInfo { lines.append("live \(info3.url)") }

        let out = Integration.env["REELBIRD_DEMO_OUT"].map { URL(fileURLWithPath: $0) } ?? dir.appendingPathComponent("urls.txt")
        try lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        print("DEMO SHARES:\n" + lines.joined(separator: "\n"))
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        liveTask.cancel()
    }
}
