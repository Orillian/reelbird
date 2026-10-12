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
        if try app.services.recorder.recoverIfNeeded(bundle) { app.library.reload() }
        model = try EditorModel(bundle: bundle, services: app.services)
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
        model.pause()
        model.saveNow()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Single-key shortcuts (space, J/K/L, S, Z, arrows, delete) while no text field is editing.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let w = self.window, w.isKeyWindow, w.attachedSheet == nil else { return event }
            if w.firstResponder is NSTextView { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control])
            if mods.contains(.command) {
                if let n = Int(event.charactersIgnoringModifiers ?? ""), (1...InspectorSection.allCases.count).contains(n) {
                    self.model.section = InspectorSection.allCases[n - 1]; return nil
                }
                switch event.charactersIgnoringModifiers {
                case "=", "+": self.model.timelineZoom = min(16, self.model.timelineZoom * 1.5); return nil
                case "-": self.model.timelineZoom = max(1, self.model.timelineZoom / 1.5); return nil
                case "e": self.model.showExport = true; return nil
                default: return event
                }
            }
            guard mods.isEmpty else { return event }
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

