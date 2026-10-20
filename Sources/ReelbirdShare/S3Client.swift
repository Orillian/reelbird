import Foundation
import ReelbirdCore
import Synchronization

/// A failed storage request, with a message a person can act on.
public struct ShareError: Error, LocalizedError, Hashable, Sendable {
    /// HTTP status, or 0 for network-level failures.
    public var status: Int
    /// S3 error code from the response body (e.g. "SignatureDoesNotMatch"), if any.
    public var code: String?
    public var message: String
    public var key: String?

    public init(status: Int, code: String? = nil, message: String, key: String? = nil) {
        self.status = status; self.code = code; self.message = message; self.key = key
    }

    public var errorDescription: String? { message }

    /// Worth retrying: network errors, throttling, server errors, and S3's idle-socket
    /// `RequestTimeout` (sent as HTTP 400).
    var isTransient: Bool {
        status == 0 || status == 408 || status == 429 || status >= 500 || code == "RequestTimeout" || code == "SlowDown"
    }
}

/// One object from a listing or HEAD.
public struct S3Object: Hashable, Sendable {
    public var key: String
    public var size: Int64
    public var etag: String?
    public var contentType: String?
    public var cacheControl: String?
}

/// Minimal S3-compatible client (path-style addressing, SigV4), no dependencies.
///
/// Every request goes through a concurrency limit and retries transient failures with
/// exponential backoff and jitter. Works with Cloudflare R2 (`region: "auto"`), AWS S3,
/// Backblaze B2 and MinIO.
public final class S3Client: Sendable {
    public let destination: ShareDestination
    let signer: SigV4Signer
    /// Reelbird Cloud: per-share keys from the server instead of `signer`.
    let cloud: CloudKeys?
    let session: URLSession
    let gate: AsyncGate
    let maxAttempts: Int
    let baseDelay: Double
    /// Endpoint without a trailing slash, e.g. "https://acc.r2.cloudflarestorage.com".
    let endpoint: String
    /// Scheme + host (+ port) of the endpoint.
    let origin: String
    /// Path the endpoint is mounted under ("" normally; "/minio" behind a reverse proxy). It is part
    /// of the signed canonical URI.
    let basePath: String
    /// Server clock minus local clock, learned from `RequestTimeTooSkewed` responses, so a Mac
    /// whose clock is off by more than SigV4's 15 minutes still uploads.
    private let clockOffset = Mutex<Double>(0)

    /// - Parameters:
    ///   - maxConcurrent: requests in flight at once (default 6).
    ///   - maxAttempts: tries per request including the first (default 5).
    public init(destination: ShareDestination, secret: String, session: URLSession? = nil,
                maxConcurrent: Int = 6, maxAttempts: Int = 5, baseDelay: Double = 0.4) {
        self.destination = destination
        let region = destination.region.isEmpty ? "auto" : destination.region
        self.signer = SigV4Signer(accessKeyID: destination.accessKeyID, secretAccessKey: secret, region: region)
        self.cloud = destination.cloudServer.map { CloudKeys.shared(server: $0, token: secret, region: region) }
        self.session = session ?? S3Client.makeSession()
        self.gate = AsyncGate(limit: maxConcurrent)
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        var e = destination.endpoint.trimmingCharacters(in: .whitespaces)
        while e.hasSuffix("/") { e.removeLast() }
        if !e.contains("://") { e = "https://" + e }
        self.endpoint = e
        if let c = URLComponents(string: e), let scheme = c.scheme, let host = c.host {
            origin = "\(scheme)://\(host)" + (c.port.map { ":\($0)" } ?? "")
            var p = c.percentEncodedPath
            while p.hasSuffix("/") { p.removeLast() }
            basePath = p.removingPercentEncoding ?? p
        } else {
            origin = e
            basePath = ""
        }
    }

    /// Now, corrected by the server clock offset.
    var now: Date { Date().addingTimeInterval(clockOffset.withLock { $0 }) }

