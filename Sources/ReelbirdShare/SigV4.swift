import CryptoKit
import Foundation

/// AWS Signature Version 4 request signing (header-based), as used by S3, R2, B2 and MinIO.
///
/// Pure and deterministic: given the same inputs it produces the same `Authorization` value,
/// which is what the published AWS test vectors check.
public struct SigV4Signer: Sendable, CustomStringConvertible, CustomReflectable {
    public var accessKeyID: String
    /// Never printed: `description` and `dump`/`Mirror` redact it.
    public var secretAccessKey: String
    /// "auto" for Cloudflare R2.
    public var region: String
    public var service: String
    /// Session token of temporary credentials (sent and signed as `x-amz-security-token`). Never printed.
    public var sessionToken: String?

    /// SHA-256 of the empty string, the payload hash of every body-less request.
    public static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    /// Payload hash value that tells S3 the body is not signed (TLS still protects it).
    public static let unsignedPayload = "UNSIGNED-PAYLOAD"

    public init(accessKeyID: String, secretAccessKey: String, region: String, service: String = "s3", sessionToken: String? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.region = region
        self.service = service
        self.sessionToken = sessionToken
    }

    public var description: String { "SigV4Signer(accessKeyID: \(accessKeyID), region: \(region), service: \(service), secretAccessKey: <redacted>)" }
    public var customMirror: Mirror {
        Mirror(self, children: ["accessKeyID": accessKeyID, "secretAccessKey": "<redacted>", "region": region, "service": service,
                                "sessionToken": sessionToken == nil ? "nil" : "<redacted>"])
    }

    public struct Signature: Sendable {
        public var authorization: String
        public var canonicalRequest: String
        public var stringToSign: String
        public var signedHeaders: String
    }

    /// Signs a request.
    /// - Parameters:
    ///   - canonicalURI: the already URI-encoded absolute path (see `encodePath`), e.g. "/bucket/r/a%20b".
    ///   - query: decoded query items; encoded and sorted here.
    ///   - headers: every header to sign; must include `host` and `x-amz-date`. Names are case-insensitive.
    public func sign(method: String, canonicalURI: String, query: [(String, String)] = [],
                     headers: [String: String], payloadHash: String, date: Date) -> Signature {
        let amzDate = Self.amzDate(date)
        let day = String(amzDate.prefix(8))

        var canon: [(String, String)] = []
        for (k, v) in headers {
            canon.append((k.lowercased(), Self.trimHeaderValue(v)))
        }
        canon.sort { $0.0 < $1.0 }
        let canonicalHeaders = canon.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = canon.map(\.0).joined(separator: ";")

        let canonicalRequest = [
            method.uppercased(),
            canonicalURI.isEmpty ? "/" : canonicalURI,
            Self.canonicalQuery(query),
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Self.sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let kDate = Self.hmac(key: Data("AWS4\(secretAccessKey)".utf8), day)
        let kRegion = Self.hmac(key: kDate, region)
        let kService = Self.hmac(key: kRegion, service)
        let kSigning = Self.hmac(key: kService, "aws4_request")
        let signature = Self.hex(Self.hmac(key: kSigning, stringToSign))

        let auth = "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return Signature(authorization: auth, canonicalRequest: canonicalRequest,
                         stringToSign: stringToSign, signedHeaders: signedHeaders)
    }

    // MARK: Encoding helpers

    private static let unreserved: Set<UInt8> = {
        var s = Set<UInt8>()
        for c in UInt8(ascii: "A")...UInt8(ascii: "Z") { s.insert(c) }
        for c in UInt8(ascii: "a")...UInt8(ascii: "z") { s.insert(c) }
        for c in UInt8(ascii: "0")...UInt8(ascii: "9") { s.insert(c) }
        for c in "-._~".utf8 { s.insert(c) }
        return s
    }()

    /// RFC 3986 percent-encoding of everything except unreserved characters (and `/` unless `encodeSlash`).
    public static func uriEncode(_ s: String, encodeSlash: Bool = true) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for b in s.utf8 {
            if unreserved.contains(b) || (!encodeSlash && b == UInt8(ascii: "/")) {
                out.unicodeScalars.append(Unicode.Scalar(b))
            } else {
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    /// Encodes an S3 object path (bucket + key) once, keeping slashes. S3 does not normalise paths.
    public static func encodePath(_ path: String) -> String {
        let p = path.hasPrefix("/") ? path : "/" + path
        return uriEncode(p, encodeSlash: false)
    }

    public static func canonicalQuery(_ items: [(String, String)]) -> String {
        let encoded: [(key: String, value: String)] = items.map { (uriEncode($0.0), uriEncode($0.1)) }
        let sorted = encoded.sorted { a, b in a.key == b.key ? a.value < b.value : a.key < b.key }
        return sorted.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }

    static func trimHeaderValue(_ v: String) -> String {
        v.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
    }

    public static func amzDate(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let parts: [Int] = [c.year ?? 1970, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0]
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", parts[0], parts[1], parts[2], parts[3], parts[4], parts[5])
    }

    public static func sha256Hex(_ data: Data) -> String { hex(Data(SHA256.hash(data: data))) }

    static func hmac(key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    static func hex(_ d: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(d.count * 2)
        for b in d { out.append(digits[Int(b >> 4)]); out.append(digits[Int(b & 0x0f)]) }
        return String(decoding: out, as: UTF8.self)
    }
}
