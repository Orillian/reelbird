import AppKit

/// The main menu. Installed even while the app is menu-bar only, so text fields get ⌘C/⌘V/⌘Z.
@MainActor enum MainMenu {
    static func build(target: AppDelegate, prefs: Preferences) -> NSMenu {
        let main = NSMenu()

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
        let hideOthers = item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit Reelbird", #selector(NSApplication.terminate(_:)), key: "q"))
        add(appMenu, title: "Reelbird", to: main)

        let file = NSMenu(title: "File")
        let rec = item("New Recording…", #selector(AppDelegate.newRecording(_:)), key: prefs.recordHotKey.menuKeyEquivalent, target: target)
        rec.keyEquivalentModifierMask = prefs.recordHotKey.menuModifiers
        file.addItem(rec)
        file.addItem(item("Open…", #selector(AppDelegate.openDocument(_:)), key: "o", target: target))
        let lib = item("Library", #selector(AppDelegate.openLibrary(_:)), key: "l", target: target)
        lib.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(lib)
        file.addItem(.separator())
        file.addItem(item("Close", #selector(NSWindow.performClose(_:)), key: "w"))
        add(file, title: "File", to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), key: "z"))
        let redo = item("Redo", Selector(("redo:")), key: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), key: "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), key: "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), key: "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), key: "a"))
        add(edit, title: "Edit", to: main)

        let window = NSMenu(title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = window
        add(window, title: "Window", to: main)

        let help = NSMenu(title: "Help")
        help.addItem(item("Welcome Tour", #selector(AppDelegate.showOnboarding(_:)), target: target))
        help.addItem(item("Reelbird on GitHub", #selector(AppDelegate.openRepository(_:)), target: target))
        help.addItem(item("Support Reelbird", #selector(AppDelegate.openSupport(_:)), target: target))
        NSApp.helpMenu = help
        add(help, title: "Help", to: main)
        return main
    }

    private static func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
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
