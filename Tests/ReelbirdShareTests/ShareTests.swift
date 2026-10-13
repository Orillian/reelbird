import AVFoundation
import CoreGraphics
import Foundation
import ReelbirdCore
import Testing
@testable import ReelbirdShare

// MARK: - Helpers

enum TestSupport {
    static func tempDir(_ name: String = "share") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reelbird-share-tests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func server() throws -> MockS3Server {
        let s = MockS3Server()
        try s.start()
        return s
    }

    static func client(_ s: MockS3Server, attempts: Int = 3) -> S3Client {
        S3Client(destination: s.destination(), secret: s.secret, maxAttempts: attempts, baseDelay: 0.05)
    }

    static func uploader(_ s: MockS3Server, journal: URL, attempts: Int = 3) -> LiveShareUploader {
        LiveShareUploader(destination: s.destination(), client: client(s, attempts: attempts), journalDirectory: journal)
    }

    static func bundle(in dir: URL, title: String = "Quarterly walkthrough", duration: Double = 6,
                       share: ShareInfo? = nil) throws -> ProjectBundle {
        let b = try ProjectBundle.create(at: dir.appendingPathComponent("Test.reelbird"))
        let m = ProjectManifest(title: title, appVersion: "test", status: .complete,
                                capture: CaptureInfo(source: .synthetic(name: "test"), pixelSize: PixelSize(width: 640, height: 360),
                                                     scale: 1, frameRate: 30),
                                clock: ClockInfo(originHostTime: 0), duration: duration, share: share)
        try b.writeManifest(m)
        return b
    }

    static func fetch(_ url: String) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: URL(string: url)!, cachePolicy: .reloadIgnoringLocalCacheData)
        req.httpMethod = "GET"
        let (d, r) = try await URLSession.shared.data(for: req)
        return (d, r as! HTTPURLResponse)
    }

    static func meta(_ s: MockS3Server, _ layout: ShareLayout) throws -> ViewerMeta {
        guard let o = s.object(layout.metaKey) else { throw ShareError(status: 404, message: "no meta") }
        return try JSONCoding.decoder.decode(ViewerMeta.self, from: o.data)
    }

    static func waitUntil(_ timeout: Double = 20, _ condition: () async throws -> Bool) async throws -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if try await condition() { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    static func playlistSegments(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty }
    }
}

/// Synthetic media is generated once and shared by every test.
actor Media {
    static let shared = Media()
    private var stream: Synthetic.Stream?
    private var mp4: URL?

    func cmaf() async throws -> Synthetic.Stream {
        if let stream { return stream }
        let s = try await Synthetic.cmaf(Synthetic.Options(seconds: 6))
        stream = s
        return s
    }

    func polished() async throws -> URL {
        if let mp4 { return mp4 }
        let url = try TestSupport.tempDir("media").appendingPathComponent("polished.mp4")
        try await Synthetic.mp4(Synthetic.Options(seconds: 3), to: url)
        mp4 = url
        return url
    }
}

// MARK: - Media generation

