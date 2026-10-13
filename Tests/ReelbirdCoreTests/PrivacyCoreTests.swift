import CoreGraphics
import Foundation
import Testing
@testable import ReelbirdCore

// Find Sensitive Info patterns, the Luhn check, linking sightings across frames, and annotation geometry.

private func kinds(_ text: String, words: [String] = []) -> [SensitiveKind] {
    SensitivePatterns.matches(in: text, customWords: words).map(\.kind)
}

private func matched(_ text: String, words: [String] = []) -> [String] {
    SensitivePatterns.matches(in: text, customWords: words).map { String(text[$0.range]) }
}

@Test func emailsAreFound() {
    #expect(matched("Signed in as jane.doe@example.com today") == ["jane.doe@example.com"])
    #expect(kinds("Contact: ops+alerts@mail.acme-corp.co.uk") == [.email])
    // OCR sometimes puts a space next to the @.
    #expect(kinds("bob @example.org") == [.email])
    #expect(kinds("no email here, just @mentions and example.com").isEmpty)
    #expect(kinds("user@localhost").isEmpty)
}

@Test func apiKeysByPrefix() {
    let positives = [
        "sk-proj-Ab3dEf9GhJk2LmN0pQr5StU8vWx1",
        "sk-ant-api03-Zx8yW7vU6tS5rQ4pO3nM2lK1",
        "sk" + "_live_51HxYzAbCdEfGh12345678",
        "pk" + "_test_TYooMQauvdEDq54NiTphI7jx",
        "gh" + "p_16C7e42F292c6912E7710c838347Ae178B4a",
        "gi" + "thub_pat_11ABCDEFG0123456789_abcdefghijklmnop",
        "AKIAIOSFODNN7EXAMPLE",
        "xo" + "xb-1234567890-0987654321-AbCdEfGhIjKlMnOp",
        "AI" + "zaSyD-9tSrke72PouQMnMX-a7eZSW0jkFMBWY",
        "gl" + "pat-xxYyZz0123456789abcd",
        "hf" + "_aBcDeFgHiJkLmNoPqRsTuVwXyZ012345",
        "ey" + "JhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
        "-----BEGIN RSA PRIVATE KEY-----",
    ]
    for p in positives {
        #expect(kinds("token: \(p)").contains(.apiKey), "\(p)")
        #expect(kinds(p) == [.apiKey], "\(p) alone")
    }
    #expect(matched("export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE") == ["AKIAIOSFODNN7EXAMPLE"])
    #expect(matched("GITHUB_TOKEN=gh" + "p_16C7e42F292c6912E7710c838347Ae178B4a") == ["gh" + "p_16C7e42F292c6912E7710c838347Ae178B4a"])
}

@Test func keyValuePairsAndHighEntropyStrings() {
    #expect(matched("password: hunter2!x") == ["hunter2!x"])
    #expect(matched("API_KEY=\"9f8e7d6c5b4a39281706f5e4d3c2b1a0\"").contains("9f8e7d6c5b4a39281706f5e4d3c2b1a0"))
    #expect(matched("Authorization: Bearer a1B2c3D4e5F6g7H8i9J0kLmN") == ["a1B2c3D4e5F6g7H8i9J0kLmN"])
    #expect(kinds("x7Kp2QmZ9vR4tL8wN3bY6cH1") == [.apiKey])
    // Not secrets: words, identifiers, placeholders, paths, versions, a git commit hash.
    for text in ["applicationDidFinishLaunchingNotification", "testCase123HelperFunction", "password: ********",
                 "password: required", "/Users/me/Library/Application Support/Reelbird", "Version 2.4.1 (build 1903)",
                 "commit 3f2a9c01d4e5b6a7980f1e2d3c4b5a6978695a4b", "The quick brown fox jumps over the lazy dog",
                 "https://github.com/btahir/reelbird/pull/42"] {
        #expect(!kinds(text).contains(.apiKey), "\(text)")
    }
}

@Test func luhnAndCardNumbers() {
    #expect(SensitivePatterns.luhnValid("4242424242424242"))
    #expect(SensitivePatterns.luhnValid("79927398713"))
    #expect(!SensitivePatterns.luhnValid("4242424242424241"))
    #expect(!SensitivePatterns.luhnValid("12a4"))
    #expect(SensitivePatterns.isCardNumber("378282246310005"))   // Amex test number
    #expect(SensitivePatterns.isCardNumber("5555555555554444"))
    #expect(!SensitivePatterns.isCardNumber("1234567812345670"))  // passes Luhn, no card network starts with 1
    #expect(matched("Card 4242 4242 4242 4242 exp 12/29") == ["4242 4242 4242 4242"])
    #expect(kinds("Card 4242-4242-4242-4242") == [.card])
    #expect(kinds("Card 4242 4242 4242 4241").isEmpty)
    #expect(kinds("Order 1234567890123").isEmpty)
}

