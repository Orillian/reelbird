import Foundation
import Testing
@testable import ReelbirdShare

/// Vectors from the AWS SigV4 test suite (awslabs/aws-c-auth tests/aws-signing-test-suite/v4)
/// and the worked examples in the Amazon S3 API reference ("Signature Calculations for the
/// Authorization Header").
@Suite struct SigV4Tests {
    static let suiteSigner = SigV4Signer(accessKeyID: "AKIDEXAMPLE",
                                         secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
                                         region: "us-east-1", service: "service")
    static let suiteDate = Date(timeIntervalSince1970: 1_440_938_160) // 2015-08-30T12:36:00Z

    struct Vector: Sendable, CustomTestStringConvertible {
        var name: String
        var method: String
        var path: String
        var query: [(String, String)]
        var headers: [String: String]
        var signature: String
        var canonical: String?
        var testDescription: String { name }
    }

    static let vectors: [Vector] = [
        Vector(name: "get-vanilla", method: "GET", path: "/", query: [], headers: [:],
               signature: "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31",
               canonical: "GET\n/\n\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        Vector(name: "post-vanilla", method: "POST", path: "/", query: [], headers: [:],
               signature: "5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b"),
        Vector(name: "get-vanilla-query-order-key-case", method: "GET", path: "/",
               query: [("Param2", "value2"), ("Param1", "value1")], headers: [:],
               signature: "b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500"),
        Vector(name: "get-unreserved", method: "GET", path: "/-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz",
               query: [], headers: [:],
               signature: "07ef7494c76fa4850883e2b006601f940f8a34d404d0cfa977f52a65bbf5f24f"),
        Vector(name: "get-vanilla-query-unreserved", method: "GET", path: "/",
               query: [("-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz",
                        "-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")], headers: [:],
               signature: "9c3e54bfcdf0b19771a7f523ee5669cdf59bc7cc0884027167c21bb143a40197"),
        Vector(name: "get-utf8", method: "GET", path: "/ሴ", query: [], headers: [:],
               signature: "8318018e0b0f223aa2bbf98705b62bb787dc9c0e678f255a891fd03141be5d85"),
        Vector(name: "get-vanilla-utf8-query", method: "GET", path: "/", query: [("ሴ", "bar")], headers: [:],
               signature: "2cdec8eed098649ff3a119c94853b13c643bcf08f8b0a1d91e12c9027818dd04"),
        Vector(name: "get-space-unnormalized", method: "GET", path: "/example space/", query: [], headers: [:],
               signature: "652487583200325589f1fba4c7e578f72c47cb61beeca81406b39ddec1366741"),
        Vector(name: "post-header-key-sort", method: "POST", path: "/", query: [], headers: ["My-Header1": "value1"],
               signature: "c5410059b04c1ee005303aed430f6e6645f61f4dc9e1461ec8f8916fdf18852c"),
    ]

    @Test(arguments: vectors)
    func awsTestSuite(_ v: Vector) {
        var headers = v.headers
        headers["Host"] = "example.amazonaws.com"
        headers["X-Amz-Date"] = "20150830T123600Z"
        let sig = Self.suiteSigner.sign(method: v.method, canonicalURI: SigV4Signer.encodePath(v.path), query: v.query,
                                        headers: headers, payloadHash: SigV4Signer.emptyPayloadHash, date: Self.suiteDate)
        if let canonical = v.canonical { #expect(sig.canonicalRequest == canonical) }
        #expect(sig.authorization.hasSuffix("Signature=\(v.signature)"), "\(v.name): \(sig.authorization)")
    }

    static let s3Signer = SigV4Signer(accessKeyID: "AKIAIOSFODNN7EXAMPLE",
                                      secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region: "us-east-1")
    static let s3Date = Date(timeIntervalSince1970: 1_369_353_600) // 2013-05-24T00:00:00Z

    @Test func s3GetObjectExample() {
        let sig = Self.s3Signer.sign(method: "GET", canonicalURI: "/test.txt", headers: [
            "Host": "examplebucket.s3.amazonaws.com", "Range": "bytes=0-9",
            "x-amz-content-sha256": SigV4Signer.emptyPayloadHash, "x-amz-date": "20130524T000000Z",
        ], payloadHash: SigV4Signer.emptyPayloadHash, date: Self.s3Date)
        #expect(sig.signedHeaders == "host;range;x-amz-content-sha256;x-amz-date")
        #expect(sig.authorization.hasSuffix("Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"))
    }

    @Test func s3PutObjectExample() {
        let body = Data("Welcome to Amazon S3.".utf8)
        let hash = SigV4Signer.sha256Hex(body)
        #expect(hash == "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")
        let sig = Self.s3Signer.sign(method: "PUT", canonicalURI: SigV4Signer.encodePath("/test$file.text"), headers: [
            "Host": "examplebucket.s3.amazonaws.com", "Date": "Fri, 24 May 2013 00:00:00 GMT",
            "x-amz-storage-class": "REDUCED_REDUNDANCY", "x-amz-content-sha256": hash, "x-amz-date": "20130524T000000Z",
        ], payloadHash: hash, date: Self.s3Date)
        #expect(sig.authorization.hasSuffix("Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"))
    }

    @Test func s3ListObjectsExample() {
        let sig = Self.s3Signer.sign(method: "GET", canonicalURI: "/", query: [("max-keys", "2"), ("prefix", "J")], headers: [
            "Host": "examplebucket.s3.amazonaws.com",
            "x-amz-content-sha256": SigV4Signer.emptyPayloadHash, "x-amz-date": "20130524T000000Z",
        ], payloadHash: SigV4Signer.emptyPayloadHash, date: Self.s3Date)
        #expect(sig.authorization.hasSuffix("Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"))
    }

    @Test func pathEncodingKeepsSlashesAndEncodesOnce() {
        #expect(SigV4Signer.encodePath("bucket/r/a b/c+d%.m4s") == "/bucket/r/a%20b/c%2Bd%25.m4s")
        #expect(SigV4Signer.canonicalQuery([("uploads", "")]) == "uploads=")
        #expect(SigV4Signer.canonicalQuery([("b", "2"), ("a", "x y"), ("a", "1")]) == "a=1&a=x%20y&b=2")
    }

    @Test func headerValuesAreTrimmed() {
        #expect(SigV4Signer.trimHeaderValue("  a   b \t c ") == "a b c")
    }
}
