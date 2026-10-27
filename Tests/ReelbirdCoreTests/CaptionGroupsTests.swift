import Foundation
import Testing
@testable import ReelbirdCore

private func words(_ spec: [(String, Double, Double)]) -> [CaptionWord] {
    spec.map { CaptionWord(range: TimeRange(start: $0.1, end: $0.2), text: $0.0) }
}

@Test func phraseGroupsBreakAtSentencesPausesAndSixWords() {
    let w = words([("Open", 0, 0.3), ("Settings,", 0.32, 0.8), ("then", 0.95, 1.1), ("turn", 1.18, 1.4), ("on", 1.42, 1.55),
                   ("Auto-edit.", 1.6, 2.2), ("It", 2.7, 2.8), ("cuts", 2.86, 3.1), ("every", 3.12, 3.4), ("pause", 3.42, 3.7),
                   ("for", 3.78, 3.9), ("you", 3.95, 4.1), ("today", 4.12, 4.4), ("now.", 4.45, 4.8)])
    let g = CaptionGroups.groups(w, style: .highlight)
    #expect(g.map { $0.words.map(\.text).joined(separator: " ") } ==
            ["Open Settings, then turn on Auto-edit.", "It cuts every pause for you", "today now."])
    // Never two on screen: each group ends before the next starts.
    for (a, b) in zip(g, g.dropFirst()) { #expect(a.range.end <= b.range.start) }
    #expect(abs(g[0].range.start - (0 - 0.08)) < 1e-9 || g[0].range.start == 0)
}

@Test func longPauseStartsANewGroupAndLoneWordsMerge() {
    let w = words([("So", 0, 0.2), ("this", 0.25, 0.4), ("works", 0.45, 0.8), ("well", 2.0, 2.3), ("indeed.", 2.35, 2.8)])
    let g = CaptionGroups.groups(w, style: .pop)
    #expect(g.count == 2)
    #expect(g[1].words.first?.text == "well")
}

@Test func oneWordGroupsJoinShortWords() {
    let w = words([("Click", 0, 0.3), ("the", 0.32, 0.4), ("button.", 0.42, 0.8), ("Done.", 1.5, 1.9)])
    let g = CaptionGroups.groups(w, style: .oneWord)
    #expect(g.map { $0.words.map(\.text) } == [["Click"], ["the", "button."], ["Done."]])
    for x in g { #expect(x.range.duration >= 0.25 - 1e-9 || x == g.last) }
}

@Test func groupLookupFindsTheGroupOnScreen() {
    let g = CaptionGroups.groups(words([("A", 0.1, 0.5), ("b.", 0.5, 0.9), ("C", 3, 3.4), ("d.", 3.4, 3.8)]), style: .highlight)
    let starts = g.map(\.range.start)
    #expect(CaptionGroups.index(at: 0.3, groups: g, starts: starts) == 0)
    #expect(CaptionGroups.index(at: 2.5, groups: g, starts: starts) == nil)
    #expect(CaptionGroups.index(at: 3.5, groups: g, starts: starts) == 1)
}

@Test func transcriptJSONSkipsHiddenSegmentsAndSpreadsUntimedWords() throws {
    let json = """
    {"locale":"en-US","segments":[
      {"range":{"start":0,"end":1},"text":"Hello there","words":[{"range":{"start":0,"end":0.4},"text":"Hello"},{"range":{"start":0.5,"end":1},"text":"there"}]},
      {"range":{"start":1,"end":2},"text":"secret line","words":[],"hidden":true},
      {"range":{"start":2,"end":3},"text":"no timings","words":[]}
    ]}
    """
    let w = try #require(CaptionGroups.words(transcriptJSON: Data(json.utf8)))
    #expect(w.map(\.text) == ["Hello", "there", "no", "timings"])
    #expect(w[2].range == TimeRange(start: 2, end: 2.5))
}

@Test func emphasisMarksNumbersAndNamesSparingly() {
    let w = CaptionGroups.markEmphasis(words([("It", 0, 0.1), ("costs", 0.1, 0.2), ("$5", 0.2, 0.3), ("on", 0.3, 0.4),
                                             ("Reelbird", 0.4, 0.5), ("today.", 0.5, 0.6)]))
    #expect(w.first { $0.text == "$5" }?.emphasis == true)
    #expect(w.filter(\.emphasis).count <= 2)
    #expect(w.first { $0.text == "It" }?.emphasis == false)
}

@Test func captionSettingsDecodeOlderFilesAndKeepBurnInForThem() throws {
    let old = try JSONDecoder().decode(CaptionSettings.self, from: Data(#"{"burnIn":true,"file":"captions.vtt"}"#.utf8))
    #expect(old.style == .classic && old.burnIn && old.position == .auto && old.palette == .night)
    let off = try JSONDecoder().decode(CaptionSettings.self, from: Data(#"{"file":"captions.vtt"}"#.utf8))
    #expect(off.style == .none && !off.burnIn)
    var s = CaptionSettings()
    s.style = .marker
    s.palette = .mint
    let data = try JSONEncoder().encode(s)
    let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(obj["burnIn"] as? Bool == true && obj["style"] as? String == "marker")
    let back = try JSONDecoder().decode(CaptionSettings.self, from: data)
    #expect(back == s)
    // An explicit style wins over the older flag (e.g. turning captions off from Classic).
    let none = try JSONDecoder().decode(CaptionSettings.self, from: Data(#"{"style":"none","burnIn":true}"#.utf8))
    #expect(none.style == .none)
}

@Test func paletteTextReadsOnItsBacking() {
    func lum(_ c: RGBA) -> Double {
        func ch(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b)
    }
    func ratio(_ a: RGBA, _ b: RGBA) -> Double { let x = lum(a), y = lum(b); return (max(x, y) + 0.05) / (min(x, y) + 0.05) }
    for p in CaptionSettings.Palette.allCases {
        #expect(ratio(p.onAccent, p.accent) >= 4.5, "\(p) marker text")
        if let back = p.backing {
            let solid = RGBA(back.r, back.g, back.b)
            #expect(ratio(p.text, solid) >= 4.5, "\(p) text")
            #expect(ratio(p.accent, solid) >= 4.5, "\(p) accent")
        }
    }
}
