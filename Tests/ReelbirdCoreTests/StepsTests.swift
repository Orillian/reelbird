import Foundation
import Testing
@testable import ReelbirdCore

private func p(_ x: Double, _ y: Double) -> NormPoint { NormPoint(x: x, y: y) }
private func click(_ t: Double, _ x: Double, _ y: Double, button: Int = 0, upAt: NormPoint? = nil) -> [InputEvent] {
    [.down(t, p(x, y), button: button), .up(t + 0.08, upAt ?? p(x, y), button: button)]
}
private func key(_ t: Double, _ chars: String, _ mods: [String] = []) -> InputEvent {
    InputEvent(t: t, type: .key, chars: chars, mods: mods.isEmpty ? nil : mods)
}
private func typing(_ text: String, from t: Double, gap: Double = 0.12) -> [InputEvent] {
    text.enumerated().map { i, ch in key(t + Double(i) * gap, ch == " " ? "␣" : String(ch)) }
}

@Suite struct StepExtractionTests {
    @Test func clicksBecomeStepsWithStableIDs() {
        let events = click(1.2, 0.1, 0.2) + click(3.456, 0.5, 0.5) + [.move(4, p(0.6, 0.6))]
        let steps = StepExtractor.extract(events: events)
        #expect(steps.map(\.id) == ["c1200", "c3456"])
        #expect(steps.map(\.kind) == [.click, .click])
        #expect(steps[0].point == p(0.1, 0.2))
        #expect(abs(steps[0].imageTime - 1.12) < 1e-9)
        // The same log gives the same IDs every time.
        #expect(StepExtractor.extract(events: events).map(\.id) == steps.map(\.id))
    }

    @Test func doubleClicksRepeatsRightClicksAndDrags() {
        var events = click(1, 0.3, 0.3) + click(1.25, 0.301, 0.3)            // double-click
        events += click(3, 0.7, 0.7) + click(3.6, 0.7, 0.7) + click(4.2, 0.7, 0.7)   // the same spot three times
        events += click(6, 0.2, 0.8, button: 1)                                 // right-click
        events += click(8, 0.1, 0.1, upAt: p(0.4, 0.1))                          // drag
        events += click(10, 0.9, 0.9) + click(10.3, 0.5, 0.5)                  // close in time, far apart: two steps
        let steps = StepExtractor.extract(events: events)
        #expect(steps.map(\.kind) == [.doubleClick, .click, .rightClick, .drag, .click, .click])
        #expect(steps[1].count == 3)
        #expect(StepText.template(steps[1], typed: nil) == "Click here (3 times)")
    }

    @Test func typingAfterAClickGoesIntoThatField() {
        var events = click(1, 0.4, 0.3)
        events += typing("Hi there", from: 1.5)
        events.append(key(3, "⏎"))
        let steps = StepExtractor.extract(events: events)
        #expect(steps.count == 1)
        #expect(steps[0].kind == .type)
        #expect(steps[0].id == "c1000")
        #expect(steps[0].point == p(0.4, 0.3))
        #expect(steps[0].typed == "Hi there")
        #expect(steps[0].keys == "Return")
    }

    @Test func typingKeepsShiftDeletesAndIgnoresArrows() {
        var events = [key(1, "h", ["⇧"]), key(1.1, "e"), key(1.2, "y"), key(1.3, "⌫"), key(1.4, "1", ["⇧"]), key(1.5, "←")]
        events.append(key(1.6, "x"))
        let steps = StepExtractor.extract(events: events)
        #expect(steps.count == 1)
        #expect(steps[0].kind == .type && steps[0].point == nil)
        #expect(steps[0].typed == "He!x")
    }

    @Test func aPauseInTypingStartsANewStep() {
        let events = typing("one", from: 1) + typing("two", from: 5)
        let steps = StepExtractor.extract(events: events)
        #expect(steps.map(\.typed) == ["one", "two"])
    }

    @Test func shortcutsAndLoneKeys() {
        let events = [key(1, "s", ["⌘"]), key(1.5, "z", ["⌘"]), key(1.8, "z", ["⌘"]), key(3, "⎋"), key(4, "⏎"), key(6, "→")]
        let steps = StepExtractor.extract(events: events)
        #expect(steps.map(\.kind) == [.shortcut, .shortcut, .key, .key])
        #expect(steps.map(\.keys) == ["⌘S", "⌘Z", "Esc", "Return"])
        #expect(steps[1].count == 2)
        #expect(StepText.template(steps[1], typed: nil) == "Press ⌘Z (2 times)")
    }