@Test func phoneNumbers() {
    #expect(kinds("Call +1 415-555-0132") == [.phone])
    #expect(kinds("Office (415) 555-0132") == [.phone])
    #expect(kinds("Mobile 07700 900123") == [.phone])
    #expect(kinds("+44 20 7946 0958") == [.phone])
    for text in ["Version 10.15.7", "192.168.100.200", "Order 1234567", "Updated 2026-10-13 14:05", "ID 1697040000123"] {
        #expect(!kinds(text).contains(.phone), "\(text)")
    }
}

@Test func customWordsAndOverlaps() {
    #expect(matched("Roadmap for Project Bluebird (internal)", words: ["project bluebird"]) == ["Project Bluebird"])
    #expect(kinds("bluebird bluebird", words: ["Bluebird"]) == [.custom, .custom])
    #expect(kinds("a", words: ["a"]).isEmpty)
    // A card number isn't also reported as a phone number.
    #expect(kinds("4242 4242 4242 4242") == [.card])
    // Only the kinds asked for.
    #expect(SensitivePatterns.matches(in: "jane@example.com +1 415-555-0132", kinds: [.phone]).map(\.kind) == [.phone])
}

@Test func maskedPreviewsHideTheValue() {
    #expect(SensitivePatterns.mask("sk-proj-ab3def9ghjk2", kind: .apiKey) == "sk-p…k2")
    #expect(SensitivePatterns.mask("jane.doe@example.com", kind: .email) == "j…@example.com")
    #expect(SensitivePatterns.mask("4242424242424242", kind: .card) == "•••• 4242")
    #expect(SensitivePatterns.mask("+14155550132", kind: .phone) == "••• 132")
}

// MARK: Linking

private func sighting(_ v: String, _ y: Double, kind: SensitiveKind = .apiKey, x: Double = 0.1) -> SensitiveSighting {
    SensitiveSighting(kind: kind, value: v, rect: NormRect(x: x, y: y, width: 0.3, height: 0.04))
}

@Test func linkingFollowsTextThatScrolls() {
    // Seen from 2 s to 4 s, moving up 0.1 per half second.
    var samples: [SensitiveSample] = (0..<10).map { i in SensitiveSample(t: Double(i) * 0.5, sightings: []) }
    for (k, i) in (4...8).enumerated() { samples[i].sightings = [sighting("gh" + "p_abcdefghijklmnopqrstu", 0.8 - Double(k) * 0.1)] }
    let d = SensitiveTracker.link(samples: samples, duration: 5)
    #expect(d.count == 1)
    guard let one = d.first else { return }
    #expect(one.kind == .apiKey && one.sightings == 5)
    // From the sample before it appeared to the sample after it was last seen.
    #expect(one.range == TimeRange(start: 1.5, end: 4.5))
    let a = one.annotation()
    #expect(a.keys != nil && a.detected == "apiKey" && a.kind == .blur)
    // Between two samples the blur covers both places; at a sample, exactly that place.
    #expect(a.rect(at: 1.8).y == 0.8)
    let mid = a.rect(at: 2.25)
    #expect(abs(mid.y - 0.7) < 1e-9 && abs(mid.height - 0.14) < 1e-9)
    #expect(a.rect(at: 4.0).y.isApproximately(0.4))
    #expect(a.rect.y.isApproximately(0.4) && (a.rect.y + a.rect.height).isApproximately(0.84))
}

@Test func linkingSeparatesRepeatsAndToleratesMisreads() {
    // The same email twice on screen, each staying put; one sample misreads a character.
    let samples = (0..<6).map { i in
        SensitiveSample(t: Double(i) * 0.5, sightings: [
            sighting(i == 3 ? "jane.doe@examp1e.com" : "jane.doe@example.com", 0.2, kind: .email),
            sighting("jane.doe@example.com", 0.6, kind: .email),
        ])
    }
    let d = SensitiveTracker.link(samples: samples, duration: 3)
    #expect(d.count == 2)
    #expect(d.allSatisfy { $0.sightings == 6 && $0.range == TimeRange(start: 0, end: 3) })
    #expect(Set(d.map(\.rect.y)) == [0.2, 0.6])
    // Still: a single area, so the blur needs no keys.
    #expect(d.allSatisfy { $0.annotation().keys == nil }, "\(d.map(\.keys))")
    #expect(d[0].id != d[1].id)
    // IDs are stable from scan to scan.
    #expect(SensitiveTracker.link(samples: samples, duration: 3).map(\.id) == d.map(\.id))
}

@Test func linkingStartsANewItemAfterALongGap() {
    var samples = (0..<12).map { i in SensitiveSample(t: Double(i) * 0.5, sightings: []) }
    for i in [1, 2] + [9, 10] { samples[i].sightings = [sighting("sk" + "_live_abcdefghijklmnop", 0.3)] }
    let d = SensitiveTracker.link(samples: samples, duration: 6)
    #expect(d.count == 2)
    #expect(d.map(\.range) == [TimeRange(start: 0, end: 1.5), TimeRange(start: 4, end: 5.5)])
    #expect(SensitiveTracker.similar("abcdefghijkl", "abcdefgh1jkl"))
    #expect(!SensitiveTracker.similar("abcdef", "abcxyz"))
}

// MARK: Annotations