@Suite struct SyntheticMediaTests {
    @Test func cmafStreamHasInitAndTwoSecondSegments() async throws {
        let s = try await Media.shared.cmaf()
        #expect(s.initSegment.count > 100)
        #expect(String(decoding: s.initSegment[4..<8], as: UTF8.self) == "ftyp")
        #expect(s.segments.count >= 3)
        #expect(abs(s.totalDuration - 6) < 0.6)
        for seg in s.segments.dropLast() { #expect(abs(seg.duration - 2) < 0.2) }
    }

    /// The viewer's HLS-only Download joins init + segments; that must be a playable MP4.
    @Test func joinedSegmentsArePlayableMP4() async throws {
        let s = try await Media.shared.cmaf()
        var joined = s.initSegment
        for seg in s.segments { joined.append(seg.data) }
        let url = try TestSupport.tempDir("joined").appendingPathComponent("joined.mp4")
        try joined.write(to: url)
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        #expect(abs(duration - s.totalDuration) < 0.3)
        #expect(try await asset.load(.isPlayable))
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    }
}

// MARK: - Live upload

@Suite(.serialized) struct LiveUploadTests {
    @Test func liveUploadEndToEnd() async throws {
        let server = try TestSupport.server()
        defer { server.stop() }
        let journal = try TestSupport.tempDir("journal")
        let stream = try await Media.shared.cmaf()
        let up = TestSupport.uploader(server, journal: journal)

        let info = try await up.begin(recordingID: "rec1", title: "Bug <repro> & notes")
        let layout = try #require(ShareLayout(info: info, destination: server.destination()))
        #expect(info.url == "\(server.publicBase)/r/\(layout.id)/")
        #expect(layout.id.count == 14)

        // Placeholder exists before any media: every form of the link serves the page.
        for k in layout.pageKeys {
            let o = try #require(server.object(k))
            #expect(o.contentType.hasPrefix("text/html"))
        }
        let m0 = try TestSupport.meta(server, layout)
        #expect(m0.status == .recording)
        #expect(m0.hls == nil)
        #expect(server.object(layout.cardKey)?.contentType == "image/jpeg")
        let journalFile = journal.appendingPathComponent("\(layout.id).json")
        #expect(FileManager.default.fileExists(atPath: journalFile.path))

        // Segment 1 lands last: the playlist must not list 2 and 3 before 1 is up.
        server.delay(layout.segmentKey(1), seconds: 0.8)
        await up.initSegment(stream.initSegment)
        for (i, s) in stream.segments.enumerated() {
            await up.mediaSegment(index: i + 1, data: s.data, duration: s.duration)
        }
        #expect(await up.backlog > 0)
        await up.finish(totalDuration: stream.totalDuration, timeout: 15)
        #expect(await up.backlog == 0)

        let versions = server.versions(layout.playlistKey).map { String(decoding: $0, as: UTF8.self) }
        #expect(!versions.isEmpty)
        for v in versions {
            let segs = TestSupport.playlistSegments(v)
            #expect(segs == (0..<segs.count).map { layout.segmentName($0 + 1) }, "non-contiguous playlist: \(segs)")
        }
        let first = try #require(versions.first)
        #expect(TestSupport.playlistSegments(first).first == "seg_00001.m4s")

        let final = try #require(versions.last)
        #expect(final.contains("#EXT-X-PLAYLIST-TYPE:EVENT"))
        #expect(final.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        #expect(final.hasSuffix("#EXT-X-ENDLIST\n"))
        #expect(TestSupport.playlistSegments(final).count == stream.segments.count)

        let m = try TestSupport.meta(server, layout)
        #expect(m.status == .ready)
        #expect(m.hls == "hls/index.m3u8")
        #expect(abs((m.duration ?? 0) - stream.totalDuration) < 0.01)
        #expect(!FileManager.default.fileExists(atPath: journalFile.path))

        // Served publicly with the right types and caching.
        let (page, pageResp) = try await TestSupport.fetch(info.url)
        #expect(pageResp.statusCode == 200)
        #expect(pageResp.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") == true)
        let html = String(decoding: page, as: UTF8.self)
        #expect(html.contains("Bug &lt;repro&gt; &amp; notes"))
        #expect(!html.contains("<repro>"))
        let (_, plResp) = try await TestSupport.fetch(m.url(m.hls)!)
        #expect(plResp.value(forHTTPHeaderField: "Content-Type") == "application/vnd.apple.mpegurl")
        #expect(plResp.value(forHTTPHeaderField: "Cache-Control")?.contains("no-store") == true)
        let (seg, segResp) = try await TestSupport.fetch(layout.baseURL + "hls/seg_00002.m4s")
        #expect(segResp.value(forHTTPHeaderField: "Content-Type") == "video/iso.segment")
        #expect(segResp.value(forHTTPHeaderField: "Cache-Control")?.contains("immutable") == true)
        #expect(seg == stream.segments[1].data)
        let (_, metaResp) = try await TestSupport.fetch(layout.baseURL + "meta.json")
        #expect(metaResp.value(forHTTPHeaderField: "Cache-Control")?.contains("no-store") == true)
        let (initData, initResp) = try await TestSupport.fetch(layout.baseURL + "hls/init.mp4")
        #expect(initResp.value(forHTTPHeaderField: "Content-Type") == "video/mp4")
        #expect(initData == stream.initSegment)
    }

