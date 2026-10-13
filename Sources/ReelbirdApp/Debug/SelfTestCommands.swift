import AppKit
import ReelbirdCore

/// Self test of the command registry, the command menu, the shortcut sheet and zoom handling
/// (`ReelbirdApp --selftest`).
extension SelfTest {
    /// A key-down event as the editor's key handler would see it.
    private static func key(_ chars: String, code: UInt16 = 0, _ mods: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
    }

    private static func rowsFor(_ commands: [EditorCommand]) -> [(id: String, title: String, keycaps: [String])] {
        EditorCommands.sheet(commands).flatMap(\.rows)
    }

    static func commandRegistry(editor: EditorModel, prefs: Preferences, check: (Bool, String) -> Void) {
        let commands = EditorCommands.all(model: editor, app: nil)
        check(commands.count > 60, "the registry lists every editor command (\(commands.count))")
        check(commands.allSatisfy { !$0.id.isEmpty && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty && !$0.symbol.isEmpty },
              "every command has an id, a title and a symbol")
        check(Set(commands.map(\.id)).count == commands.count, "command ids are unique")
        var seen: [KeyShortcut: String] = [:]
        var clashes: [String] = []
        for c in commands {
            guard let s = c.shortcut else { continue }
            if let other = seen[s] { clashes.append("\(s.display): \(other) / \(c.id)") } else { seen[s] = c.id }
        }
        check(clashes.isEmpty, "no two commands share a shortcut \(clashes)")
        // Every command runs from the palette: an action of the right type is the registry's contract; spot-run a few.
        let motionBlur = editor.edit.background.motionBlur
        commands.first { $0.id == "motion-blur" }?.action()
        check(editor.edit.background.motionBlur != motionBlur, "a toggle command switches its setting")
        commands.first { $0.id == "panel-audio" }?.action()
        check(editor.section == .audio, "a panel command shows its inspector panel")
        EditorCommands.all(model: editor, app: nil).first { $0.id == "motion-blur" }?.action()
        check(editor.edit.background.motionBlur == motionBlur, "and switches it back")

        // Menus and the registry agree: every ⌘ shortcut the menus own is a menu item with that key.
        let menu = MainMenu.build(target: AppDelegate(), prefs: prefs)
        var menuKeys: Set<KeyShortcut> = []
        func walk(_ m: NSMenu) {
            for item in m.items {
                if let sub = item.submenu { walk(sub) }
                guard !item.keyEquivalent.isEmpty else { continue }
                if let s = commands.compactMap(\.shortcut).first(where: {
                    $0.menuKeyEquivalent == item.keyEquivalent && $0.menuModifierMask == item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
                }) { menuKeys.insert(s) }
            }
        }
        walk(menu)
        let missing = commands.filter { c in
            guard let s = c.shortcut, s.usesMenuModifiers, !c.takesMenuKey, c.id != "library", c.id != "trash" else { return false }
            return !menuKeys.contains(s)
        }
        check(missing.isEmpty, "every ⌘ shortcut in the registry is in the menus \(missing.map(\.id))")
        let timeline = menu.item(withTitle: "Timeline")?.submenu?.items.filter { !$0.keyEquivalent.isEmpty && $0.keyEquivalentModifierMask.isEmpty } ?? []
        check(!timeline.isEmpty && timeline.allSatisfy { item in
            commands.contains { $0.shortcut?.menuKeyEquivalent == item.keyEquivalent && $0.shortcut?.modifiers.isEmpty == true }
        }, "the Timeline menu's single keys come from the registry")
        check(menu.item(withTitle: "Help")?.submenu?.item(withTitle: "Keyboard Shortcuts")?.keyEquivalent == "/", "Help has Keyboard Shortcuts (⌘/)")

        // Key events find their command.
        func cmd(_ e: NSEvent?) -> String? { e.flatMap { EditorCommands.command(for: $0, in: EditorCommands.all(model: editor, app: nil))?.id } }
        check(cmd(key("s")) == "split" && cmd(key("z")) == "add-zoom" && cmd(key("c")) == "add-layout" && cmd(key(" ", code: 49)) == "play",
              "plain keys run their commands")
        check(cmd(key("m")) == "add-marker", "M adds a marker from the registry")
        check(rowsFor(commands).contains { $0.id == "hotkey-layout" && $0.keycaps == ["⌥", "⇧", "L"] }
              && rowsFor(commands).contains { $0.id == "hotkey-marker" && $0.keycaps == ["⌥", "⇧", "M"] },
              "the sheet lists the recording shortcuts, ⌥⇧L and ⌥⇧M included")
        check(cmd(key("3")) == "zoom-depth-3" && cmd(key("0")) == "zoom-on-off" && cmd(key("i")) == "zoom-instant", "0–9 and I are zoom keys")
        check(cmd(key(String(UnicodeScalar(NSLeftArrowFunctionKey)!), code: 123, .shift)) == "second-back"
              && cmd(key("\u{7f}", code: 51)) == "delete-selection", "arrows and delete")
        editor.selection = nil
        check(cmd(key("c", .command)) == nil, "⌘C keeps its usual meaning with no zoom selected")
        check(cmd(key("e", .command)) == nil, "⌘E is left to the menus")

        // The shortcut sheet comes from the same registry.
        let sheet = EditorCommands.sheet(commands)
        let rows = sheet.flatMap(\.rows)
        check(sheet.map(\.area).first == .playback && rows.contains { $0.title == "Split at Playhead" && $0.keycaps == ["S"] },
              "the shortcut sheet lists the editor's keys by area")
        check(rows.filter { $0.id == "zoom-depth" }.count == 1 && !rows.contains { $0.id.hasPrefix("zoom-depth-") },
              "the 0–9 depth keys are one row in the sheet")
        check(ShortcutSheetView.columns(sheet, count: 3).allSatisfy { !$0.isEmpty }, "the sheet fills three columns")
    }

