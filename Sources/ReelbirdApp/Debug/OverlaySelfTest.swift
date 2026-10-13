import AppKit
import ReelbirdCore

/// Overlay checks for `--selftest` (mock engine) and `--selftest-live` (real preview player and scanner).
@MainActor enum OverlaySelfTest {
    private static func nextEvent() async { try? await Task.sleep(for: .milliseconds(20)) }

    /// Adding, editing, undo and redo of overlays, the tool and Esc, and Find Sensitive Info's Keep / Keep All.
    static func run(editor: EditorModel, check: (Bool, String) -> Void) async {
        let start = editor.edit.annotations
        let commands = EditorCommands.all(model: editor, app: nil)
        check(commands.first { $0.id == "add-blur" }?.shortcut == EditorKeys.addBlur
              && Annotation.Kind.toolOrder.allSatisfy { k in commands.contains { $0.id == "add-\(k.rawValue)" && $0.area == .overlays } }
              && commands.contains { $0.id == "find-sensitive-info" }, "overlays: the tools and Find Sensitive Info are in the command registry")
        editor.seek(source: 1)
        editor.beginOverlayTool(.blur)
        check(editor.overlays.tool == .blur && editor.section == .overlays, "overlays: B arms the blur tool and opens Overlays")
        editor.escape()
        check(editor.overlays.tool == nil, "overlays: Esc drops the tool")
        editor.beginOverlayTool(.blur)
        let id = editor.addAnnotation(.blur, rect: NormRect(x: 0.2, y: 0.2, width: 0.3, height: 0.1))
        await nextEvent()
        guard let blur = editor.edit.annotations.first(where: { $0.id == id }) else { check(false, "overlays: blur added"); return }
        let length = min(5, editor.duration)
        check(editor.selection == .annotation(id) && editor.overlays.tool == nil
              && abs(blur.range.start - max(0, min(editor.playhead, editor.duration - length))) < 1e-9,
              "overlays: a drawn blur is added at the playhead and selected")
        check(blur.kind == .blur && blur.blurStyle == .blur && abs(blur.range.duration - length) < 1e-9, "overlays: a blur lasts 5 s by default")
        for i in 1...5 {
            editor.updateAnnotation(id, "Move Overlay", coalesce: "move") { $0.setRect(NormRect(x: 0.2 + Double(i) * 0.02, y: 0.2, width: 0.3, height: 0.1)) }
        }
        func x() -> Double { editor.selectedAnnotation?.rect.x ?? -1 }
        check(abs(x() - 0.3) < 1e-9, "overlays: a drag moves the blur")
        await nextEvent()
        editor.undoManager.undo()
        check(abs(x() - 0.2) < 1e-9, "overlays: a drag undoes in one step")
        editor.undoManager.redo()
        check(abs(x() - 0.3) < 1e-9, "overlays: and redoes")
        await nextEvent()
        editor.updateAnnotation(id, "Blur Style", coalesce: "style") { $0.style = .pixelate; $0.strength = 0.9 }
        check(editor.selectedAnnotation?.blurStyle == .pixelate && editor.selectedAnnotation?.blurStrength == 0.9, "overlays: pixelate and strength")
        editor.updateAnnotation(id, "Trim Overlay", coalesce: "end") { $0.range.end = editor.duration + 50 }
        check(editor.selectedAnnotation?.range.end == editor.duration, "overlays: trimming stops at the end of the recording")

        // Text: the box follows the label.
        let tid = editor.addAnnotation(.text, rect: NormRect(x: 0.5, y: 0.5, width: 0.01, height: 0))
        await nextEvent()
        let w0 = editor.selectedAnnotation?.rect.width ?? 0
        editor.updateAnnotation(tid, "Edit Text", coalesce: "text") { $0.text = "A much longer label" }
        let w1 = editor.selectedAnnotation?.rect.width ?? 0
        check(w0 > 0 && w1 > w0 * 2 && editor.overlays.focusTextID == tid, "overlays: text labels size to their text (\(String(format: "%.3f → %.3f", w0, w1)))")
        editor.updateAnnotation(tid, "Text Size", coalesce: "size") { $0.fontSize = 0.05 }
        check((editor.selectedAnnotation?.rect.height ?? 0) > 0.05, "overlays: text size grows the label")

        // Arrow ends, colours, delete with undo.
        let aid = editor.addAnnotation(.arrow, rect: .full, tail: NormPoint(x: 0.8, y: 0.8), head: NormPoint(x: 0.6, y: 0.5))
        let arrow = editor.edit.annotations.first { $0.id == aid }
        check(arrow?.arrowEnds.head == NormPoint(x: 0.6, y: 0.5) && arrow?.color == Annotation.defaultColor, "overlays: arrows point from tail to head, coral by default")
        await nextEvent()
        editor.updateAnnotation(aid, "Overlay Colour", coalesce: "color") { $0.color = Annotation.palette[2].color }
        await nextEvent()
        editor.deleteSelection()
        await nextEvent()
        check(!editor.edit.annotations.contains { $0.id == aid } && editor.selection == nil, "overlays: Delete removes the selected overlay")
        editor.undoManager.undo()
        check(editor.edit.annotations.first { $0.id == aid }?.color == Annotation.palette[2].color, "overlays: undo brings it back")

        // Find Sensitive Info (mock findings).
        editor.findSensitiveInfo()
        for _ in 0..<100 where editor.overlays.isScanning { try? await Task.sleep(for: .milliseconds(20)) }
        check(editor.overlays.scanned && editor.overlays.suggestions.count == 3, "overlays: Find Sensitive Info suggests three findings")
        let first = editor.overlays.suggestions[0].id
        editor.keepSuggestion(first)
        await nextEvent()
        let kept = editor.edit.annotations.first { $0.id == first }
        check(kept?.kind == .blur && kept?.detected == "email" && editor.overlays.suggestions.count == 2, "overlays: Keep adds a blur for the finding")
        let before = editor.edit.annotations.count
        editor.keepAllSuggestions()
        await nextEvent()
        check(editor.edit.annotations.count == before + 2 && editor.overlays.suggestions.isEmpty, "overlays: Keep All blurs the rest")
        editor.undoManager.undo()
        check(editor.edit.annotations.count == before, "overlays: Keep All undoes in one step")
        editor.findSensitiveInfo()
        for _ in 0..<100 where editor.overlays.isScanning { try? await Task.sleep(for: .milliseconds(20)) }
        check(!editor.overlays.suggestions.contains { $0.id == first }, "overlays: a kept finding isn't suggested again")
        editor.dismissAllSuggestions()

        // Leave the document as it was.
        editor.change("x") { $0.annotations = start }
        editor.selection = nil
    }