    static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 15 * 60
        c.httpMaximumConnectionsPerHost = 8
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }

    // MARK: Object operations

    /// PUT an object. The payload is SHA-256 signed.
    public func put(_ key: String, data: Data, contentType: String, cacheControl: String? = nil) async throws {
        var headers = ["content-type": contentType]
        if let cacheControl { headers["cache-control"] = cacheControl }
        _ = try await send("PUT", key: key, headers: headers, body: data)
    }

    /// GET an object's bytes.
    public func get(_ key: String) async throws -> Data {
        try await send("GET", key: key).data
    }

    /// HEAD an object; `nil` if it does not exist.
    public func head(_ key: String) async throws -> S3Object? {
        do {
            let r = try await send("HEAD", key: key)
            return S3Object(key: key,
                            size: Int64(r.response.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0,
                            etag: r.response.value(forHTTPHeaderField: "ETag"),
                            contentType: r.response.value(forHTTPHeaderField: "Content-Type"),
                            cacheControl: r.response.value(forHTTPHeaderField: "Cache-Control"))
        } catch let e as ShareError where e.status == 404 {
            return nil
        }
    }

    /// DELETE an object. Deleting a missing object succeeds.
    public func delete(_ key: String) async throws {
        do { _ = try await send("DELETE", key: key) } catch let e as ShareError where e.status == 404 {}
    }

    /// One page of ListObjectsV2.
    public func list(prefix: String, continuationToken: String? = nil, maxKeys: Int = 1000) async throws
        -> (objects: [S3Object], nextToken: String?) {
        var q: [(String, String)] = [("list-type", "2"), ("prefix", prefix), ("max-keys", String(maxKeys))]
        if let continuationToken { q.append(("continuation-token", continuationToken)) }
        let r = try await send("GET", key: nil, query: q)
        let parsed = ListParser.parse(r.data)
        return (parsed.objects, parsed.truncated ? parsed.nextToken : nil)
    }

    /// Every object under a prefix (follows continuation tokens).
    public func listAll(prefix: String) async throws -> [S3Object] {
        var all: [S3Object] = []
        var token: String?
        repeat {
            let page = try await list(prefix: prefix, continuationToken: token)
            all += page.objects
            token = page.nextToken
        } while token != nil
        return all
    }

    /// Deletes every object under `prefix` (list + parallel deletes). Returns the number deleted.
    @discardableResult
    public func deletePrefix(_ prefix: String) async throws -> Int {
        guard !prefix.isEmpty else { throw ShareError(status: 0, message: "Refusing to delete an empty prefix (the whole bucket).") }
        var count = 0
        while true {
            let page = try await list(prefix: prefix)
            if page.objects.isEmpty { break }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for o in page.objects { group.addTask { try await self.delete(o.key) } }
                try await group.waitForAll()
            }
            count += page.objects.count
            if page.nextToken == nil { break }
        }
        return count
    }

    // MARK: Multipart

    public func createMultipartUpload(_ key: String, contentType: String, cacheControl: String? = nil) async throws -> String {
        var headers = ["content-type": contentType]
        if let cacheControl { headers["cache-control"] = cacheControl }
        let r = try await send("POST", key: key, query: [("uploads", "")], headers: headers, body: Data())
        guard let id = XMLValue.first("UploadId", in: r.data) else {
            throw ShareError(status: r.response.statusCode, message: "The storage service did not return an upload ID.", key: key)
        }
        return id
    }

    /// Uploads one part; returns its ETag.
    public func uploadPart(_ key: String, uploadID: String, partNumber: Int, data: Data) async throws -> String {
        let r = try await send("PUT", key: key, query: [("partNumber", String(partNumber)), ("uploadId", uploadID)], body: data)
        guard let etag = r.response.value(forHTTPHeaderField: "ETag") else {
            throw ShareError(status: r.response.statusCode, message: "The storage service did not return an ETag for part \(partNumber).", key: key)
        }
        return etag
    }

    public func completeMultipartUpload(_ key: String, uploadID: String, parts: [(number: Int, etag: String)]) async throws {
        var xml = "<CompleteMultipartUpload xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
        for p in parts.sorted(by: { $0.number < $1.number }) {
            xml += "<Part><PartNumber>\(p.number)</PartNumber><ETag>\(XMLValue.escape(p.etag))</ETag></Part>"
        }
        xml += "</CompleteMultipartUpload>"
        let r = try await send("POST", key: key, query: [("uploadId", uploadID)],
                               headers: ["content-type": "application/xml"], body: Data(xml.utf8))
        // S3 can answer 200 with an <Error> body when completion fails late.
        if let code = XMLValue.first("Code", in: r.data), XMLValue.first("Error", in: r.data) != nil || r.data.starts(with: Data("<Error".utf8)) {
            throw S3Client.describe(status: 500, code: code, serverMessage: XMLValue.first("Message", in: r.data), key: key, bucket: destination.bucket, endpoint: endpoint)
        }
    }

    public func abortMultipartUpload(_ key: String, uploadID: String) async throws {
        do { _ = try await send("DELETE", key: key, query: [("uploadId", uploadID)]) } catch let e as ShareError where e.status == 404 {}
    }

    /// Uploads a file: one PUT when small, otherwise a parallel multipart upload with fixed-size parts.
    /// `progress` receives 0...1 by bytes uploaded.
    public func uploadFile(_ key: String, file: URL, contentType: String, cacheControl: String? = nil,
                           partSize: Int = 8 << 20, multipartThreshold: Int = 16 << 20,
                           progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        if size <= multipartThreshold {
            progress(0)
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            try await put(key, data: data, contentType: contentType, cacheControl: cacheControl)
            progress(1)
            return
        }
        // R2: every part except the last must be the same size and at least 5 MiB; at most 10,000 parts.
        var chosen = max(partSize, 5 << 20)
        while (size + chosen - 1) / chosen > 10_000 { chosen *= 2 }
        let part = chosen
        let partCount = (size + part - 1) / part
        let uploadID = try await createMultipartUpload(key, contentType: contentType, cacheControl: cacheControl)
        let counter = ProgressCounter(total: Int64(size), report: progress)
        progress(0)
        do {
            let etags = try await withThrowingTaskGroup(of: (Int, String).self) { group in
                var results: [(number: Int, etag: String)] = []
                var next = 1
                // Keep at most 4 parts in memory at once.
                while next <= min(4, partCount) {
                    let n = next
                    next += 1
                    group.addTask { try await self.uploadChunk(key, uploadID: uploadID, file: file, part: n, partSize: part, counter: counter) }
                }
                while let r = try await group.next() {
                    results.append((r.0, r.1))
                    if next <= partCount {
                        let n = next
                        next += 1
                        group.addTask { try await self.uploadChunk(key, uploadID: uploadID, file: file, part: n, partSize: part, counter: counter) }
                    }
                }
                return results
            }
            try await completeMultipartUpload(key, uploadID: uploadID, parts: etags)
            progress(1)
        } catch {
            try? await abortMultipartUpload(key, uploadID: uploadID)
            throw error
        }
    }

    private func uploadChunk(_ key: String, uploadID: String, file: URL, part n: Int, partSize: Int,
                             counter: ProgressCounter) async throws -> (Int, String) {
        let data = try Self.readChunk(file, offset: (n - 1) * partSize, length: partSize)
        let etag = try await uploadPart(key, uploadID: uploadID, partNumber: n, data: data)
        await counter.add(Int64(data.count))
        return (n, etag)
    }

    static func readChunk(_ url: URL, offset: Int, length: Int) throws -> Data {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(offset))
        return try h.read(upToCount: length) ?? Data()
    }

    // MARK: Transport

    struct Response: Sendable {
        var data: Data
        var response: HTTPURLResponse
    }

    /// Path ("/bucket/key", under the endpoint's base path) before encoding.
    func path(for key: String?) -> String {
        guard let key else { return "\(basePath)/\(destination.bucket)" }
        return "\(basePath)/\(destination.bucket)/\(key)"
    }

    func send(_ method: String, key: String?, query: [(String, String)] = [],
              headers: [String: String] = [:], body: Data? = nil) async throws -> Response {
        let canonicalURI = SigV4Signer.encodePath(path(for: key))
        let qs = query.map { $0.1.isEmpty && $0.0 == "uploads" ? "uploads=" : "\(SigV4Signer.uriEncode($0.0))=\(SigV4Signer.uriEncode($0.1))" }
            .joined(separator: "&")
        guard let url = URL(string: origin + canonicalURI + (qs.isEmpty ? "" : "?" + qs)), let host = url.host else {
            throw ShareError(status: 0, message: "The endpoint \"\(destination.endpoint)\" is not a valid URL.")
        }
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host
        let payloadHash = body.map { SigV4Signer.sha256Hex($0) } ?? SigV4Signer.emptyPayloadHash

        var attempt = 0
        var clockFixed = false
        var keysRenewed = false
        // Cloud keys are per share: a listing is scoped by its prefix.
        let scope = key ?? query.first(where: { $0.0 == "prefix" })?.1 ?? ""
        while true {
            attempt += 1
            try Task.checkCancellation()
            let signer = try await cloud?.signer(for: scope) ?? self.signer
            // One timestamp for both the header and the signature (two Date() calls could straddle
            // a second boundary and fail with SignatureDoesNotMatch).
            let date = now
            var signed = headers
            signed["host"] = hostHeader
            signed["x-amz-date"] = SigV4Signer.amzDate(date)
            signed["x-amz-content-sha256"] = payloadHash
            if let token = signer.sessionToken { signed["x-amz-security-token"] = token }
            let sig = signer.sign(method: method, canonicalURI: canonicalURI, query: query,
                                  headers: signed, payloadHash: payloadHash, date: date)
            var req = URLRequest(url: url)
            req.httpMethod = method
            for (k, v) in signed where k != "host" { req.setValue(v, forHTTPHeaderField: k) }
            req.setValue(sig.authorization, forHTTPHeaderField: "Authorization")

            do {
                await gate.acquire()
                let result: (Data, URLResponse)
                do {
                    if let body, method == "PUT" || method == "POST" {
                        result = try await session.upload(for: req, from: body)
                    } else {
                        result = try await session.data(for: req)
                    }
                } catch {
                    await gate.release()
                    throw error
                }
                await gate.release()
                guard let http = result.1 as? HTTPURLResponse else {
                    throw ShareError(status: 0, message: "Unexpected response from the storage service.", key: key)
                }
                if (200..<300).contains(http.statusCode) {
                    if let cloud, let key, method == "PUT", key.hasSuffix("/meta.json") { cloud.didUpdate(key) }
                    return Response(data: result.0, response: http)
                }
                if let cloud, http.statusCode == 403, !keysRenewed {
                    // Keys revoked or expired early: fetch fresh ones once.
                    keysRenewed = true
                    cloud.invalidate(scope)
                    attempt -= 1
                    continue
                }
                let err = Self.describe(status: http.statusCode, code: XMLValue.first("Code", in: result.0),
                                        serverMessage: XMLValue.first("Message", in: result.0),
                                        key: key, bucket: destination.bucket, endpoint: endpoint)
                if err.code == "RequestTimeTooSkewed", !clockFixed,
                   let server = http.value(forHTTPHeaderField: "Date").flatMap(Self.parseHTTPDate) {
                    // Sign with the server's clock from now on and retry right away.
                    clockFixed = true
                    clockOffset.withLock { $0 = server.timeIntervalSince(Date()) }
                    attempt -= 1
                    continue
                }
                if err.isTransient && attempt < maxAttempts {
                    try await backoff(attempt, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
                    continue
                }
                throw err
            } catch let e as ShareError {
                throw e
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as URLError {
                if e.code == .cancelled, Task.isCancelled { throw CancellationError() }
                let err = Self.describe(urlError: e, endpoint: endpoint, key: key)
                if attempt < maxAttempts && Self.isRetryable(e) {
                    try await backoff(attempt, retryAfter: nil)
                    continue
                }
                throw err
            }
        }
    }

    /// Parses an RFC 7231 IMF-fixdate ("Sun, 06 Nov 1994 08:49:37 GMT").
    static func parseHTTPDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s)
    }

    func backoff(_ attempt: Int, retryAfter: String?) async throws {
        var delay = baseDelay * pow(2, Double(attempt - 1))
        if let s = retryAfter, let secs = Double(s) { delay = max(delay, min(secs, 30)) }
        delay = min(delay, 20) * Double.random(in: 0.75...1.25)
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    static func isRetryable(_ e: URLError) -> Bool {
        switch e.code {
        case .badURL, .unsupportedURL, .cancelled, .userAuthenticationRequired, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
             .clientCertificateRejected, .appTransportSecurityRequiresSecureConnection:
            return false
        default:
            return true
        }
    }

    static func describe(urlError e: URLError, endpoint: String, key: String?) -> ShareError {
        let msg: String
        switch e.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            msg = "No internet connection. Uploads will resume when you're back online."
        case .cannotFindHost, .dnsLookupFailed:
            msg = "Can't find \(URL(string: endpoint)?.host ?? endpoint). Check the endpoint URL."
        case .cannotConnectToHost:
            msg = "Can't connect to \(endpoint). Check the endpoint URL."
        case .timedOut:
            msg = "The storage service took too long to answer."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot:
            msg = "Secure connection to \(endpoint) failed."
        case .appTransportSecurityRequiresSecureConnection:
            msg = "The endpoint must use https://."
        default:
            msg = "Network error talking to the storage service: \(e.localizedDescription)"
        }
        return ShareError(status: 0, code: "URLError\(e.code.rawValue)", message: msg, key: key)
    }

    static func describe(status: Int, code: String?, serverMessage: String?, key: String?, bucket: String, endpoint: String) -> ShareError {
        let msg: String
        switch (status, code) {
        case (_, "SignatureDoesNotMatch"):
            msg = "The secret access key doesn't match the access key ID. Check the secret."
        case (_, "InvalidAccessKeyId"):
            msg = "The access key ID isn't recognised. Check the access key."
        case (_, "RequestTimeTooSkewed"):
            msg = "Your Mac's clock is off. Turn on \"Set time and date automatically\" in System Settings."
        case (301, _), (_, "PermanentRedirect"), (_, "AuthorizationHeaderMalformed"):
            msg = "The endpoint doesn't match the bucket's region. For AWS S3 use https://s3.<region>.amazonaws.com and set the region."
        case (_, "NoSuchBucket"):
            msg = "Bucket \"\(bucket)\" doesn't exist at \(endpoint). Check the bucket name and endpoint."
        case (_, "AccessDenied"), (403, _):
            msg = "Access denied to bucket \"\(bucket)\". Check the access key and that it can read and write this bucket."
        case (401, _):
            msg = "The storage service rejected the credentials. Check the access key and secret."
        case (404, _):
            msg = "Not found\(key.map { ": \($0)" } ?? "")."
        case (_, "EntityTooLarge"), (413, _):
            msg = "The file is too large for a single upload."
        case (429, _), (_, "SlowDown"):
            msg = "The storage service is rate-limiting uploads. Retrying."
        case (500..., _):
            msg = "The storage service had an error (HTTP \(status)). Try again shortly."
        default:
            msg = "Storage request failed (HTTP \(status)\(code.map { ", \($0)" } ?? ""))\(serverMessage.map { ": \($0)" } ?? "")."
        }
        return ShareError(status: status, code: code, message: msg, key: key)
    }
}

