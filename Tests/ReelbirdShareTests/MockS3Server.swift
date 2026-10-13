import CryptoKit
import Foundation
import Network
import ReelbirdCore
@testable import ReelbirdShare

/// A local S3-compatible server for tests: verifies SigV4 on every authenticated request,
/// stores objects in memory, supports ListObjectsV2 and multipart uploads, and serves
/// objects publicly (with Range) like an r2.dev bucket URL. Supports fault injection.
final class MockS3Server: @unchecked Sendable {
    struct Object { var data: Data; var contentType: String; var cacheControl: String? }
    struct LogEntry { var method: String; var key: String; var query: String; var status: Int; var authenticated: Bool }

    let bucket: String
    let accessKey = "TESTKEY"
    let secret: String
    private let queue = DispatchQueue(label: "mock-s3")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    // State (queue-confined).
    private var objects: [String: Object] = [:]
    private var uploads: [String: (key: String, contentType: String, cacheControl: String?, parts: [Int: Data])] = [:]
    private var log: [LogEntry] = []
    private var history: [String: [Data]] = [:]
    private var failures: [String: (count: Int, status: Int)] = [:]
    private var delays: [String: Double] = [:]
    private var offline = false
    var listPageSize = 1000
    /// Server clock minus real time; requests signed more than 15 minutes off get RequestTimeTooSkewed.
    var clockSkew: Double = 0
    /// Path the server is mounted under (a reverse proxy in front of MinIO), e.g. "/minio".
    var pathPrefix = ""
    /// Requests rejected as skewed.
    private(set) var skewRejections = 0
    /// Delay applied to every response (a slow or congested network).
    var globalDelay: Double = 0

    init(bucket: String = "test-bucket", secret: String = "test-secret-\(UUID().uuidString)") {
        self.bucket = bucket
        self.secret = secret
    }