    @Test func aClickedFieldLeftEmptyStaysAClick() {
        let events = click(1, 0.5, 0.5) + [key(1.5, "a"), key(1.6, "⌫")]
        let steps = StepExtractor.extract(events: events)
        #expect(steps.map(\.kind) == [.click])
        #expect(steps[0].typed == nil)
    }

    @Test func pointsOutsideTheCaptureAreSkippedAndTheCountIsCapped() {
        #expect(StepExtractor.extract(events: click(1, 1.2, 0.5) + click(2, -0.1, 0.5)).isEmpty)
        let many = (0..<400).flatMap { click(Double($0) * 2, 0.1 + Double($0 % 7) * 0.1, 0.5) }
        #expect(StepExtractor.extract(events: many).count == StepExtractor.maxSteps)
    }

    @Test func narrationTilesTheTimeBetweenSteps() {
        let steps = StepExtractor.extract(events: click(2, 0.1, 0.1) + click(10, 0.5, 0.5))
        let words = [TimedWord(start: 0.5, end: 1.5, text: "First open the inbox."),
                     TimedWord(start: 4, end: 5, text: "Then wait."),
                     TimedWord(start: 9, end: 10, text: "Now save."),
                     TimedWord(start: 20, end: 21, text: "Bye.")]
        let n = StepExtractor.narration(for: steps, words: words)
        #expect(n == ["First open the inbox.", "Then wait. Now save."])
    }
}

@Suite struct StepResolveTests {
    let scanned: [GuideStep] = [
        GuideStep(id: "c1000", kind: .click, t: 1, imageTime: 0.92, point: NormPoint(x: 0.1, y: 0.1), label: "Inbox",
                  labelRect: NormRect(x: 0.08, y: 0.09, width: 0.05, height: 0.02), modelText: "Click \"Inbox\" to see today's tasks"),
        GuideStep(id: "c5000", kind: .click, t: 5, point: NormPoint(x: 0.5, y: 0.5), label: "Delete"),
        GuideStep(id: "c9000", kind: .type, t: 9, point: NormPoint(x: 0.5, y: 0.9), label: "Email", typed: "me@example.com sent"),
        GuideStep(id: "k12000", kind: .shortcut, t: 12, keys: "⌘S"),
        GuideStep(id: "c15000", kind: .click, t: 15, point: NormPoint(x: 0.9, y: 0.05), label: "Wrong button",
                  modelText: "Click \"Settings\" to open preferences"),
    ]

    @Test func cutsTrimAndCropDropSteps() {
        var edit = EditDocument()
        edit.cuts = [TimeRange(start: 4, end: 6)]
        edit.crop = NormRect(x: 0, y: 0.08, width: 1, height: 0.92)
        let steps = GuideSteps.resolve(scanned, edit: edit, duration: 20, markers: [])
        // c5000 is cut; c15000 sits in the cropped-off strip at the top.
        #expect(steps.map(\.id) == ["c1000", "c9000", "k12000"])
        edit.cuts = []
        edit.crop = nil
        edit.trim = TimeRange(start: 2, end: 13)
        #expect(GuideSteps.resolve(scanned, edit: edit, duration: 20, markers: []).map(\.id) == ["c5000", "c9000", "k12000"])
    }

    @Test func wordingPrefersEditsThenModelThenTemplate() {
        var edit = EditDocument()
        edit.guide.setEdit(id: "k12000", text: .some("Save with ⌘S"))
        let steps = GuideSteps.resolve(scanned, edit: edit, duration: 20, markers: [])
        let text = Dictionary(uniqueKeysWithValues: steps.map { ($0.id, $0.text) })
        #expect(text["c1000"] == "Click \"Inbox\" to see today's tasks")
        #expect(text["c5000"] == "Click \"Delete\"")
        #expect(text["k12000"] == "Save with ⌘S")
        // A model sentence that names a different button than the one clicked isn't used.
        #expect(text["c15000"] == "Click \"Wrong button\"")
        // Clearing the edit goes back to the automatic text.
        edit.guide.setEdit(id: "k12000", text: .some("  "))
        #expect(edit.guide.edits.isEmpty)
    }

