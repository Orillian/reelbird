import AppKit
import ReelbirdCore
import SwiftUI

/// Window for one recording. Owns the editor model and routes keyboard shortcuts.
@MainActor final class EditorWindowController: NSWindowController {
    let model: EditorModel
    private unowned let app: AppModel
    private var keyMonitor: Any?

    init(bundle: ProjectBundle, app: AppModel) throws {
        self.app = app
        // A take still being recorded (here or by the CLI) must not be recovered under its recorder.
        let manifest = try? bundle.readManifest()
        if bundle.url.standardizedFileURL == app.recording.activeBundle?.standardizedFileURL
            || manifest.map({ bundle.isBeingRecorded($0) }) == true {
            throw StillRecording()
        }
        // Recovery (consolidating a long take) runs off the main thread before this (WindowManager.openEditor).
        var cursor = CursorSettings()
        cursor.visible = app.prefs.showCursorDefault
        cursor.clickEffect = app.prefs.clickEffectDefault
        model = try EditorModel(bundle: bundle, services: app.services, cursorDefaults: cursor)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 840),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = model.title
        w.representedURL = bundle.url
        w.contentMinSize = NSSize(width: 980, height: 640)
        w.isReleasedWhenClosed = false
        w.tabbingMode = .preferred
        w.backgroundColor = .rbPanel
        super.init(window: w)
        w.contentView = NSHostingView(rootView: EditorView(model: model, app: app).environment(app))
        w.center()
        w.setFrameAutosaveName("EditorWindow")
        model.attachPlayer()
        installKeyMonitor()
    }

    required init?(coder: NSCoder) { fatalError() }

    func willClose() {
        // Closing without the "still exporting" question (Move to Trash closes the editor directly)
        // must not leave an export or upload running for a window that's gone.
        model.cancelWork()
        model.pause()
        model.stopWatchingEdits()
        model.saveNow()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// The editor's keys while no text field is editing: plain keys (space, J/K/L, S, Z, C, M, R, 0–9, arrows, delete…)
    /// run their command from the registry (`EditorCommands`), and ⌘C, ⌘V, ⌘A act on zooms when they can.
    /// Other ⌘ shortcuts live in the menus. The Timeline menu lists single keys without matching them
    /// (TimelineMenuDelegate). While the command menu is open, the arrows, Return and Esc drive it.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let w = self.window, w.isKeyWindow, w.attachedSheet == nil else { return event }
            let model = self.model
            let mods = event.modifierFlags.intersection([.command, .option, .control])
            if model.showCommandPalette {
                guard mods.isEmpty else { return event }
                switch event.keyCode {
                case 126: CommandMenu.move(-1, model: model, app: self.app); return nil   // up
                case 125: CommandMenu.move(1, model: model, app: self.app); return nil    // down
                case 36, 76: CommandMenu.runHighlighted(model: model, app: self.app); return nil
                case 53: CommandMenu.close(model); return nil
                default: return event                                                    // typing goes to the search field
                }
            }
            if w.firstResponder is NSTextView { return event }
            if model.showShortcuts, mods.isEmpty, event.keyCode == 53 { model.showShortcuts = false; return nil }
            if model.isCropping {
                guard mods.isEmpty else { return event }
                // Crop mode: Return keeps the crop, Esc cancels; editing keys wait until it's done.
                switch event.keyCode {
                case 36, 76: model.commitCrop(); return nil
                case 53: model.cancelCrop(); return nil
                case 49: model.togglePlay(); return nil
                default: return ["s", "z", "c", "m", "r", "b", "a", "x", "t", "h"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") || [51, 117].contains(event.keyCode) ? nil : event
                }
            }
            let commands = EditorCommands.all(model: model, app: self.app)
            guard let command = EditorCommands.command(for: event, in: commands) else { return event }
            if command.isEnabled { command.action() }
            return nil
        }
    }
}

/// Opening a recording that is still being written.
struct StillRecording: LocalizedError {
    var errorDescription: String? { "This recording is still in progress. Stop it first, then open it." }
}