// MARK: - Support

/// A counting semaphore for async code: at most `limit` holders at once, FIFO waiters.
actor AsyncGate {
    private let limit: Int
    private var inUse = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func acquire() async {
        if inUse < limit { inUse += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { inUse -= 1 } else { waiters.removeFirst().resume() }
    }
}

actor ProgressCounter {
    let total: Int64
    var done: Int64 = 0
    let report: @Sendable (Double) -> Void
    init(total: Int64, report: @escaping @Sendable (Double) -> Void) { self.total = max(1, total); self.report = report }
    func add(_ n: Int64) { done += n; report(min(1, Double(done) / Double(total))) }
}

/// Tiny tag extraction for S3's flat XML responses (no namespaces needed).
enum XMLValue {
    static func first(_ tag: String, in data: Data) -> String? {
        all(tag, in: String(decoding: data, as: UTF8.self)).first
    }

    static func all(_ tag: String, in s: String) -> [String] {
        var out: [String] = []
        var rest = s[...]
        let open = "<\(tag)>", close = "</\(tag)>"
        while let a = rest.range(of: open), let b = rest.range(of: close, range: a.upperBound..<rest.endIndex) {
            out.append(unescape(String(rest[a.upperBound..<b.lowerBound])))
            rest = rest[b.upperBound...]
        }
        return out
    }

    static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

enum ListParser {
    static func parse(_ data: Data) -> (objects: [S3Object], truncated: Bool, nextToken: String?) {
        let s = String(decoding: data, as: UTF8.self)
        let objects = XMLValue.all("Contents", in: s).compactMap { c -> S3Object? in
            guard let key = XMLValue.all("Key", in: c).first else { return nil }
            return S3Object(key: key, size: Int64(XMLValue.all("Size", in: c).first ?? "") ?? 0,
                            etag: XMLValue.all("ETag", in: c).first, contentType: nil, cacheControl: nil)
        }
        let truncated = XMLValue.all("IsTruncated", in: s).first == "true"
        return (objects, truncated, XMLValue.all("NextContinuationToken", in: s).first)
    }
}
