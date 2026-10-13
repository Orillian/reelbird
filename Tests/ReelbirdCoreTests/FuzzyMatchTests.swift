import Testing
@testable import ReelbirdCore

// The command menu's search.

private struct Item { let title: String; var keywords: [String] = []; var recent = 0.0 }

private let items: [Item] = [
    Item(title: "Play"),
    Item(title: "Split at Playhead", keywords: ["cut", "blade"]),
    Item(title: "Add Zoom at Playhead"),
    Item(title: "Export as GIF…", keywords: ["animated"]),
    Item(title: "Export as MP4…", keywords: ["h264", "video"]),
    Item(title: "Burn In Captions", keywords: ["subtitles"]),
    Item(title: "Zoom In Timeline"),
    Item(title: "Show in Finder", keywords: ["reveal"]),
    Item(title: "Enhance Voice", keywords: ["noise", "denoise"]),
    Item(title: "Copy Zooms"),
]

private func ranked(_ q: String, _ list: [Item] = items) -> [String] {
    FuzzyMatch.rank(list, query: q, fields: { [$0.title] + $0.keywords }, boost: { $0.recent }).map(\.title)
}

@Test func lettersMustAppearInOrder() {
    #expect(FuzzyMatch.match("spl", in: "Split at Playhead") != nil)
    #expect(FuzzyMatch.match("lps", in: "Split") == nil)
    #expect(FuzzyMatch.match("xyz", in: "Export") == nil)
    #expect(FuzzyMatch.match("", in: "Anything")?.score == 0)
    #expect(FuzzyMatch.match("PLAY", in: "play")?.score == .infinity)
    #expect(FuzzyMatch.match("enhance", in: "Énhance Voice") != nil, "accents ignored")
    #expect(FuzzyMatch.match("sap", in: "Split at Playhead")?.positions == [0, 6, 9], "word starts are preferred")
}

@Test func rankingPrefersWordStartsAndPrefixes() {
    #expect(ranked("split").first == "Split at Playhead")
    #expect(ranked("exp gif").first == "Export as GIF…")
    #expect(ranked("gif").first == "Export as GIF…")
    #expect(ranked("burn cap").first == "Burn In Captions")
    #expect(ranked("zoom").prefix(3).allSatisfy { $0.contains("Zoom") })
    #expect(ranked("play").first == "Play", "an exact title wins")
    // Keywords find commands, a little below title matches.
    #expect(ranked("subtitles").first == "Burn In Captions")
    #expect(ranked("reveal").first == "Show in Finder")
    #expect(ranked("denoise").first == "Enhance Voice")
    #expect(ranked("qqq").isEmpty)
}

@Test func recentCommandsComeFirst() {
    var list = items
    list[7].recent = 2 // Show in Finder, used last
    list[3].recent = 1 // Export as GIF
    // No query: most recent first, then the original order.
    #expect(Array(ranked("", list).prefix(3)) == ["Show in Finder", "Export as GIF…", "Play"])
    // Among similar matches a recent one rises.
    #expect(ranked("export", list).first == "Export as GIF…")
    var mp4 = items
    mp4[4].recent = 1
    #expect(ranked("export", mp4).first == "Export as MP4…")
    // But a strong match still beats a weak recent one.
    #expect(ranked("split", list).first == "Split at Playhead")
}