    func start(port fixed: UInt16 = 0) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: fixed) ?? .any)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let p = l.port?.rawValue, p != 0 else { throw ShareError(status: 0, message: "mock server failed to start") }
        port = p
        listener = l
    }

    func stop() { listener?.cancel() }

    var endpoint: String { "http://127.0.0.1:\(port)" }
    var publicBase: String { "http://127.0.0.1:\(port)/\(bucket)" }

    func destination(prefix: String = "r") -> ShareDestination {
        ShareDestination(endpoint: endpoint, bucket: bucket, region: "auto", accessKeyID: accessKey,
                         publicBaseURL: publicBase, prefix: prefix)
    }

    // MARK: Inspection / fault injection

    func object(_ key: String) -> Object? { queue.sync { objects[key] } }
    func keys(prefix: String = "") -> [String] { queue.sync { objects.keys.filter { $0.hasPrefix(prefix) }.sorted() } }
    func requests() -> [LogEntry] { queue.sync { log } }
    /// Every body PUT to `key`, in arrival order.
    func versions(_ key: String) -> [Data] { queue.sync { history[key] ?? [] } }
    func clearLog() { queue.sync { log.removeAll() } }
    func put(_ key: String, _ data: Data, contentType: String = "application/octet-stream") {
        queue.sync { objects[key] = Object(data: data, contentType: contentType, cacheControl: nil) }
    }
    /// The next `count` authenticated requests for `key` fail with `status`.
    func fail(_ key: String, count: Int, status: Int = 503) { queue.sync { failures[key] = (count, status) } }
    /// Responses for `key` are delayed by `seconds`.
    func delay(_ key: String, seconds: Double) { queue.sync { delays[key] = seconds } }
    /// Every authenticated request fails with 503 (and is not stored) while true.
    func setOffline(_ v: Bool) { queue.sync { offline = v } }
    var openMultipartUploads: Int { queue.sync { uploads.count } }

    // MARK: Connections

    private final class Conn: @unchecked Sendable {
        let c: NWConnection
        var buffer = Data()
        init(_ c: NWConnection) { self.c = c }
    }

    private func accept(_ c: NWConnection) {
        let conn = Conn(c)
        c.start(queue: queue)
        receive(conn)
    }

    private func receive(_ conn: Conn) {
        conn.c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { conn.buffer.append(data) }
            self.drain(conn)
            if done || error != nil { conn.c.cancel(); return }
            self.receive(conn)
        }
    }

    private struct Request {
        var method: String
        var rawPath: String
        var rawQuery: String
        var headers: [String: String]
        var body: Data
    }

    private func drain(_ conn: Conn) {
        while let r = parse(&conn.buffer) {
            let (status, headers, body) = handle(r)
            let delay = max(globalDelay, delays[key(from: r.rawPath) ?? ""] ?? 0)
            var head = "HTTP/1.1 \(status) \(reason(status))\r\n"
            var h = headers
            h["Content-Length"] = String(body.count)
            h["Connection"] = "keep-alive"
            h["Access-Control-Allow-Origin"] = "*"
            h["Date"] = Self.httpDate(Date().addingTimeInterval(clockSkew))
            for (k, v) in h { head += "\(k): \(v)\r\n" }
            head += "\r\n"
            var out = Data(head.utf8)
            if r.method != "HEAD" { out.append(body) }
            let payload = out
            let send: @Sendable () -> Void = { conn.c.send(content: payload, completion: .contentProcessed { _ in }) }
            if delay > 0 { queue.asyncAfter(deadline: .now() + delay, execute: send) } else { send() }
        }
    }

    private func parse(_ buf: inout Data) -> Request? {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headText = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { buf.removeAll(); return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard buf.count - (bodyStart - buf.startIndex) >= length else { return nil }
        let body = Data(buf[bodyStart..<(bodyStart + length)])
        buf = Data(buf[(bodyStart + length)...])
        let target = String(first[1])
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        return Request(method: String(first[0]), rawPath: String(parts[0]), rawQuery: parts.count > 1 ? String(parts[1]) : "",
                       headers: headers, body: body)
    }

    static func httpDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.string(from: d)
    }

    /// The request path with the mount prefix removed (nil if it isn't under the prefix).
    private func routed(_ rawPath: String) -> String? {
        guard !pathPrefix.isEmpty else { return rawPath }
        guard rawPath.hasPrefix(pathPrefix + "/") else { return nil }
        return String(rawPath.dropFirst(pathPrefix.count))
    }

    private func key(from rawPath: String) -> String? {
        guard let rawPath = routed(rawPath) else { return nil }
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        let prefix = "/\(bucket)/"
        guard decoded.hasPrefix(prefix) else { return nil }
        return String(decoded.dropFirst(prefix.count))
    }

    private func queryItems(_ raw: String) -> [(String, String)] {
        guard !raw.isEmpty else { return [] }
        return raw.split(separator: "&").map { pair in
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let v = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            return (k, v)
        }
    }

    private func xmlError(_ status: Int, _ code: String, _ message: String = "") -> (Int, [String: String], Data) {
        (status, ["Content-Type": "application/xml"],
         Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Error><Code>\(code)</Code><Message>\(message)</Message></Error>".utf8))
    }

    private func verify(_ r: Request) -> String? {
        guard let auth = r.headers["authorization"] else { return "missing" }
        func field(_ name: String) -> String? {
            guard let range = auth.range(of: name + "=") else { return nil }
            let rest = auth[range.upperBound...]
            return String(rest.prefix { $0 != "," && $0 != " " })
        }
        guard let cred = field("Credential"), let signed = field("SignedHeaders"), let signature = field("Signature"),
              let amzDate = r.headers["x-amz-date"], let payload = r.headers["x-amz-content-sha256"] else { return "malformed" }
        let credParts = cred.split(separator: "/")
        guard credParts.first.map(String.init) == accessKey else { return "InvalidAccessKeyId" }
        if payload != SigV4Signer.unsignedPayload && payload != SigV4Signer.sha256Hex(r.body) { return "XAmzContentSHA256Mismatch" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        guard let date = f.date(from: amzDate) else { return "malformed date" }
        if abs(date.timeIntervalSince(Date().addingTimeInterval(clockSkew))) > 900 { skewRejections += 1; return "RequestTimeTooSkewed" }
        var headers: [String: String] = [:]
        for name in signed.split(separator: ";") { headers[String(name)] = r.headers[String(name)] ?? "" }
        let signer = SigV4Signer(accessKeyID: accessKey, secretAccessKey: secret, region: String(credParts[2]))
        let expected = signer.sign(method: r.method, canonicalURI: r.rawPath, query: queryItems(r.rawQuery),
                                   headers: headers, payloadHash: payload, date: date)
        guard expected.authorization.hasSuffix("Signature=\(signature)") else { return "SignatureDoesNotMatch" }
        guard signed.contains("host") && signed.contains("x-amz-date") else { return "headers" }
        return nil
    }

    private func handle(_ r: Request) -> (Int, [String: String], Data) {
        let key = key(from: r.rawPath)
        let q = Dictionary(queryItems(r.rawQuery), uniquingKeysWith: { a, _ in a })
        let authed = r.headers["authorization"] != nil
        let result: (Int, [String: String], Data) = {
            if authed {
                if let problem = verify(r) {
                    let code = ["InvalidAccessKeyId", "RequestTimeTooSkewed"].contains(problem) ? problem : "SignatureDoesNotMatch"
                    return xmlError(403, code, problem)
                }
                if offline { return xmlError(503, "ServiceUnavailable") }
                if let k = key, let f = failures[k], f.count > 0 {
                    failures[k] = (f.count - 1, f.status)
                    return xmlError(f.status, "InternalError")
                }
            }
            guard let path = routed(r.rawPath), path == "/\(bucket)" || path.hasPrefix("/\(bucket)/") else { return xmlError(404, "NoSuchBucket") }

            switch (r.method, key) {
            case ("GET", nil) where authed, ("GET", "") where authed:
                return list(prefix: q["prefix"] ?? "", token: q["continuation-token"], max: Int(q["max-keys"] ?? "") ?? 1000)
            case ("PUT", let k?) where authed:
                if let id = q["uploadId"], let n = Int(q["partNumber"] ?? "") {
                    guard uploads[id] != nil else { return xmlError(404, "NoSuchUpload") }
                    uploads[id]?.parts[n] = r.body
                    return (200, ["ETag": "\"\(SigV4Signer.sha256Hex(r.body).prefix(32))\""], Data())
                }
                objects[k] = Object(data: r.body, contentType: r.headers["content-type"] ?? "binary/octet-stream",
                                    cacheControl: r.headers["cache-control"])
                history[k, default: []].append(r.body)
                return (200, ["ETag": "\"\(SigV4Signer.sha256Hex(r.body).prefix(32))\""], Data())
            case ("POST", let k?) where authed:
                if q["uploads"] != nil {
                    let id = UUID().uuidString
                    uploads[id] = (k, r.headers["content-type"] ?? "binary/octet-stream", r.headers["cache-control"], [:])
                    return (200, ["Content-Type": "application/xml"],
                            Data("<InitiateMultipartUploadResult><Bucket>\(bucket)</Bucket><Key>\(k)</Key><UploadId>\(id)</UploadId></InitiateMultipartUploadResult>".utf8))
                }
                if let id = q["uploadId"], let u = uploads[id] {
                    let numbers = XMLValue.all("PartNumber", in: String(decoding: r.body, as: UTF8.self)).compactMap(Int.init)
                    var data = Data()
                    for n in numbers {
                        guard let p = u.parts[n] else { return xmlError(400, "InvalidPart") }
                        data.append(p)
                    }
                    objects[u.key] = Object(data: data, contentType: u.contentType, cacheControl: u.cacheControl)
                    uploads[id] = nil
                    return (200, ["Content-Type": "application/xml"], Data("<CompleteMultipartUploadResult><Key>\(u.key)</Key></CompleteMultipartUploadResult>".utf8))
                }
                return xmlError(404, "NoSuchUpload")
            case ("DELETE", let k?) where authed:
                if let id = q["uploadId"] { uploads[id] = nil; return (204, [:], Data()) }
                objects[k] = nil
                return (204, [:], Data())
            case ("GET", let k?), ("HEAD", let k?):
                guard let o = objects[k] else { return xmlError(404, "NoSuchKey") }
                var h = ["Content-Type": o.contentType, "Accept-Ranges": "bytes", "ETag": "\"x\""]
                if let cc = o.cacheControl { h["Cache-Control"] = cc }
                if let range = r.headers["range"], range.hasPrefix("bytes=") {
                    let spec = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                    let total = o.data.count
                    var start = Int(spec.first ?? "") ?? 0
                    var end = spec.count > 1 ? (Int(spec[1]) ?? total - 1) : total - 1
                    if spec.first?.isEmpty == true, let suffix = Int(spec.count > 1 ? spec[1] : "") { start = max(0, total - suffix); end = total - 1 }
                    end = min(end, total - 1)
                    guard start <= end else { return (416, ["Content-Range": "bytes */\(total)"], Data()) }
                    h["Content-Range"] = "bytes \(start)-\(end)/\(total)"
                    return (206, h, o.data.subdata(in: start..<(end + 1)))
                }
                return (200, h, o.data)
            default:
                return xmlError(authed ? 405 : 403, authed ? "MethodNotAllowed" : "AccessDenied")
            }
        }()
        log.append(LogEntry(method: r.method, key: key ?? "", query: r.rawQuery, status: result.0, authenticated: authed))
        return result
    }

    private func list(prefix: String, token: String?, max: Int) -> (Int, [String: String], Data) {
        let all = objects.keys.filter { $0.hasPrefix(prefix) }.sorted()
        let after = token.flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }
        let rest = after.map { a in all.filter { $0 > a } } ?? all
        let page = Array(rest.prefix(min(max, listPageSize)))
        let truncated = rest.count > page.count
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult><Name>\(bucket)</Name><Prefix>\(XMLValue.escape(prefix))</Prefix><KeyCount>\(page.count)</KeyCount><IsTruncated>\(truncated)</IsTruncated>"
        for k in page { xml += "<Contents><Key>\(XMLValue.escape(k))</Key><Size>\(objects[k]?.data.count ?? 0)</Size></Contents>" }
        if truncated, let last = page.last { xml += "<NextContinuationToken>\(Data(last.utf8).base64EncodedString())</NextContinuationToken>" }
        xml += "</ListBucketResult>"
        return (200, ["Content-Type": "application/xml"], Data(xml.utf8))
    }

    private func reason(_ s: Int) -> String {
        switch s {
        case 200: "OK"
        case 204: "No Content"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 416: "Range Not Satisfiable"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }
}