    /// The real preview player places overlays and the real scanner runs on the synthetic take.
    static func runLive(editor: EditorModel, check: (Bool, String) -> Void) async {
        if let m = editor.player?.screenMapping(atSource: 1, width: 1280, height: 720) {
            let r = m.rect(NormRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
            check(r.minX > 0 && r.maxX < 1280 && r.minY > 0 && r.maxY < 720, "overlays: the live player maps screen to canvas (\(Int(r.minX)),\(Int(r.minY)))")
            let back = m.screenRect(r)
            check(abs(back.x - 0.25) < 1e-9 && abs(back.width - 0.5) < 1e-9, "overlays: and back")
        } else {
            check(false, "overlays: the live player gives a screen mapping")
        }
        editor.findSensitiveInfo()
        let started = Date()
        while editor.overlays.isScanning, Date().timeIntervalSince(started) < 120 { try? await Task.sleep(for: .milliseconds(50)) }
        print("  …    scan took \(String(format: "%.1f", Date().timeIntervalSince(started))) s, scanning \(editor.overlays.isScanning)")
        check(editor.overlays.scanned && editor.overlays.scanError == nil,
              "overlays: Find Sensitive Info scans the take on this Mac (\(editor.overlays.suggestions.count) findings\(editor.overlays.scanError.map { "; \($0)" } ?? ""))")
    }
}