    @Test func transientFailuresAreRetried() async throws {
        let server = try TestSupport.server()
        defer { server.stop() }
        let stream = try await Media.shared.cmaf()
        let up = TestSupport.uploader(server, journal: try TestSupport.tempDir("journal"))
        let info = try await up.begin(recordingID: "rec", title: "Retry")
        let layout = try #require(ShareLayout(info: info, destination: server.destination()))
        server.fail(layout.segmentKey(2), count: 4, status: 503)   // more than one client attempt cycle
        server.fail(layout.initKey, count: 1, status: 500)
        await up.initSegment(stream.initSegment)
        for (i, s) in stream.segments.enumerated() { await up.mediaSegment(index: i + 1, data: s.data, duration: s.duration) }
        await up.finish(totalDuration: stream.totalDuration, timeout: 20)
        let m = try TestSupport.meta(server, layout)
        #expect(m.status == .ready)
        #expect(server.object(layout.segmentKey(2))?.data == stream.segments[1].data)
    }

    @Test func offlineFinishTimesOutThenCompletesInBackground() async throws {
        let server = try TestSupport.server()
        defer { server.stop() }
        let stream = try await Media.shared.cmaf()
        let up = TestSupport.uploader(server, journal: try TestSupport.tempDir("journal"), attempts: 2)
        let info = try await up.begin(recordingID: "rec", title: "Offline")
        let layout = try #require(ShareLayout(info: info, destination: server.destination()))
        server.setOffline(true)
        await up.initSegment(stream.initSegment)
        for (i, s) in stream.segments.enumerated() { await up.mediaSegment(index: i + 1, data: s.data, duration: s.duration) }
        let start = Date()
        await up.finish(totalDuration: stream.totalDuration, timeout: 0.6)
        #expect(Date().timeIntervalSince(start) < 3)
        #expect(await up.backlog > 0)
        #expect(await up.lastError != nil)
        server.setOffline(false)
        let ready = try await TestSupport.waitUntil(30) { (try? TestSupport.meta(server, layout))?.status == .ready }
        #expect(ready)
        #expect(await up.backlog == 0)
    }

    @Test func cancelDeletesEverything() async throws {
        let server = try TestSupport.server()
        defer { server.stop() }
        let stream = try await Media.shared.cmaf()
        let up = TestSupport.uploader(server, journal: try TestSupport.tempDir("journal"))
        let info = try await up.begin(recordingID: "rec", title: "Discard me")
        await up.initSegment(stream.initSegment)
        await up.mediaSegment(index: 1, data: stream.segments[0].data, duration: stream.segments[0].duration)
        _ = try await TestSupport.waitUntil(5) { server.object("\(info.key)/hls/seg_00001.m4s") != nil }
        await up.cancel()
        #expect(server.keys(prefix: info.key).isEmpty)
    }

    @Test func badCredentialsFailBeginWithClearMessage() async throws {
        let server = try TestSupport.server()
        defer { server.stop() }
        let client = S3Client(destination: server.destination(), secret: "wrong", maxAttempts: 2, baseDelay: 0.01)
        let up = LiveShareUploader(destination: server.destination(), client: client, journalDirectory: try TestSupport.tempDir("j"))
        let error = await #expect(throws: ShareError.self) { try await up.begin(recordingID: "r", title: "t") }
        #expect(error?.message.contains("secret") == true)
        #expect(server.keys().isEmpty)
    }