    @Test func hiddenStepsAndSections() {
        var edit = EditDocument()
        edit.guide.setEdit(id: "c5000", hidden: .some(true))
        let markers = [Marker(id: "m1", t: 0.5, title: "Start"), Marker(id: "m2", t: 8, title: "Sign up"), Marker(id: "m3", t: 8.5, title: "Account")]
        let steps = GuideSteps.resolve(scanned, edit: edit, duration: 20, markers: markers)
        #expect(!steps.contains { $0.id == "c5000" })
        #expect(steps.first { $0.id == "c1000" }?.section == "Start")
        // Two markers before the same step: the later one names the section.
        #expect(steps.first { $0.id == "c9000" }?.section == "Account")
        #expect(steps.first { $0.id == "k12000" }?.section == nil)
        edit.guide.setEdit(id: "c5000", hidden: .some(false))
        #expect(edit.guide.edits.isEmpty)
    }

    @Test func typedTextIsHiddenUnlessAllowedAndSensitivePartsAreMasked() {
        var edit = EditDocument()
        var typing = GuideSteps.resolve(scanned, edit: edit, duration: 20, markers: []).first { $0.id == "c9000" }
        #expect(typing?.text == "Type in \"Email\"")
        #expect(typing?.typed == nil)
        edit.guide.showTypedText = true
        typing = GuideSteps.resolve(scanned, edit: edit, duration: 20, markers: []).first { $0.id == "c9000" }
        #expect(typing?.text == "Type \"••• sent\" in \"Email\"")
        // Typed while a blur is on screen: never shown.
        edit.annotations = [Annotation(kind: .blur, range: TimeRange(start: 8, end: 10), rect: NormRect(x: 0.6, y: 0.6, width: 0.1, height: 0.1))]
        typing = GuideSteps.resolve(scanned, edit: edit, duration: 20, markers: []).first { $0.id == "c9000" }
        #expect(typing?.text == "Type in \"Email\"")
    }

    @Test func labelsUnderABlurAreDropped() {
        var edit = EditDocument()
        edit.annotations = [Annotation(kind: .blur, range: TimeRange(start: 0, end: 3), rect: NormRect(x: 0.05, y: 0.05, width: 0.1, height: 0.06))]
        let first = GuideSteps.resolve(scanned, edit: edit, duration: 20, markers: []).first { $0.id == "c1000" }
        #expect(first?.label == nil && first?.labelRect == nil)
        #expect(first?.text == "Click here")
    }

    @Test func clicksBesideTheirLabelSayNextTo() {
        let s = GuideStep(id: "c1", kind: .click, t: 1, point: NormPoint(x: 0.26, y: 0.36), label: "Fix flaky test",
                          labelRect: NormRect(x: 0.28, y: 0.35, width: 0.12, height: 0.02))
        #expect(StepText.template(s, typed: nil) == "Click next to \"Fix flaky test\"")
    }

    @Test func placementMapsThroughTheCrop() {
        let s = GuideStep(id: "c1", kind: .click, t: 1, point: NormPoint(x: 0.5, y: 0.54), labelRect: NormRect(x: 0.4, y: 0.52, width: 0.2, height: 0.04))
        let place = GuideSteps.placement(s, crop: NormRect(x: 0, y: 0.08, width: 1, height: 0.92))
        #expect(place.point == NormPoint(x: 0.5, y: 0.5))
        #expect(abs((place.box?.y ?? 0) - 0.4783) < 1e-4)
    }
}

@Suite struct GuideDocumentTests {
    @Test func guideSettingsDecodeLeniently() throws {
        let json = #"{"guide": {"share": false, "edits": [{"id": "c1", "text": "Hi"}, {"text": "no id"}, {"id": "c2", "hidden": true}]}}"#
        let edit = try JSONCoding.decoder.decode(EditDocument.self, from: Data(json.utf8))
        #expect(edit.guide.share == false)
        #expect(edit.guide.copyText == true)
        #expect(edit.guide.edits.map(\.id) == ["c1", "c2"])
        // Older files have no guide: defaults.
        let old = try JSONCoding.decoder.decode(EditDocument.self, from: Data("{}".utf8))
        #expect(old.guide == GuideSettings())
    }

    @Test func stepsCacheIsUsedOnlyForTheSameInputs() throws {
        let dir = testTemporaryDirectory.appendingPathComponent("rb-steps-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("T.reelbird"))
        let inputs = StepDocument.Inputs(events: 10, screen: "screen/screen.mp4", screenSize: 100, transcript: nil)
        let doc = StepDocument(inputs: inputs, writer: "template", steps: [GuideStep(id: "c1", kind: .click, t: 1, text: "Click here")])
        try bundle.writeSteps(doc)
        #expect(bundle.readSteps(inputs: inputs) == doc)
        var other = inputs
        other.events = 11
        #expect(bundle.readSteps(inputs: other) == nil)
    }
}
