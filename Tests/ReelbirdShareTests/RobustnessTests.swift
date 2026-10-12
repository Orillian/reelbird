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