    @Test func resumeFinishesAnInterruptedUpload() async throws {
        let server = try TestSupport.server()
        defer { server.stop() }
        let stream = try await Media.shared.cmaf()
        let dir = try TestSupport.tempDir("resume")
        let journal = dir.appendingPathComponent("journal")
        let up = TestSupport.uploader(server, journal: journal)
        let info = try await up.begin(recordingID: "rec", title: "Crashy")
        let layout = try #require(ShareLayout(info: info, destination: server.destination()))

        // Only init + segment 1 make it before the "crash".
        await up.initSegment(stream.initSegment)
        await up.mediaSegment(index: 1, data: stream.segments[0].data, duration: stream.segments[0].duration)
        _ = try await TestSupport.waitUntil(5) { server.object(layout.playlistKey) != nil }
        server.setOffline(true)
        for (i, s) in stream.segments.enumerated().dropFirst() { await up.mediaSegment(index: i + 1, data: s.data, duration: s.duration) }
        await up.simulateCrash()
        server.setOffline(false)
        #expect(FileManager.default.fileExists(atPath: journal.appendingPathComponent("\(layout.id).json").path))

        // The recorder kept every segment in the bundle.
        let bundle = try TestSupport.bundle(in: dir, share: info)
        let shareDir = bundle.directory(for: .share)
        try FileManager.default.createDirectory(at: shareDir, withIntermediateDirectories: true)
        try stream.initSegment.write(to: shareDir.appendingPathComponent("init.mp4"))
        for (i, s) in stream.segments.enumerated() {
            try s.data.write(to: shareDir.appendingPathComponent(String(format: "seg_%05d.m4s", i + 1)))
        }

        let again = TestSupport.uploader(server, journal: journal)
        let resumed = try await again.resumeIfNeeded(bundle: bundle)
        #expect(resumed?.url == info.url)
        let playlist = String(decoding: try #require(server.object(layout.playlistKey)).data, as: UTF8.self)
        #expect(playlist.hasSuffix("#EXT-X-ENDLIST\n"))
        #expect(TestSupport.playlistSegments(playlist).count == stream.segments.count)
        for i in 1...stream.segments.count { #expect(server.object(layout.segmentKey(i))?.data == stream.segments[i - 1].data) }
        #expect(try TestSupport.meta(server, layout).status == .ready)
        #expect(!FileManager.default.fileExists(atPath: journal.appendingPathComponent("\(layout.id).json").path))

        // Nothing left to do the second time.
        let third = TestSupport.uploader(server, journal: journal)
        #expect(try await third.resumeIfNeeded(bundle: bundle) == nil)
    }
}

// MARK: - Publish

@Suite(.serialized) struct PublishTests {
    @Test func publishCreatesUpdatesInPlaceAndUnpublishes() async throws {
        let server = try TestSupport.server()
        defer { server.stop() }
        let dir = try TestSupport.tempDir("publish")
        let video = try await Media.shared.polished()
        var bundle = try TestSupport.bundle(in: dir, duration: 3)
        var edit = EditDocument()
        edit.trim = TimeRange(start: 0, end: 3)
        edit.chapters = [Chapter(time: 1.5, title: "The fix"), Chapter(time: 0, title: "Intro")]
        try bundle.writeEdit(edit)
        let vtt = dir.appendingPathComponent("captions.vtt")
        try "WEBVTT\n\n00:00.000 --> 00:01.500\nHello there\n".write(to: vtt, atomically: true, encoding: .utf8)

        let progress = ProgressLog()
        let info = try await ShareService.publish(bundle: bundle, video: video, poster: nil, captions: vtt,
                                                  destination: server.destination(), secret: server.secret,
                                                  session: nil) { p in Task { await progress.add(p) } }
        #expect(info.polished)
        let layout = try #require(ShareLayout(info: info, destination: server.destination()))
        let m1 = try TestSupport.meta(server, layout)
        #expect(m1.video == "video.1.mp4")
        #expect(m1.width == 640 && m1.height == 360)
        #expect(abs((m1.duration ?? 0) - 3) < 0.1)
        #expect(m1.chapters.map(\.title) == ["Intro", "The fix"])
        #expect(m1.poster == "poster.1.jpg")
        #expect(m1.captions == "captions.1.vtt")
        #expect(server.object(layout.key("video.1.mp4"))?.contentType == "video/mp4")
        #expect(server.object(layout.key("video.1.mp4"))?.cacheControl?.contains("immutable") == true)
        #expect(server.object(layout.key("captions.1.vtt"))?.contentType.hasPrefix("text/vtt") == true)
        let html = String(decoding: try #require(server.object(layout.pageKeys[0])).data, as: UTF8.self)
        #expect(html.contains(#"<meta property="og:video" content="\#(layout.baseURL)video.1.mp4">"#))
        #expect(html.contains(#"<meta property="og:image" content="\#(layout.baseURL)poster.1.jpg">"#))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await progress.last == 1)

        // Range requests work (Safari needs them for MP4).
        var req = URLRequest(url: URL(string: layout.baseURL + "video.1.mp4")!)
        req.setValue("bytes=0-99", forHTTPHeaderField: "Range")
        let (part, resp) = try await URLSession.shared.data(for: req)
        #expect((resp as? HTTPURLResponse)?.statusCode == 206)
        #expect(part.count == 100)

        // Update in place: same link, new revision, old assets cleaned up.
        var manifest = try bundle.readManifest()
        manifest.share = info
        try bundle.writeManifest(manifest)
        edit.title = "Quarterly walkthrough (final)"
        try bundle.writeEdit(edit)
        let info2 = try await ShareService.publish(bundle: bundle, video: video, poster: nil, captions: nil,
                                                   destination: server.destination(), secret: server.secret,
                                                   session: nil) { _ in }
        #expect(info2.url == info.url && info2.key == info.key)
        let m2 = try TestSupport.meta(server, layout)
        #expect(m2.revision == 2)
        #expect(m2.title == "Quarterly walkthrough (final)")
        #expect(m2.video == "video.2.mp4")
        #expect(m2.captions == "captions.1.vtt")   // kept: not replaced
        #expect(server.object(layout.key("video.1.mp4")) == nil)
        #expect(server.object(layout.key("poster.1.jpg")) == nil)
        #expect(server.object(layout.key("video.2.mp4")) != nil)
        #expect(m2.createdAt == m1.createdAt)

        bundle = ProjectBundle(url: bundle.url)
        try await ShareService.unpublish(info2, destination: server.destination(), secret: server.secret)
        #expect(server.keys(prefix: info.key).isEmpty)
    }

    @Test func publishAfterLiveKeepsTheStreamAndAddsTheMP4() async throws {
        let server = try TestSupport.server()
        defer { server.stop() }
        let stream = try await Media.shared.cmaf()
        let up = TestSupport.uploader(server, journal: try TestSupport.tempDir("journal"))
        let info = try await up.begin(recordingID: "rec", title: "Live then polished")
        await up.initSegment(stream.initSegment)
        for (i, s) in stream.segments.enumerated() { await up.mediaSegment(index: i + 1, data: s.data, duration: s.duration) }
        await up.finish(totalDuration: stream.totalDuration, timeout: 15)

        let bundle = try TestSupport.bundle(in: try TestSupport.tempDir("p"), share: info)
        let out = try await ShareService.publish(bundle: bundle, video: try await Media.shared.polished(), poster: nil,
                                                 captions: nil, destination: server.destination(), secret: server.secret,
                                                 session: nil) { _ in }
        #expect(out.url == info.url)
        let layout = try #require(ShareLayout(info: info, destination: server.destination()))
        let m = try TestSupport.meta(server, layout)
        #expect(m.hls == "hls/index.m3u8")
        #expect(m.video == "video.1.mp4")
        #expect(server.object(layout.segmentKey(1)) != nil)
    }

    @Test func testConnectionReportsWhatToFix() async throws {
        let server = try TestSupport.server()
        defer { server.stop() }
        try await ShareService.testConnection(server.destination(), secret: server.secret, session: nil)
        #expect(server.keys().isEmpty, "the check object is cleaned up")

        let wrongSecret = await #expect(throws: ShareError.self) {
            try await ShareService.testConnection(server.destination(), secret: "nope", session: nil)
        }
        #expect(wrongSecret?.message.contains("secret") == true)

        var badBucket = server.destination()
        badBucket.bucket = "missing"
        let noBucket = await #expect(throws: ShareError.self) {
            try await ShareService.testConnection(badBucket, secret: server.secret, session: nil)
        }
        #expect(noBucket?.message.contains("doesn't exist") == true)

        var badPublic = server.destination()
        badPublic.publicBaseURL = server.endpoint + "/elsewhere"
        let noPublic = await #expect(throws: ShareError.self) {
            try await ShareService.testConnection(badPublic, secret: server.secret, session: nil)
        }
        #expect(noPublic?.code == "PublicURL")
        #expect(server.keys().isEmpty)

        let empty = await #expect(throws: ShareError.self) {
            try await ShareService.testConnection(server.destination(), secret: " ", session: nil)
        }
        #expect(empty?.code == "InvalidSettings")
    }
}