    static func commandMenu(editor: EditorModel, check: (Bool, String) -> Void) async {
        CommandHistory.setForSnapshot([])
        CommandMenu.open(editor)
        check(editor.showCommandPalette && editor.paletteHighlight == 0, "⌘K opens the command menu")
        var sections = CommandMenu.sections(model: editor, app: nil)
        check(sections.first?.title == "Playback" && !CommandMenu.flat(sections).contains { $0.id == "command-menu" },
              "with no search, commands are grouped by area")
        check(!CommandMenu.flat(sections).contains { !$0.isEnabled }, "only commands that can run are listed")
        editor.paletteQuery = "exp gif"
        check(CommandMenu.flat(CommandMenu.sections(model: editor, app: nil)).first?.id == "export-gif", "search finds Export as GIF")
        editor.paletteQuery = "motion blur"
        let blur = editor.edit.background.motionBlur
        CommandMenu.runHighlighted(model: editor, app: nil)
        check(!editor.showCommandPalette, "Return closes the menu")
        try? await Task.sleep(for: .milliseconds(30))
        check(editor.edit.background.motionBlur != blur, "and runs the highlighted command")
        check(CommandHistory.recent.first == "motion-blur", "the command is remembered")
        CommandMenu.open(editor)
        sections = CommandMenu.sections(model: editor, app: nil)
        check(sections.first?.title == "Recent" && sections.first?.commands.first?.id == "motion-blur", "recent commands come first")
        editor.paletteQuery = "pl"
        let n = CommandMenu.flat(CommandMenu.sections(model: editor, app: nil)).count
        CommandMenu.move(1, model: editor, app: nil)
        CommandMenu.move(1, model: editor, app: nil)
        check(editor.paletteHighlight == min(2, n - 1), "arrow keys move the highlight")
        CommandMenu.move(-10, model: editor, app: nil)
        check(editor.paletteHighlight == 0, "and stay on the list")
        CommandMenu.close(editor)
        editor.undoManager.undo()
        check(editor.edit.background.motionBlur == blur, "a command from the menu undoes")
        CommandHistory.setForSnapshot([])

        editor.pendingExportFormat = nil
        EditorCommands.all(model: editor, app: nil).first { $0.id == "export-gif" }?.action()
        check(editor.showExport && editor.pendingExportFormat == .gif, "Export as GIF opens the export sheet on GIF")
        editor.showExport = false
        editor.pendingExportFormat = nil
    }

