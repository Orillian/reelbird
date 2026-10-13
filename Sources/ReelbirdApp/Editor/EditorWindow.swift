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
        if try app.services.recorder.recoverIfNeeded(bundle) { app.library.reload() }
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
        model.saveNow()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Single-key shortcuts (space, J/K/L, S, Z, arrows, delete) while no text field is editing.
    /// The Timeline menu lists them without matching them (TimelineMenuDelegate).
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let w = self.window, w.isKeyWindow, w.attachedSheet == nil else { return event }
            if w.firstResponder is NSTextView { return event }
            // ⌘ shortcuts live in the menus (File, Timeline, View); this handles the single keys.
            let mods = event.modifierFlags.intersection([.command, .option, .control])
            guard mods.isEmpty else { return event }
            if self.model.isCropping {
                // Crop mode: Return keeps the crop, Esc cancels; editing keys wait until it's done.
                switch event.keyCode {
                case 36, 76: self.model.commitCrop(); return nil
                case 53: self.model.cancelCrop(); return nil
                case 49: self.model.togglePlay(); return nil
                default: return ["s", "z"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") || [51, 117].contains(event.keyCode) ? nil : event
                }
            }
            switch event.keyCode {
            case 49: self.model.togglePlay(); return nil              // space
            case 123: self.model.step(event.modifierFlags.contains(.shift) ? -1 : -1.0 / 30); return nil
            case 124: self.model.step(event.modifierFlags.contains(.shift) ? 1 : 1.0 / 30); return nil
            case 51, 117: self.model.deleteSelection(); return nil     // delete, forward delete
            case 53: self.model.selection = nil; return nil            // esc
            case 115: self.model.seek(source: 0); return nil           // home
            case 119: self.model.seek(source: self.model.duration); return nil
            default: break
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "j": self.model.shuttle("j"); return nil
            case "k": self.model.shuttle("k"); return nil
            case "l": self.model.shuttle("l"); return nil
            case "s": self.model.splitAtPlayhead(); return nil
            case "z": self.model.addZoomAtPlayhead(); return nil
            default: return event
            }
        }
    }
}

/// Opening a recording that is still being written.
struct StillRecording: LocalizedError {
    var errorDescription: String? { "This recording is still in progress. Stop it first, then open it." }
}