actor ProgressLog {
    var values: [Double] = []
    func add(_ v: Double) { values.append(v) }
    var last: Double? { values.max() }
}

// MARK: - S3 client

@Suite struct S3ClientTests {
    @Test func listPaginatesAndDeletePrefixRemovesOnlyThatPrefix() async throws {
        let server = try TestSupport.server()
        defer { server.stop() }
        server.listPageSize = 3
        for i in 0..<10 { server.put("r/abc/f\(i)", Data([UInt8(i)])) }
        server.put("r/abcd/keep", Data([1]))
        server.put("r/abc", Data([1]))
        let c = TestSupport.client(server)
        let all = try await c.listAll(prefix: "r/abc/")
        #expect(all.count == 10)
        #expect(try await c.deletePrefix("r/abc/") == 10)
        #expect(server.keys() == ["r/abc", "r/abcd/keep"])
        await #expect(throws: ShareError.self) { try await c.deletePrefix("") }
    }

    @Test func headPutDeleteAndKeysNeedingEncoding() async throws {
        let server = try TestSupport.server()
        defer { server.stop() }
        let c = TestSupport.client(server)
        let key = "r/a b+c/ü (1).txt"
        try await c.put(key, data: Data("hi".utf8), contentType: "text/plain", cacheControl: "no-store")
        let h = try await c.head(key)
        #expect(h?.size == 2)
        #expect(h?.contentType == "text/plain")
        #expect(h?.cacheControl == "no-store")
        #expect(try await c.get(key) == Data("hi".utf8))
        try await c.delete(key)
        #expect(try await c.head(key) == nil)
        try await c.delete(key)   // deleting twice is fine
    }