@Test func annotationDecodesOlderFilesAndKeepsNewFields() throws {
    let old = #"{"id":"a1","kind":"blur","range":{"start":1,"end":2},"rect":{"x":0.1,"y":0.1,"width":0.2,"height":0.1}}"#
    let a = try JSONCoding.decoder.decode(Annotation.self, from: Data(old.utf8))
    #expect(a.color == Annotation.defaultColor && a.blurStyle == .blur && a.blurStrength == 0.5 && a.keys == nil)
    var b = a
    b.style = .pixelate
    b.strength = 0.9
    b.keys = [Annotation.Key(t: 1, rect: a.rect), Annotation.Key(t: 2, rect: NormRect(x: 0.5, y: 0.1, width: 0.2, height: 0.1))]
    b.detected = "email"
    let round = try JSONCoding.decoder.decode(Annotation.self, from: JSONCoding.encoder.encode(b))
    #expect(round == b)
    #expect(round.title == "Email")
    // Nil fields stay out of the file.
    let json = String(decoding: try JSONCoding.encoder.encode(a), as: UTF8.self)
    #expect(!json.contains("strength") && !json.contains("keys") && !json.contains("fontSize"))
    // Out-of-range values are clamped instead of failing the document.
    let wild = #"{"kind":"text","range":{"start":0,"end":1},"rect":{"x":0,"y":0,"width":0.1,"height":0.1},"strength":7,"fontSize":-1,"style":"swirl"}"#
    let w = try JSONCoding.decoder.decode(Annotation.self, from: Data(wild.utf8))
    #expect(w.strength == 1 && w.fontSize == nil && w.style == nil && !w.id.isEmpty)
    // A whole edit with annotations from before this version.
    let edit = #"{"formatVersion":1,"annotations":[\#(old)]}"#
    #expect(try JSONCoding.decoder.decode(EditDocument.self, from: Data(edit.utf8)).annotations.count == 1)
}

@Test func moveAndResizeCarryKeysAndArrowEnds() {
    var a = Annotation(kind: .blur, range: TimeRange(start: 0, end: 4), rect: NormRect(x: 0.1, y: 0.1, width: 0.2, height: 0.4))
    a.keys = [Annotation.Key(t: 0, rect: NormRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)),
              Annotation.Key(t: 4, rect: NormRect(x: 0.1, y: 0.4, width: 0.2, height: 0.1))]
    a.setRect(NormRect(x: 0.5, y: 0.1, width: 0.4, height: 0.4))
    #expect(a.keys![0].rect.x.isApproximately(0.5) && a.keys![0].rect.width.isApproximately(0.4))
    #expect(a.keys![1].rect.y.isApproximately(0.4))
    var arrow = Annotation(kind: .arrow, range: TimeRange(start: 0, end: 1), rect: .full)
    arrow.setArrow(tail: NormPoint(x: 0.8, y: 0.2), head: NormPoint(x: 0.4, y: 0.6))
    #expect(arrow.rect.x.isApproximately(0.4) && arrow.rect.width.isApproximately(0.4))
    arrow.setRect(NormRect(x: 0.3, y: 0.2, width: 0.4, height: 0.4))
    #expect(arrow.arrowEnds.tail.x.isApproximately(0.7) && arrow.arrowEnds.head.x.isApproximately(0.3))
    var moved = a
    moved.shift(by: 1.5)
    #expect(moved.range == TimeRange(start: 1.5, end: 5.5) && moved.keys!.map(\.t) == [1.5, 5.5])
}

@Test func blurCellsAreLargeAtEveryStrength() {
    // A one-line box on a Retina screen: at least 9 points (18 px), larger than body-text capitals.
    #expect(PrivacyBlur.cellPixels(shortSidePixels: 40, strength: 0, captureScale: 2) == 18)
    #expect(PrivacyBlur.cellPixels(shortSidePixels: 40, strength: 1, captureScale: 2) == 36)
    // A large area: a quarter to half of its shorter side.
    #expect(PrivacyBlur.cellPixels(shortSidePixels: 400, strength: 0, captureScale: 2) == 100)
    #expect(PrivacyBlur.cellPixels(shortSidePixels: 400, strength: 1, captureScale: 1) == 200)
    #expect(PrivacyBlur.cellPixels(shortSidePixels: 400, strength: .nan, captureScale: 1) == 150)
}

@Test func screenMappingRoundTrips() {
    let m = ScreenMapping(originX: -120, originY: 40, scaleX: 2400, scaleY: 1350)
    let r = NormRect(x: 0.2, y: 0.3, width: 0.25, height: 0.1)
    let back = m.screenRect(m.rect(r))
    #expect(back.x.isApproximately(r.x) && back.y.isApproximately(r.y) && back.width.isApproximately(r.width) && back.height.isApproximately(r.height))
    let p = m.offsetBy(dx: 10, dy: 5).point(NormPoint(x: 0.5, y: 0.5))
    #expect(p == CGPoint(x: -120 + 1200 + 10, y: 40 + 675 + 5))
}

private extension Double {
    func isApproximately(_ o: Double, _ tol: Double = 1e-9) -> Bool { abs(self - o) <= tol }
}