    static func zoomHandling(editor: EditorModel, check: (Bool, String) -> Void) async {
        func nextEvent() async { try? await Task.sleep(for: .milliseconds(20)) }
        let d = editor.duration
        let ids = ["t1", "t2", "t3"]
        editor.change("x") { e in
            e.zoom.mode = .manual
            e.zoom.regions = zip(ids, [(0.1, 0.25), (0.35, 0.5), (0.7, 0.85)]).map { id, r in
                ZoomRegion(id: id, range: TimeRange(start: r.0 * d, end: r.1 * d), scale: 1.8, focus: .center)
            }
        }
        await nextEvent()
        editor.clickZoom(ids[0], extend: false)
        editor.clickZoom(ids[2], extend: true)
        check(editor.selection == .zooms([ids[0], ids[2]]), "shift-click selects several zooms")
        editor.clickZoom(ids[2], extend: true)
        check(editor.selection == .zoom(ids[0]), "shift-click again takes one out")
        editor.clickZoom(ids[2], extend: true)

        // Depth keys on the selection, one undo step.
        editor.zoomDigit(4)
        await nextEvent()
        check(editor.zooms([ids[0], ids[2]]).allSatisfy { $0.scale == 2 } && editor.zooms([ids[1]])[0].scale == 1.8, "4 sets 2× on the selected zooms")
        editor.undoManager.undo()
        check(editor.edit.zoom.regions.allSatisfy { $0.scale == 1.8 }, "depth keys undo in one step")
        // 0 turns off, again turns on; the hovered zoom wins when it isn't selected.
        editor.zoomDigit(0)
        await nextEvent()
        check(editor.zooms([ids[0], ids[2]]).allSatisfy { !$0.enabled }, "0 turns the zooms off")
        check(editor.edit.zoom.regions.count == 3, "a zoom turned off stays in the edit")
        editor.hoveredZoomID = ids[1]
        check(editor.zoomKeyTargets == [ids[1]], "keys act on the zoom under the pointer")
        editor.zoomDigit(9)
        await nextEvent()
        check(editor.zooms([ids[1]])[0].scale == ZoomEditing.maxDepth, "9 is the deepest")
        editor.hoveredZoomID = nil
        editor.zoomDigit(0)
        await nextEvent()
        check(editor.zooms([ids[0], ids[2]]).allSatisfy(\.enabled), "0 again turns them back on")
        editor.toggleZoomsInstant(editor.zoomKeyTargets)
        await nextEvent()
        check(editor.zooms([ids[0], ids[2]]).allSatisfy(\.instant), "I makes them instant")
        editor.undoManager.undo()
        check(editor.zooms([ids[0], ids[2]]).allSatisfy { !$0.instant }, "instant undoes")

        // Copy and paste at the playhead.
        editor.copyZooms()
        check(ZoomClipboard.zooms.count == 2 && editor.canPasteZooms, "⌘C copies the selected zooms")
        editor.seek(source: 0.05 * d)
        editor.pasteZooms()
        await nextEvent()
        check(editor.edit.zoom.regions.count == 5 && editor.selectedZoomIDs.count == 2 && !editor.selectedZoomIDs.contains(ids[0]),
              "⌘V pastes them at the playhead and selects them")
        let pasted = editor.selectedZooms
        check(abs((pasted.first?.range.start ?? 0) - editor.playhead) < 0.01, "the first pasted zoom starts at the playhead")
        editor.undoManager.undo()
        check(editor.edit.zoom.regions.count == 3 && editor.selection == nil, "paste undoes in one step")

        // Box select and delete together.
        editor.boxSelectZooms(TimeRange(start: 0.15 * d, end: 0.5 * d), adding: [])
        check(editor.selectedZoomIDs == [ids[0], ids[1]] && editor.zoomMarquee != nil, "a box on the zoom lane selects the zooms it touches")
        editor.endZoomMarquee()
        check(editor.zoomMarquee == nil && editor.deleteZoomsTitle == "Delete 2 Zooms", "the box ends; delete names the count")
        editor.deleteSelection()
        await nextEvent()
        check(editor.edit.zoom.regions.map(\.id) == [ids[2]], "delete removes every selected zoom")
        editor.undoManager.undo()
        check(editor.edit.zoom.regions.count == 3, "and undoes in one step")
        editor.selectAllZooms()
        check(editor.selectedZoomIDs.count == 3, "Select All selects every zoom")
        editor.selection = nil

        // An automatic zoom turned off stays off when automatic zooms are planned again.
        editor.change("x") { $0.zoom.mode = .manual; $0.zoom.regions = [] }
        await nextEvent()
        editor.setZoomMode(.auto)
        await nextEvent()
        if let auto = editor.edit.zoom.regions.first(where: { $0.source == .auto }) {
            editor.toggleZoomsEnabled([auto.id])
            await nextEvent()
            editor.setZoomIntensity(0.9)
            await nextEvent()
            check(editor.edit.zoom.regions.contains { $0.id == auto.id && !$0.enabled && $0.source == .user },
                  "an automatic zoom turned off survives replanning")
        } else {
            check(false, "auto zooms planned")
        }
        editor.change("x") { $0.zoom.mode = .auto; $0.zoom.regions = [] }
        editor.resetAutoZooms()
        await nextEvent()
    }
}
