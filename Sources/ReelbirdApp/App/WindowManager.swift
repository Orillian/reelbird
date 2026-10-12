import AppKit
import ReelbirdCore
import SwiftUI

/// Opens and tracks the app's document-style windows. While any is open the app shows in the
/// Dock (`.regular`); when the last one closes it returns to a menu-bar-only app (`.accessory`).
@MainActor final class WindowManager: NSObject, NSWindowDelegate {
    private unowned let app: AppModel
    private var editors: [URL: EditorWindowController] = [:]
    private var library: NSWindow?
    private var settings: SettingsWindowController?
    private var onboarding: NSWindow?

    init(app: AppModel) { self.app = app }

    var hasRegularWindows: Bool {
        !editors.isEmpty || library?.isVisible == true || settings?.window?.isVisible == true || onboarding?.isVisible == true
    }

    func openEditor(bundle: ProjectBundle) {
        let key = bundle.url.standardizedFileURL
        if let existing = editors[key] { bring(existing.window); return }
        do {
            let controller = try EditorWindowController(bundle: bundle, app: app)
            controller.window?.delegate = self
            editors[key] = controller
            bring(controller.window)
            app.library.noteRecent(bundle)
        } catch {
            app.present(error, title: "Couldn't open this recording")
        }
    }

    func openLibrary() {
        if let w = library { bring(w); app.library.reload(); return }
        let w = makeWindow(title: "Library", size: NSSize(width: 980, height: 640), minSize: NSSize(width: 640, height: 420),
                           root: LibraryView(store: app.library, app: app), autosave: "LibraryWindow")
        library = w
        app.library.reload()
        bring(w)
    }

    func openSettings(_ tab: SettingsTab) {
        if settings == nil {
            let s = SettingsWindowController(app: app)
            s.window?.delegate = self
            settings = s
        }
        settings?.select(tab)
        bring(settings?.window)
    }

    func openOnboarding() {
        if let w = onboarding { bring(w); return }
        let w = makeWindow(title: "Welcome to Reelbird", size: NSSize(width: 620, height: 520), minSize: nil,
                           root: OnboardingView(model: OnboardingModel(app: app)), autosave: nil, resizable: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        onboarding = w
        bring(w)
    }

    func closeOnboarding() { onboarding?.close() }

    // MARK: Helpers

    private func makeWindow<V: View>(title: String, size: NSSize, minSize: NSSize?, root: V, autosave: String?,
                                     resizable: Bool = true) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        w.title = title
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: root.environment(app))
        if let minSize { w.contentMinSize = minSize }
        w.center()
        if let autosave { w.setFrameAutosaveName(autosave) }
        w.delegate = self
        return w
    }

    private func bring(_ w: NSWindow?) {
        guard let w else { return }
        NSApp.setActivationPolicy(.regular)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if let (k, _) = editors.first(where: { $0.value.window === w }) {
            editors[k]?.willClose()
            editors.removeValue(forKey: k)
        }
        if w === library { library = nil }
        if w === onboarding { onboarding = nil }
        // Defer so the closing window no longer counts as visible.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.hasRegularWindows else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        editors.values.first(where: { $0.window === window })?.model.undoManager
    }
}