    @Test func multipartUploadReassemblesTheFile() async throws {
        let server = try TestSupport.server()
        defer { server.stop() }
        let c = TestSupport.client(server)
        let url = try TestSupport.tempDir("mp").appendingPathComponent("big.bin")
        var bytes = [UInt8](repeating: 0, count: 12 * 1024 * 1024 + 123)
        for i in stride(from: 0, to: bytes.count, by: 4096) { bytes[i] = UInt8(truncatingIfNeeded: i / 4096) }
        try Data(bytes).write(to: url)
        let progress = ProgressLog()
        try await c.uploadFile("r/x/video.mp4", file: url, contentType: "video/mp4", cacheControl: ShareLayout.immutable,
                               partSize: 5 << 20, multipartThreshold: 6 << 20) { p in Task { await progress.add(p) } }
        let o = try #require(server.object("r/x/video.mp4"))
        #expect(o.data == Data(bytes))
        #expect(o.contentType == "video/mp4")
        #expect(server.openMultipartUploads == 0)
        let parts = server.requests().filter { $0.method == "PUT" && $0.query.contains("partNumber") }
        #expect(parts.count == 3)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await progress.last == 1)
    }

    @Test func errorMessagesSayWhatToCheck() {
        let d = ShareSettings.normalized(ShareDestination(endpoint: "e", bucket: "b", accessKeyID: "k", publicBaseURL: "p"))
        func msg(_ status: Int, _ code: String?) -> String {
            S3Client.describe(status: status, code: code, serverMessage: nil, key: nil, bucket: d.bucket, endpoint: d.endpoint).message
        }
        #expect(msg(403, "AccessDenied").contains("check the access key") || msg(403, "AccessDenied").contains("Check the access key"))
        #expect(msg(403, "SignatureDoesNotMatch").contains("secret"))
        #expect(msg(403, "InvalidAccessKeyId").contains("access key"))
        #expect(msg(404, "NoSuchBucket").contains("doesn't exist"))
        #expect(msg(403, "RequestTimeTooSkewed").contains("clock"))
        #expect(S3Client.describe(urlError: URLError(.cannotFindHost), endpoint: "https://x.example", key: nil).message.contains("x.example"))
    }
}

// MARK: - Settings

