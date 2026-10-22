import Foundation
import ReelbirdCore
import Testing
@testable import ReelbirdAI

@Suite struct StepLabelTests {
    // A 2880 × 1800 frame: a toolbar with "Share" and "+ New Task", and a row with a checkbox left of its title.
    let W = 2880.0, H = 1800.0
    func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NormRect { NormRect(x: x / W, y: y / H, width: w / W, height: h / H) }
    var found: [StepLabeler.Found] {
        [
            .init(text: "Share", rect: box(2290, 155, 80, 30)),
            .init(text: "+ New Task", rect: box(2460, 155, 160, 30)),
            .init(text: "Fix flaky checkout test", rect: box(820, 640, 370, 34)),
            .init(text: "11:30", rect: box(2610, 640, 80, 34)),
            .init(text: "·", rect: box(1000, 900, 10, 10)),
        ]
    }

    @Test func theTextUnderThePointerWins() {
        let p = NormPoint(x: 2320 / W, y: 170 / H)
        #expect(StepLabeler.pick(found, at: p, pixelWidth: W, pixelHeight: H)?.text == "Share")
    }

    @Test func otherwiseTheNearestTextOnTheSameRow() {
        // The checkbox, 60 px left of its title.
        let p = NormPoint(x: 760 / W, y: 657 / H)
        #expect(StepLabeler.pick(found, at: p, pixelWidth: W, pixelHeight: H)?.text == "Fix flaky checkout test")
    }

    @Test func nothingWhenNoTextIsWithinReach() {
        let p = NormPoint(x: 1800 / W, y: 1400 / H)
        #expect(StepLabeler.pick(found, at: p, pixelWidth: W, pixelHeight: H) == nil)
        // Punctuation alone is not a label.
        #expect(StepLabeler.pick(found, at: NormPoint(x: 1005 / W, y: 905 / H), pixelWidth: W, pixelHeight: H) == nil)
    }

    @Test func labelsAreTidied() {
        #expect(StepLabeler.tidy("  Save   draft: ") == "Save draft")
        #expect(StepLabeler.tidy(String(repeating: "a", count: 80)).count == 60)
        #expect(StepLabeler.tidy("•") == "")
    }

    @Test func aLineCutByTheWindowEdgeIsReadAgain() {
        let p = NormPoint(x: 0.5, y: 0.5)
        let w = StepLabeler.window.w / W
        let inside = NormRect(x: 0.5 - w / 4, y: 0.49, width: w / 4, height: 0.02)
        let cut = NormRect(x: 0.5, y: 0.49, width: w / 2, height: 0.02)
        #expect(!StepLabeler.touchesWindowEdge(inside, around: p, pixelWidth: W, pixelHeight: H))
        #expect(StepLabeler.touchesWindowEdge(cut, around: p, pixelWidth: W, pixelHeight: H))
    }
}

@Suite struct StepWriterTests {
    @Test func modelSentencesAreTidied() {
        #expect(StepWriter.tidy("Click 'Inbox' to see today's tasks.", label: "Inbox") == "Click \"Inbox\" to see today's tasks")
        #expect(StepWriter.tidy("\"Click Save\"", label: "Save") == "Click Save")
        #expect(StepWriter.tidy("+ New Task", label: "+ New Task") == "")
        #expect(StepWriter.tidy("Open the menu\nand more", label: nil) == "Open the menu")
    }

    @Test func stepsAreDescribedForTheModel() {
        let s = GuideStep(id: "c1", kind: .click, t: 1, label: "Save", count: 2)
        #expect(StepWriter.describe(s, number: 3, narration: "now save it") == "3. click on \"Save\" 2 times (narrator said: \"now save it\")")
        let k = GuideStep(id: "k1", kind: .shortcut, t: 1, keys: "⌘S")
        #expect(StepWriter.describe(k, number: 1, narration: nil) == "1. press ⌘S")
    }

    @Test func narrationGoesBySentence() {
        let t = Transcript(segments: [
            .init(range: TimeRange(start: 0, end: 4), text: "Open the inbox. Then add a task", words: [
                .init(range: TimeRange(start: 0, end: 0.5), text: "Open"), .init(range: TimeRange(start: 0.5, end: 0.8), text: "the"),
                .init(range: TimeRange(start: 0.8, end: 1.2), text: "inbox."), .init(range: TimeRange(start: 2, end: 2.4), text: "Then"),
                .init(range: TimeRange(start: 2.4, end: 2.8), text: "add"), .init(range: TimeRange(start: 2.8, end: 3), text: "a"),
                .init(range: TimeRange(start: 3, end: 4), text: "task"),
            ]),
        ], locale: "en-US")
        let s = StepScanner.sentences(t)
        #expect(s.map(\.text) == ["Open the inbox.", "Then add a task"])
        #expect(s.map(\.start) == [0, 2])
    }
}
