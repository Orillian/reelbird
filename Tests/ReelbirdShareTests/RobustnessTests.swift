import Foundation
import ReelbirdCore
import Testing
@testable import ReelbirdShare

@Suite struct ClientRobustnessTests {
    /// A Mac whose clock is an hour off still uploads: the client learns the server clock from the
    /// RequestTimeTooSkewed answer and signs with it.
    @Test func clockSkewIsCorrectedFromTheServerDate() async throws {
        let server = try TestSupport.server()
        defer { server.stop() }
        server.clockSkew = 3_600
        let c = TestSupport.client(server, attempts: 1)
        try await c.put("r/skew.txt", data: Data("ok".utf8), contentType: "text/plain")
        #expect(server.object("r/skew.txt")?.data == Data("ok".utf8))
        // Learned once; later requests sign with the corrected clock straight away.
        try await c.put("r/skew2.txt", data: Data("ok".utf8), contentType: "text/plain")
        #expect(server.skewRejections == 1)
        #expect(abs(c.now.timeIntervalSinceNow - 3_600) < 5)
    }

    /// MinIO behind a reverse proxy: the endpoint's path is part of what gets signed.
    @Test func endpointWithAPathPrefixSignsTheFullPath() async throws {
        let server = try TestSupport.server()
        defer { server.stop() }
        server.pathPrefix = "/minio"
        var d = server.destination()
        d.endpoint = server.endpoint + "/minio/"
        let c = S3Client(destination: d, secret: server.secret, maxAttempts: 1)
        let key = "r/a b/ü+1.txt"
        try await c.put(key, data: Data("hi".utf8), contentType: "text/plain")
        #expect(server.object(key)?.data == Data("hi".utf8))
        #expect(try await c.list(prefix: "r/").objects.map(\.key) == [key])
        try await c.delete(key)
        #expect(server.object(key) == nil)
    }

    @Test func transientClassificationCoversS3Quirks() {
        #expect(ShareError(status: 400, code: "RequestTimeout", message: "").isTransient)
        #expect(ShareError(status: 503, code: "SlowDown", message: "").isTransient)
        #expect(ShareError(status: 0, message: "offline").isTransient)
        #expect(!ShareError(status: 403, code: "AccessDenied", message: "").isTransient)
        #expect(!ShareError(status: 400, code: "InvalidArgument", message: "").isTransient)
        let redirect = S3Client.describe(status: 301, code: "PermanentRedirect", serverMessage: nil, key: nil, bucket: "b", endpoint: "https://s3.amazonaws.com")
        #expect(redirect.message.contains("region"))
        #expect(S3Client.parseHTTPDate("Sun, 06 Nov 1994 08:49:37 GMT")?.timeIntervalSince1970 == 784_111_777)
    }
}

@Suite struct UploadQueueTests {
    /// Offline for a long stretch: uploads stay bounded (a few in flight, a few in memory, the rest
    /// spooled to disk), then everything lands in order once the network is back.
    @Test func longOutageKeepsMemoryBoundedAndCatchesUp() async throws {
        let server = try TestSupport.server()
        defer { server.stop() }
        let stream = try await Media.shared.cmaf()
        let journal = try TestSupport.tempDir("queue")
        let up = TestSupport.uploader(server, journal: journal, attempts: 1)
        let info = try await up.begin(recordingID: "rec", title: "Outage")
        let layout = try #require(ShareLayout(info: info, destination: server.destination()))
        server.setOffline(true)
        await up.initSegment(stream.initSegment)
        let count = 30
        for i in 1...count {
            let s = stream.segments[(i - 1) % stream.segments.count]
            await up.mediaSegment(index: i, data: s.data, duration: s.duration)
        }
        #expect(await up.state.uploadsInFlight <= LiveShareUploader.maxConcurrent)
        #expect(await up.state.queuedInMemory <= UploadState.memoryQueueLimit)
        #expect(await up.backlog == count + 1)
        let spool = journal.appendingPathComponent("\(layout.id).spool")
        let spooled = (try? FileManager.default.contentsOfDirectory(atPath: spool.path))?.count ?? 0
        #expect(spooled >= count - UploadState.memoryQueueLimit - UploadState.maxConcurrentSegments, "spooled \(spooled)")

        server.setOffline(false)
        await up.finish(totalDuration: Double(count) * 2, timeout: 60)
        #expect(await up.backlog == 0)
        let playlist = String(decoding: try #require(server.object(layout.playlistKey)).data, as: UTF8.self)
        #expect(TestSupport.playlistSegments(playlist).count == count)
        #expect(playlist.contains("#EXT-X-TARGETDURATION:4\n"))
        for i in [1, 9, 17, 30] {
            #expect(server.object(layout.segmentKey(i))?.data == stream.segments[(i - 1) % stream.segments.count].data)
        }
        #expect(!FileManager.default.fileExists(atPath: spool.path), "spool removed after completion")
        #expect(try TestSupport.meta(server, layout).status == .ready)
    }
}

extension LiveShareUploader {
    static var maxConcurrent: Int { UploadState.maxConcurrentSegments }
}
