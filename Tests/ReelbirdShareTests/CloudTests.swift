import Foundation
import Testing
import ReelbirdCore
@testable import ReelbirdShare

@Suite struct CloudTests {
    @Test func shareIDFromKeysAndPrefixes() {
        #expect(CloudKeys.shareID(in: "r/MyR3jLKo9BGwGW/hls/seg_00001.m4s") == "MyR3jLKo9BGwGW")
        #expect(CloudKeys.shareID(in: "r/MyR3jLKo9BGwGW/") == "MyR3jLKo9BGwGW")
        #expect(CloudKeys.shareID(in: "r/MyR3jLKo9BGwGW") == "MyR3jLKo9BGwGW")
        #expect(CloudKeys.shareID(in: "r") == nil)
        #expect(CloudKeys.shareID(in: "") == nil)
    }

    @Test func normalizingKeepsTheCloudServer() {
        let d = ShareDestination(endpoint: "acc.r2.cloudflarestorage.com", bucket: "b", accessKeyID: "cloud",
                                 publicBaseURL: "https://watch.reelbird.app/", cloudServer: "watch.reelbird.app/")
        let n = ShareSettings.normalized(d)
        #expect(n.cloudServer == "https://watch.reelbird.app")
        #expect(n.isCloud)
        #expect(ShareSettings.normalized(ShareDestination(endpoint: "e", bucket: "b", accessKeyID: "k", publicBaseURL: "p")).cloudServer == nil)
    }

    @Test func shareJSONFromEarlierVersionsStillLoads() throws {
        let old = #"{"endpoint":"https://a.r2.cloudflarestorage.com","bucket":"b","region":"auto","accessKeyID":"k","publicBaseURL":"https://v.example.com","prefix":"r"}"#
        let d = try JSONCoding.decoder.decode(ShareDestination.self, from: Data(old.utf8))
        #expect(d.cloudServer == nil)
        #expect(!d.isCloud)
    }

    @Test func cloudAccountMakesACloudDestination() {
        let a = CloudAccount(server: "http://localhost:8788", email: "a@example.com", plan: "pro",
                             storage: .init(endpoint: "https://acc.r2.cloudflarestorage.com", bucket: "hosted", region: "auto",
                                            prefix: "r", publicBaseURL: "http://localhost:8788"),
                             enabled: true)
        let d = a.destination
        #expect(d.cloudServer == "http://localhost:8788")
        #expect(d.bucket == "hosted")
        #expect(ShareLayout(id: "MyR3jLKo9BGwGW", destination: d).pageURL == "http://localhost:8788/r/MyR3jLKo9BGwGW/")
        #expect(a.isPro)
    }

    @Test func decodesTheServerContract() throws {
        let me = #"""
        {"email":"a@example.com","plan":"free","limits":{"activeLinks":5,"storageBytes":5000000000,"analytics":false},
         "usage":{"activeLinks":1,"storageBytes":4194304},"accountURL":"http://localhost:8788/account",
         "storage":{"endpoint":"https://acc.r2.cloudflarestorage.com","bucket":"hosted","region":"auto","prefix":"r","publicBaseURL":"http://localhost:8788"}}
        """#
        let m = try CloudAPI.decoder.decode(CloudAPI.Me.self, from: Data(me.utf8))
        #expect(m.limits.activeLinks == 5)
        #expect(m.usage.storageBytes == 4_194_304)

        let pro = #"{"email":"a@example.com","plan":"pro","limits":{"activeLinks":null,"storageBytes":100000000000,"analytics":true},"usage":{"activeLinks":0,"storageBytes":0},"accountURL":"x","storage":{"endpoint":"e","bucket":"b","region":"auto","prefix":"r","publicBaseURL":"p"}}"#
        #expect(try CloudAPI.decoder.decode(CloudAPI.Me.self, from: Data(pro.utf8)).limits.activeLinks == nil)

        let keys = #"{"accessKeyId":"k","secretAccessKey":"s","sessionToken":"t","expiresAt":"2026-10-20T05:06:09.000Z","endpoint":"e","bucket":"b"}"#
        let k = try CloudAPI.decoder.decode(CloudAPI.Keys.self, from: Data(keys.utf8))
        #expect(k.expiresAt == Date(timeIntervalSince1970: 1_792_472_769))

        let stats = #"""
        {"id":"MyR3jLKo9BGwGW","title":null,"views":1,"opens":2,"uniqueViewers":1,"watchSeconds":12,"averagePercent":100,
         "completionRate":100,"retention":[1,1,0.5],"chunkSeconds":2,"duration":6,"byDay":[{"day":"2026-10-19","views":1}],
         "referrers":[{"name":"Direct","views":1}],"countries":[],"devices":[{"name":"Desktop","views":1}],"recent":[],
         "locked":false,"statsURL":"http://localhost:8788/account/s/MyR3jLKo9BGwGW"}
        """#
        let s = try CloudAPI.decoder.decode(CloudAPI.Stats.self, from: Data(stats.utf8))
        #expect(s.retention == [1, 1, 0.5])
        #expect(s.title == nil)
    }

    @Test func sessionTokenIsSignedAndNeverPrinted() {
        let signer = SigV4Signer(accessKeyID: "AKID", secretAccessKey: "secret", region: "auto", sessionToken: "TOKEN-VALUE")
        let headers = ["host": "acc.r2.cloudflarestorage.com", "x-amz-date": "20261020T000000Z",
                       "x-amz-content-sha256": SigV4Signer.emptyPayloadHash, "x-amz-security-token": "TOKEN-VALUE"]
        let sig = signer.sign(method: "GET", canonicalURI: "/b/r/x", headers: headers, payloadHash: SigV4Signer.emptyPayloadHash,
                              date: Date(timeIntervalSince1970: 1_792_454_400))
        #expect(sig.signedHeaders.contains("x-amz-security-token"))
        var dumped = ""
        dump(signer, to: &dumped)
        #expect(!dumped.contains("TOKEN-VALUE"))
        #expect(!signer.description.contains("TOKEN-VALUE"))
    }
}