@Suite struct SettingsTests {
    @Test func environmentDestination() {
        let env = [
            "REELBIRD_S3_ENDPOINT": "acc.r2.cloudflarestorage.com/",
            "REELBIRD_S3_BUCKET": " videos ",
            "REELBIRD_S3_ACCESS_KEY_ID": "AK",
            "REELBIRD_S3_PUBLIC_BASE_URL": "https://pub-1.r2.dev/",
        ]
        let d = ShareSettings.fromEnvironment(env)
        #expect(d == ShareDestination(endpoint: "https://acc.r2.cloudflarestorage.com", bucket: "videos", region: "auto",
                                      accessKeyID: "AK", publicBaseURL: "https://pub-1.r2.dev", prefix: "r"))
        #expect(ShareSettings.fromEnvironment(["REELBIRD_S3_BUCKET": "x"]) == nil)
    }

    @Test func validationNamesTheMissingField() {
        let ok = ShareDestination(endpoint: "https://e.example", bucket: "b", accessKeyID: "k", publicBaseURL: "https://p.example")
        #expect(throws: Never.self) { try ShareSettings.validate(ok, secret: "s") }
        var noBucket = ok; noBucket.bucket = ""
        #expect { try ShareSettings.validate(noBucket, secret: "s") } throws: { ($0 as? ShareError)?.message.contains("bucket") == true }
        #expect { try ShareSettings.validate(ok, secret: "") } throws: { ($0 as? ShareError)?.message.contains("secret") == true }
    }

    @Test func keychainRoundTrip() throws {
        let service = "app.reelbird.share.test-\(UUID().uuidString)"
        defer { try? Keychain.deleteAll(service: service) }
        try Keychain.set("first", service: service, account: "AK")
        #expect(Keychain.get(service: service, account: "AK") == "first")
        try Keychain.set("second", service: service, account: "AK")
        #expect(Keychain.get(service: service, account: "AK") == "second")
        try Keychain.deleteAll(service: service)
        #expect(Keychain.get(service: service, account: "AK") == nil)
    }
}

// MARK: - Viewer page and playlists

@Suite struct ViewerPageTests {
    func meta(_ status: ViewerMeta.Status = .ready, video: Bool = true) -> ViewerMeta {
        ViewerMeta(id: "AbC", title: "Fix </script><script>alert(1)</script> \"quotes\"", status: status,
                   createdAt: Date(timeIntervalSince1970: 1_760_000_000), duration: 134.4,
                   pageURL: "https://pub.example/r/AbC/", baseURL: "https://pub.example/r/AbC/",
                   hls: "hls/index.m3u8", video: video ? "video.1.mp4" : nil, width: 1920, height: 1080,
                   poster: video ? "poster.1.jpg" : nil, card: "card.jpg",
                   chapters: [Chapter(time: 0, title: "Intro")], revision: 1)
    }

