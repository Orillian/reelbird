import AppKit
import ReelbirdCapture
import ReelbirdCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private(set) var model: AppModel!
    private var statusItem: StatusItemController?
    private var pendingOpen: [URL] = []
    /// Logging out or shutting down: quit without questions, but still save a running take.
    private var systemIsPoweringOff = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--mock` simulates the engine; `--synthetic` records generated frames instead of the screen.
        let args = CommandLine.arguments
        let services = args.contains("--mock") ? Services.mock() : Services.live(synthetic: args.contains("--synthetic"))
        model = AppModel(services: services, prefs: Preferences())
        NSApp.mainMenu = MainMenu.build(target: self, prefs: model.prefs)
        model.onHotKeysChanged = { [weak self] in
            guard let self else { return }
            MainMenu.applyHotKeys(self.model.prefs, to: NSApp.mainMenu)
        }
        statusItem = StatusItemController(app: model)
        model.registerHotKeys()
        NSApp.setActivationPolicy(.accessory)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemIsPoweringOff = true }
        }

        model.library.recoverInterruptedRecordings()

        if !pendingOpen.isEmpty {
            pendingOpen.forEach(openURL)
            pendingOpen.removeAll()
        } else if !model.prefs.onboardingDone {
            model.showOnboarding()
        } else if !Self.launchedAtLogin {
            // Opened on purpose (Finder, Dock, Spotlight): go straight to a new recording, as other
            // recorders do. A login-item launch stays quietly in the menu bar.
            model.newRecording()
        }
    }

    /// Whether macOS started the app as a login item rather than the person opening it.
    private static var launchedAtLogin: Bool {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == AEEventID(kAEOpenApplication),
           event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            return true
        }
        // Login items registered with SMAppService don't always carry that flag; right after login is a safe guess.
        return ProcessInfo.processInfo.systemUptime < 120
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard model != nil else { pendingOpen.append(contentsOf: urls); return }
        urls.forEach(openURL)
    }

    private func openURL(_ url: URL) {
        guard url.pathExtension == ProjectBundle.pathExtension else {
            let alert = NSAlert()
            alert.messageText = "Reelbird can't open “\(url.lastPathComponent)”"
            alert.informativeText = "Reelbird opens its own .reelbird recordings. To edit another video, record it with Reelbird first."
            NSApp.activate()
            alert.runModal()
            return
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        model.open(bundle: ProjectBundle(url: url))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening Reelbird again while it runs: show the recorder (or bring back what's already open).
        if !flag && model.recording.phase == .idle { model.newRecording() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        let rec = model.recording

        if rec.phase == .countdown {
            // Nothing captured yet: drop the empty take, then quit.
            rec.discard { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }

        if rec.phase == .recording || rec.phase == .paused {
            if !systemIsPoweringOff {
                let alert = NSAlert()
                alert.messageText = "Stop recording and quit?"
                alert.informativeText = "Reelbird saves this take to your Library before it quits."
                alert.addButton(withTitle: "Save and Quit")
                alert.addButton(withTitle: "Keep Recording")
                NSApp.activate()
                guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            }
            // Never lose a take: finish the recording before quitting.
            rec.stop(openEditor: false) { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }

        let busy = model.windows.busyEditors
        if !busy.isEmpty && !systemIsPoweringOff {
            let alert = NSAlert()
            alert.messageText = busy.count == 1 ? "An export is still running" : "\(busy.count) exports are still running"
            alert.informativeText = "Quitting stops it. Your recordings and edits are safe; you can export again any time."
            alert.addButton(withTitle: "Keep Working")
            alert.addButton(withTitle: "Quit Anyway")
            alert.buttons.last?.hasDestructiveAction = true
            NSApp.activate()
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
            busy.forEach { $0.model.cancelWork() }
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.windows.saveAllEditors()
    }

    // MARK: App commands

    @objc func newRecording(_ sender: Any?) { model.newRecording() }
    @objc func openLibrary(_ sender: Any?) { model.openLibrary() }
    @objc func openSettings(_ sender: Any?) { model.openSettings() }
    @objc func openPro(_ sender: Any?) { model.openPro() }
    @objc func openPermissions(_ sender: Any?) { model.openSettings(.permissions) }
    @objc func openAbout(_ sender: Any?) { model.openSettings(.about) }
    @objc func showOnboarding(_ sender: Any?) { model.showOnboarding() }
    @objc func openWebsite(_ sender: Any?) {
        if let u = URL(string: ReelbirdInfo.websiteURL) { NSWorkspace.shared.open(u) }
    }
    @objc func openRepository(_ sender: Any?) {
        if let u = URL(string: ReelbirdInfo.repositoryURL) { NSWorkspace.shared.open(u) }
    }
    @objc func reportIssue(_ sender: Any?) {
        if let u = URL(string: ReelbirdInfo.repositoryURL + "/issues/new") { NSWorkspace.shared.open(u) }
    }
    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: ProjectBundle.pathExtension, conformingTo: .package) ?? .package]
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = model.prefs.library.root
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { openURL(url) }
    }
    @objc func openRecentItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openURL(url)
    }

    // MARK: Recording commands

    @objc func toggleRecording(_ sender: Any?) { model.toggleRecordingFromHotKey() }
    @objc func togglePauseRecording(_ sender: Any?) { model.recording.togglePause() }
    @objc func discardRecording(_ sender: Any?) { model.recording.confirmDiscard() }
    @objc func addMarker(_ sender: Any?) { model.recording.addMarker() }

    // MARK: Editor commands (routed to the key editor window)

    private var editor: EditorModel? { model.windows.keyEditor?.model }
    /// The key editor, unless a text field in it (the title) is editing, where ⌘⌫ deletes to the line start.
    private var editorNotEditingText: EditorModel? { NSApp.keyWindow?.firstResponder is NSText ? nil : editor }

    @objc func exportRecording(_ sender: Any?) { editor?.showExport = true }
    @objc func shareRecording(_ sender: Any?) { editor?.showShare = true }
    @objc func trashRecording(_ sender: Any?) {
        if let e = editorNotEditingText { model.moveToTrash(e.bundle) } else if libraryHasSelection { model.moveToTrash(model.library.selectedItems.map(\.bundle)) }
    }
    @objc func revealRecording(_ sender: Any?) {
        if let e = editor { Finder.reveal([e.bundle.url]) } else if libraryHasSelection { model.library.reveal(model.library.selectedItems) }
    }
    @objc func togglePlay(_ sender: Any?) { editor?.togglePlay() }
    @objc func goToStart(_ sender: Any?) { editor?.seek(source: 0) }
    @objc func splitAtPlayhead(_ sender: Any?) { editor?.splitAtPlayhead() }
    @objc func addZoom(_ sender: Any?) { editor?.addZoomAtPlayhead() }
    @objc func addEditorMarker(_ sender: Any?) { editor?.addMarkerAtPlayhead() }
    @objc func addLayout(_ sender: Any?) { editor?.addLayoutAtPlayhead() }
    @objc func addBlur(_ sender: Any?) { editor?.beginOverlayTool(.blur) }
    @objc func deleteSelection(_ sender: Any?) { editor?.deleteSelection() }
    @objc func cleanUp(_ sender: Any?) { editor?.cleanUp() }
    @objc func changeSpeed(_ sender: Any?) { editor?.speedKey() }
    @objc func speedUpTyping(_ sender: Any?) { editor?.applySpeedSuggestions() }
    @objc func toggleKeepFastAudio(_ sender: Any?) { if let e = editor { e.setKeepFastAudio(!e.edit.speed.keepFastAudio) } }
    @objc func zoomTimelineIn(_ sender: Any?) { if let e = editor { e.timelineZoom = min(16, e.timelineZoom * 1.5) } }
    @objc func zoomTimelineOut(_ sender: Any?) { if let e = editor { e.timelineZoom = max(1, e.timelineZoom / 1.5) } }
    @objc func showCommandMenu(_ sender: Any?) {
        guard let e = editor else { return }
        if e.showCommandPalette { CommandMenu.close(e) } else { CommandMenu.open(e) }
    }
    @objc func showKeyboardShortcuts(_ sender: Any?) {
        guard let e = editor else { return }
        e.showCommandPalette = false
        e.showShortcuts.toggle()
    }
    /// Edit ▸ Copy and Paste reach here when no text field took them: in the editor they copy and paste zooms.
    @objc func copy(_ sender: Any?) { editorNotEditingText?.copyZooms() }
    @objc func paste(_ sender: Any?) { editorNotEditingText?.pasteZooms() }
    @objc func showInspectorSection(_ sender: NSMenuItem) {
        let i = sender.tag - MainMenu.Tag.inspectorBase.rawValue
        guard InspectorSection.allCases.indices.contains(i) else { return }
        editor?.section = InspectorSection.allCases[i]
    }

    // MARK: Library commands

    @objc func libraryAsGrid(_ sender: Any?) { model.library.gridLayout = true }
    @objc func libraryAsList(_ sender: Any?) { model.library.gridLayout = false }
    /// Edit ▸ Select All reaches here (end of the responder chain) only when no text field took it.
    @objc func selectAll(_ sender: Any?) {
        if model.windows.libraryIsKey { model.library.selectAll() } else { editorNotEditingText?.selectAllZooms() }
    }

    /// The library is key, has a selection, and isn't editing text (where ⌘⌫ deletes to the line start).
    private var libraryHasSelection: Bool {
        model.windows.libraryIsKey && !model.library.selectedItems.isEmpty && !(NSApp.keyWindow?.firstResponder is NSText)
    }

    // MARK: Menu state

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let model else { return false }
        let rec = model.recording
        let e = editor
        switch item.action {
        case #selector(toggleRecording(_:)):
            item.title = rec.isActive ? "Stop Recording" : "Start Recording"
            return rec.phase != .finishing && rec.phase != .selectingArea
        case #selector(togglePauseRecording(_:)):
            item.title = rec.phase == .paused ? "Resume" : "Pause"
            return rec.phase == .recording || rec.phase == .paused
        case #selector(discardRecording(_:)), #selector(addMarker(_:)):
            return rec.phase == .recording || rec.phase == .paused
        case #selector(exportRecording(_:)):
            return e != nil && !(e?.isBusy ?? true)
        case #selector(shareRecording(_:)):
            item.title = e?.shareInfo == nil ? "Share Link…" : "Copy Link…"
            return e != nil
        case #selector(revealRecording(_:)):
            return e != nil || libraryHasSelection
        case #selector(trashRecording(_:)):
            return editorNotEditingText != nil || libraryHasSelection
        case #selector(selectAll(_:)):
            if let ed = editorNotEditingText { return !ed.edit.zoom.regions.isEmpty }
            return model.windows.libraryIsKey && !model.library.filtered.isEmpty
        case #selector(copy(_:)):
            return editorNotEditingText?.canCopyZooms == true
        case #selector(paste(_:)):
            return editorNotEditingText?.canPasteZooms == true
        case #selector(showCommandMenu(_:)), #selector(showKeyboardShortcuts(_:)):
            return e != nil
        case #selector(goToStart(_:)), #selector(splitAtPlayhead(_:)),
             #selector(addZoom(_:)), #selector(addEditorMarker(_:)), #selector(zoomTimelineIn(_:)), #selector(zoomTimelineOut(_:)),
             #selector(changeSpeed(_:)), #selector(speedUpTyping(_:)), #selector(addBlur(_:)):
            return e != nil
        case #selector(togglePlay(_:)):
            item.title = e?.isPlaying == true ? "Pause" : "Play"
            return e != nil
        case #selector(deleteSelection(_:)):
            guard let sel = e?.selection else { item.title = "Cut Selection"; return false }
            item.title = sel.isCut ? "Restore Cut" : sel.isZoom ? e?.deleteZoomsTitle ?? "Delete Zoom" : sel.isLayout ? "Delete Layout" : sel.isSpeed ? "Remove Speed" : "Cut Selection"
            return true
        case #selector(toggleKeepFastAudio(_:)):
            item.state = e?.edit.speed.keepFastAudio == true ? .on : .off
            return e != nil
        case #selector(addLayout(_:)):
            return e?.hasCamera == true
        case #selector(cleanUp(_:)):
            return e?.canCleanUp == true
        case #selector(showInspectorSection(_:)):
            let i = item.tag - MainMenu.Tag.inspectorBase.rawValue
            item.state = e != nil && InspectorSection.allCases.indices.contains(i) && e?.section == InspectorSection.allCases[i] ? .on : .off
            return e != nil
        case #selector(libraryAsGrid(_:)):
            item.state = model.library.gridLayout ? .on : .off
            return model.windows.libraryIsKey
        case #selector(libraryAsList(_:)):
            item.state = model.library.gridLayout ? .off : .on
            return model.windows.libraryIsKey
        default:
            return true
        }
    }

    /// Fills File ▸ Open Recent from the library, newest first.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Open Recent" else { return }
        menu.removeAllItems()
        model.library.reloadIfStale()
        let items = model.library.items.prefix(10)
        if items.isEmpty {
            let none = NSMenuItem(title: "No Recordings Yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        for r in items {
            let i = NSMenuItem(title: r.title, action: #selector(openRecentItem(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = r.bundle.url
            menu.addItem(i)
        }
    }
}
