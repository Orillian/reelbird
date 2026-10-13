import AppKit

/// The main menu. Installed even while the app is menu-bar only, so text fields get ⌘C/⌘V/⌘Z.
/// Editor and library commands target the app delegate, which routes them to the key window
/// and enables them only when they apply (`AppDelegate.validateMenuItem`).
@MainActor enum MainMenu {
    /// Tags for items whose title or state changes with context.
    enum Tag: Int {
        case openRecent = 100, recordToggle, pauseToggle, discard, gridLayout, listLayout, playPause
        case inspectorBase = 200 // + section index
    }

    static func build(target: AppDelegate, prefs: Preferences) -> NSMenu {
        let main = NSMenu()

        // Reelbird
        let appMenu = NSMenu()
        appMenu.addItem(item("About Reelbird", #selector(AppDelegate.openAbout(_:)), target: target))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(AppDelegate.openSettings(_:)), key: ",", target: target))
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide Reelbird", #selector(NSApplication.hide(_:)), key: "h"))
        appMenu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h", mods: [.command, .option]))
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit Reelbird", #selector(NSApplication.terminate(_:)), key: "q"))
        add(appMenu, title: "Reelbird", to: main)

        // File
        let file = NSMenu(title: "File")
        file.addItem(item("New Recording…", #selector(AppDelegate.newRecording(_:)), key: "n", target: target))
        file.addItem(item("Open…", #selector(AppDelegate.openDocument(_:)), key: "o", target: target))
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recent.tag = Tag.openRecent.rawValue
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = target
        recent.submenu = recentMenu
        file.addItem(recent)
        file.addItem(item("Library", #selector(AppDelegate.openLibrary(_:)), key: "l", mods: [.command, .shift], target: target))
        file.addItem(.separator())
        file.addItem(item("Close", #selector(NSWindow.performClose(_:)), key: "w"))
        file.addItem(.separator())
        file.addItem(item("Export…", #selector(AppDelegate.exportRecording(_:)), key: "e", target: target))
        file.addItem(item("Share Link…", #selector(AppDelegate.shareRecording(_:)), key: "e", mods: [.command, .shift], target: target))
        file.addItem(item("Show in Finder", #selector(AppDelegate.revealRecording(_:)), key: "r", mods: [.command, .shift], target: target))
        file.addItem(.separator())
        file.addItem(item("Move to Trash…", #selector(AppDelegate.trashRecording(_:)), key: "\u{8}", target: target))
        add(file, title: "File", to: main)

        // Edit
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), key: "z"))
        edit.addItem(item("Redo", Selector(("redo:")), key: "z", mods: [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), key: "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), key: "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), key: "v"))
        edit.addItem(item("Delete", #selector(NSText.delete(_:))))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), key: "a"))
        add(edit, title: "Edit", to: main)

        // Timeline: the editor's single-key shortcuts, shown in the menu but handled by the editor
        // (TimelineMenuDelegate), so typing a title never splits the clip.
        let timeline = NSMenu(title: "Timeline")
        timeline.delegate = timelineDelegate
        timelineDelegate.target = target
        let play = item("Play", #selector(AppDelegate.togglePlay(_:)), key: " ", mods: [], target: target)
        play.tag = Tag.playPause.rawValue
        timeline.addItem(play)
        timeline.addItem(item("Go to Start", #selector(AppDelegate.goToStart(_:)), key: String(UnicodeScalar(NSHomeFunctionKey)!), mods: [], target: target))
        timeline.addItem(.separator())
        timeline.addItem(item("Split at Playhead", #selector(AppDelegate.splitAtPlayhead(_:)), key: "s", mods: [], target: target))
        timeline.addItem(item("Add Zoom at Playhead", #selector(AppDelegate.addZoom(_:)), key: "z", mods: [], target: target))
        timeline.addItem(item("Cut Selection", #selector(AppDelegate.deleteSelection(_:)), key: "\u{8}", mods: [], target: target))
        timeline.addItem(item("Cut Long Silences", #selector(AppDelegate.removeSilences(_:)), target: target))
        timeline.addItem(.separator())
        timeline.addItem(item("Zoom In Timeline", #selector(AppDelegate.zoomTimelineIn(_:)), key: "=", target: target))
        timeline.addItem(item("Zoom Out Timeline", #selector(AppDelegate.zoomTimelineOut(_:)), key: "-", target: target))
        add(timeline, title: "Timeline", to: main)

        // View
        let view = NSMenu(title: "View")
        for (i, s) in InspectorSection.allCases.enumerated() {
            let it = item(s.title, #selector(AppDelegate.showInspectorSection(_:)), key: "\(i + 1)", target: target)
            it.tag = Tag.inspectorBase.rawValue + i
            view.addItem(it)
        }
        view.addItem(.separator())
        let grid = item("as Grid", #selector(AppDelegate.libraryAsGrid(_:)), key: "1", mods: [.command, .control], target: target)
        grid.tag = Tag.gridLayout.rawValue
        view.addItem(grid)
        let list = item("as List", #selector(AppDelegate.libraryAsList(_:)), key: "2", mods: [.command, .control], target: target)
        list.tag = Tag.listLayout.rawValue
        view.addItem(list)
        view.addItem(.separator())
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), key: "f", mods: [.command, .control]))
        add(view, title: "View", to: main)

        // Recording
        let record = NSMenu(title: "Recording")
        let toggle = item("Start Recording", #selector(AppDelegate.toggleRecording(_:)), target: target)
        toggle.tag = Tag.recordToggle.rawValue
        record.addItem(toggle)
        let pause = item("Pause", #selector(AppDelegate.togglePauseRecording(_:)), target: target)
        pause.tag = Tag.pauseToggle.rawValue
        record.addItem(pause)
        let discard = item("Discard Recording…", #selector(AppDelegate.discardRecording(_:)), target: target)
        discard.tag = Tag.discard.rawValue
        record.addItem(discard)
        record.addItem(.separator())
        record.addItem(item("Permissions…", #selector(AppDelegate.openPermissions(_:)), target: target))
        add(record, title: "Recording", to: main)
        applyHotKeys(prefs, to: main)

        // Window
        let window = NSMenu(title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item("Library", #selector(AppDelegate.openLibrary(_:)), target: target))
        window.addItem(.separator())
        window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = window
        add(window, title: "Window", to: main)

        // Help
        let help = NSMenu(title: "Help")
        help.addItem(item("Welcome Tour", #selector(AppDelegate.showOnboarding(_:)), target: target))
        help.addItem(item("Reelbird on GitHub", #selector(AppDelegate.openRepository(_:)), target: target))
        help.addItem(item("Report a Problem…", #selector(AppDelegate.reportIssue(_:)), target: target))
        help.addItem(.separator())
        help.addItem(item("Support Reelbird", #selector(AppDelegate.openSupport(_:)), target: target))
        NSApp.helpMenu = help
        add(help, title: "Help", to: main)
        return main
    }

    /// Shows the global shortcuts next to the Recording items (Carbon hot keys fire first, so
    /// these never double-trigger). Called again when the user changes a shortcut.
    static func applyHotKeys(_ prefs: Preferences, to main: NSMenu?) {
        guard let record = main?.item(withTitle: "Recording")?.submenu else { return }
        if let t = record.item(withTag: Tag.recordToggle.rawValue) {
            t.keyEquivalent = prefs.recordHotKey.menuKeyEquivalent
            t.keyEquivalentModifierMask = prefs.recordHotKey.menuModifiers
        }
        if let p = record.item(withTag: Tag.pauseToggle.rawValue) {
            p.keyEquivalent = prefs.pauseHotKey.menuKeyEquivalent
            p.keyEquivalentModifierMask = prefs.pauseHotKey.menuModifiers
        }
    }

    private static let timelineDelegate = TimelineMenuDelegate()

    private static func item(_ title: String, _ action: Selector, key: String = "", mods: NSEvent.ModifierFlags = [.command],
                             target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { i.keyEquivalentModifierMask = mods }
        i.target = target
        return i
    }

    private static func add(_ menu: NSMenu, title: String, to main: NSMenu) {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        i.submenu = menu
        main.addItem(i)
    }
}

/// Lets the Timeline menu display single-key shortcuts without matching them: plain keys go to the
/// editor's key handler (which ignores them while a text field is editing). Only the ⌘ shortcuts
/// in this menu match as usual.
@MainActor final class TimelineMenuDelegate: NSObject, NSMenuDelegate {
    weak var target: AppDelegate?

    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                              action: UnsafeMutablePointer<Selector?>) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]) == .command,
              let chars = event.charactersIgnoringModifiers,
              let item = menu.items.first(where: { $0.keyEquivalentModifierMask == .command && $0.keyEquivalent == chars && !$0.keyEquivalent.isEmpty }),
              self.target?.validateMenuItem(item) == true else { return false }
        target.pointee = item.target
        action.pointee = item.action
        return true
    }
}