    @Test func readyPageHasUnfurlTagsAndEscapesEverything() {
        let html = ViewerPage.html(meta())
        #expect(html.hasPrefix("<!doctype html>"))
        #expect(!html.contains("</script><script>alert(1)"))
        #expect(html.contains("Fix &lt;/script&gt;"))
        #expect(html.contains(#"<meta property="og:video" content="https://pub.example/r/AbC/video.1.mp4">"#))
        #expect(html.contains(#"<meta property="og:video:secure_url""#))
        #expect(html.contains(#"<meta property="og:image" content="https://pub.example/r/AbC/poster.1.jpg">"#))
        #expect(html.contains(#"<meta property="og:video:width" content="1920">"#))
        #expect(html.contains(#"<meta name="twitter:card" content="summary_large_image">"#))
        #expect(html.contains(#"<meta name="robots" content="noindex, nofollow">"#))
        #expect(html.contains("A 2:14 screen recording."))
        #expect(html.contains("aspect-ratio:1920 / 1080"))
        #expect(html.contains("https://github.com/btahir/reelbird"))
        #expect(html.contains("hls.js@\(ViewerPage.hlsVersion)/dist/hls.light.min.js"))
        #expect(html.contains("sha384-"))
        #expect(!html.contains("{{"))
        // Embedded JSON can't close the script element.
        let start = html.range(of: #"<script type="application/json" id="meta">"#)!.upperBound
        let end = html.range(of: "</script>", range: start..<html.endIndex)!.lowerBound
        let json = String(html[start..<end])
        let decoded = try? JSONCoding.decoder.decode(ViewerMeta.self, from: Data(json.utf8))
        #expect(decoded?.title == meta().title)
        #expect(decoded?.chapters == meta().chapters)
    }

    @Test func placeholdersInTheTitleStayText() {
        var m = meta()
        m.title = #"0;url=https://evil.example/#{{TITLE}}" http-equiv=refresh x="{{META}}{{REPO}}"#
        let html = ViewerPage.html(m)
        // The quote stays escaped in every tag, so no attribute can break out (the JSON block escapes it as \").
        let tags = html.components(separatedBy: "<").filter { $0.hasPrefix("meta ") }
        #expect(!tags.isEmpty && !tags.contains { $0.contains(#"" http-equiv"#) })
        #expect(html.contains("{{TITLE}}&quot; http-equiv=refresh"))
        #expect(html.components(separatedBy: #"<script type="application/json" id="meta">"#).count == 2)
        #expect(ViewerPage.fill("a{{X}}b{{Y}}c{{", ["X": "{{Y}}", "Y": "2"]) == "a{{Y}}b2c{{")
    }

    @Test func recordingPageUsesTheTitleCard() {
        let html = ViewerPage.html(meta(.recording, video: false))
        #expect(!html.contains("og:video"))
        #expect(html.contains(#"<meta property="og:image" content="https://pub.example/r/AbC/card.jpg">"#))
        #expect(html.contains(#"<meta property="og:image:width" content="1200">"#))
        #expect(html.contains("in progress"))
    }

    @Test func titleCardRenders() throws {
        let jpeg = try #require(TitleCard.jpeg(title: "A long title that needs to wrap across more than one line to fit the card nicely"))
        #expect(jpeg.count > 5_000)
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]))
    }

    @Test func playlistHelpers() {
        let text = HLSPlaylist.event(durations: [2, 2, 1.25], ended: true) { String(format: "seg_%05d.m4s", $0) }
        #expect(text.hasPrefix("#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-PLAYLIST-TYPE:EVENT\n#EXT-X-TARGETDURATION:4\n"))
        #expect(text.contains("#EXTINF:1.25000,\nseg_00003.m4s\n#EXT-X-ENDLIST\n"))
        #expect(HLSPlaylist.durations(fromPlaylist: text) == [1: 2, 2: 2, 3: 1.25])
        #expect(HLSPlaylist.segmentNumber("seg_00012.m4s") == 12)
        #expect(HLSPlaylist.segmentNumber("init.mp4") == nil)
        let open = HLSPlaylist.event(durations: [2.4], ended: false) { "s\($0).m4s" }
        #expect(open.contains("#EXT-X-TARGETDURATION:4"))
        #expect(HLSPlaylist.targetDuration([2.03, 1.97]) == 4)
        #expect(HLSPlaylist.targetDuration([2, 6.6]) == 7)
        #expect(!open.contains("ENDLIST"))
    }

    @Test func layoutKeys() {
        let d = ShareDestination(endpoint: "https://e", bucket: "b", accessKeyID: "k", publicBaseURL: "https://pub.example/", prefix: "/v/")
        let l = ShareLayout(id: "XyZ", destination: d)
        #expect(l.key == "v/XyZ")
        #expect(l.pageURL == "https://pub.example/v/XyZ/")
        #expect(l.pageKeys == ["v/XyZ/index.html", "v/XyZ/", "v/XyZ"])
        #expect(l.segmentKey(7) == "v/XyZ/hls/seg_00007.m4s")
        #expect(ShareLayout(info: ShareInfo(key: "v/XyZ", url: ""), destination: d)?.id == "XyZ")
        // A share made before the prefix changed keeps its folder.
        let old = ShareLayout(info: ShareInfo(key: "old/links/AbC", url: ""), destination: d)
        #expect(old?.folder == "old/links/AbC/")
        #expect(ShareLayout(info: ShareInfo(key: "AbC", url: ""), destination: d)?.key == "v/AbC")
        #expect(ShareLayout(info: ShareInfo(key: "", url: ""), destination: d) == nil)
    }
}
