import Foundation
import Testing
import ReelbirdCore
@testable import ReelbirdRender

// The keystroke overlay: shortcuts and special keys by default, plain typing only when asked for, and
// never typing from under a blur (a password blurred on screen must not be readable in the overlay).

private func keyPlan(_ keys: [InputEvent], configure: (inout EditDocument) -> Void) throws -> RenderPlan {
    let bundle = try ProjectBundle.create(at: testTemporaryDirectory.appendingPathComponent("rb-keys-\(UUID().uuidString).reelbird"))
    let manifest = ProjectManifest(title: "K", appVersion: "test", status: .complete,
                                   capture: CaptureInfo(source: .synthetic(name: "t"), pixelSize: PixelSize(width: 1280, height: 720),
                                                        scale: 1, frameRate: 30),
                                   clock: ClockInfo(originHostTime: 0), duration: 10)
    var edit = EditDocument.initial(for: manifest)
    edit.cursor.showKeystrokes = true
    configure(&edit)
    return try RenderPlan(bundle: bundle, manifest: manifest, edit: edit, events: keys, reusing: nil)
}

/// One key event per character of `text`, 0.1 s apart from `start`.
private func typing(_ text: String, at start: Double) -> [InputEvent] {
    text.enumerated().map { InputEvent(t: start + Double($0.offset) * 0.1, type: .key, chars: String($0.element)) }
}

@Test func keystrokeOverlayShowsShortcutsOnlyByDefault() throws {
    #expect(!CursorSettings().showTypedText)
    let keys = typing("hunter2", at: 1)
        + [InputEvent(t: 3, type: .key, chars: "S", mods: ["⌘"]),
           InputEvent(t: 5, type: .key, chars: "⏎"),
           InputEvent(t: 7, type: .key, chars: "A", mods: ["⇧"])]
    let plan = try keyPlan(keys) { _ in }
    #expect(plan.keystrokeText(at: 1.65) == nil)                 // plain typing: hidden
    #expect(plan.keystrokeText(at: 3.2)?.text == "⌘S")           // a shortcut
    #expect(plan.keystrokeText(at: 5.2)?.text == "⏎")            // a special key
    #expect(plan.keystrokeText(at: 7.2) == nil)                  // Shift alone is typing

    let typed = try keyPlan(keys) { $0.cursor.showTypedText = true }
    #expect(typed.keystrokeText(at: 1.65)?.text == "hunter2")
    #expect(typed.keystrokeText(at: 3.2)?.text == "⌘S")
}

@Test func keystrokeTypedTextChoiceSurvivesOldFiles() throws {
    func cursor(_ json: String) throws -> CursorSettings { try JSONCoding.decoder.decode(CursorSettings.self, from: Data(json.utf8)) }
    // Files from before the setting showed every key whenever the overlay was on: they keep doing so.
    #expect(try cursor(#"{"showKeystrokes": true}"#).showTypedText)
    #expect(try !cursor(#"{"showKeystrokes": false}"#).showTypedText)
    #expect(try !cursor("{}").showTypedText)
    #expect(try !cursor(#"{"showKeystrokes": true, "showTypedText": false}"#).showTypedText)
    var c = CursorSettings()
    c.showKeystrokes = true
    #expect(try JSONCoding.decoder.decode(CursorSettings.self, from: JSONCoding.encoder.encode(c)) == c)
}

@Test func keystrokeOverlayHidesTypingDuringBlurs() throws {
    // A password typed at 1.2–1.7 s while a blur covers the screen from 1 to 2 s, then "ok" after it.
    let keys = typing("secret", at: 1.2) + typing("ok", at: 2.2)
        + [InputEvent(t: 1.55, type: .key, chars: "V", mods: ["⌘"]), InputEvent(t: 4, type: .key, chars: "⏎")]
    let plan = try keyPlan(keys.sorted { $0.t < $1.t }) { e in
        e.cursor.showTypedText = true
        e.annotations = [Annotation(kind: .blur, range: TimeRange(start: 1, end: 2), rect: NormRect(x: 0.2, y: 0.2, width: 0.3, height: 0.1))]
    }
    #expect(plan.keystrokeText(at: 1.45) == nil)                 // typing while the blur is on screen
    #expect(plan.keystrokeText(at: 1.58)?.text == "⌘V")          // shortcuts still show
    #expect(plan.keystrokeText(at: 1.95) == nil)
    #expect(plan.keystrokeText(at: 2.05) == nil)                 // blur gone, but the keys were typed under it
    #expect(plan.keystrokeText(at: 2.4)?.text == "ok")           // typing after it shows, without the earlier keys
    #expect(plan.keystrokeText(at: 4.2)?.text == "⏎")

    // A pixelated blur hides typing just the same; other overlays don't.
    let pixelated = try keyPlan(keys.sorted { $0.t < $1.t }) { e in
        e.cursor.showTypedText = true
        var a = Annotation(kind: .blur, range: TimeRange(start: 1, end: 2), rect: NormRect(x: 0.2, y: 0.2, width: 0.3, height: 0.1))
        a.style = .pixelate
        e.annotations = [a, Annotation(kind: .box, range: TimeRange(start: 2, end: 3), rect: NormRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1))]
    }
    #expect(pixelated.keystrokeText(at: 1.45) == nil)
    #expect(pixelated.keystrokeText(at: 2.4)?.text == "ok")
}
