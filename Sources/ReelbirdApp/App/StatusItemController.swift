import AppKit
import Observation
import ReelbirdCore

/// The menu bar bird. While recording it turns into a red dot and a running timer.
@MainActor final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private unowned let app: AppModel
    private let menu = NSMenu()

    init(app: AppModel) {
        self.app = app
        super.init()
        item.button?.image = .birdGlyph()
        item.button?.imagePosition = .imageLeading
        item.button?.toolTip = "Reelbird"
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = app.recording.phase
            _ = app.recording.status.elapsed
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshButton()
                self?.observe()
            }
        }
        refreshButton()
    }

    private func refreshButton() {
        guard let button = item.button else { return }
        let rec = app.recording
        switch rec.phase {
        case .recording, .paused:
            button.image = nil
            let dotColor: NSColor = rec.phase == .paused ? .secondaryLabelColor : .rbRecording
            let s = NSMutableAttributedString(string: rec.phase == .paused ? "❚❚ " : "● ",
                                              attributes: [.foregroundColor: dotColor, .font: NSFont.systemFont(ofSize: rec.phase == .paused ? 9 : 11)])
            s.append(NSAttributedString(string: TimeFormat.clock(rec.status.elapsed),
                                        attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)]))
            button.attributedTitle = s
        default:
            button.title = ""
            button.image = .birdGlyph()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let rec = app.recording
        let prefs = app.prefs
        if rec.isActive {
            let stop = add("Stop Recording", #selector(stopRecording), symbol: "stop.circle.fill")
            stop.keyEquivalent = prefs.recordHotKey.menuKeyEquivalent
            stop.keyEquivalentModifierMask = prefs.recordHotKey.menuModifiers
            let pause = add(rec.phase == .paused ? "Resume" : "Pause", #selector(togglePause),
                            symbol: rec.phase == .paused ? "play.fill" : "pause.fill")
            pause.keyEquivalent = prefs.pauseHotKey.menuKeyEquivalent
            pause.keyEquivalentModifierMask = prefs.pauseHotKey.menuModifiers
            add("Restart", #selector(restart), symbol: "arrow.counterclockwise")
            add("Discard…", #selector(discard), symbol: "trash")
        } else {
            let new = add("New Recording…", #selector(newRecording), symbol: "record.circle")
            new.keyEquivalent = prefs.recordHotKey.menuKeyEquivalent
            new.keyEquivalentModifierMask = prefs.recordHotKey.menuModifiers
        }
        menu.addItem(.separator())

        let recent = app.library.items.prefix(5)
        if !recent.isEmpty {
            let header = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for r in recent {
                let i = NSMenuItem(title: r.title, action: #selector(openRecent(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = r.bundle.url
                i.indentationLevel = 1
                menu.addItem(i)
            }
            menu.addItem(.separator())
        }
        let lib = add("Library", #selector(openLibrary), symbol: "square.grid.2x2")
        lib.keyEquivalent = "l"; lib.keyEquivalentModifierMask = [.command, .shift]
        let settings = add("Settings…", #selector(openSettings), symbol: nil)
        settings.keyEquivalent = ","
        menu.addItem(.separator())
        add("Quit Reelbird", #selector(quit), symbol: nil).keyEquivalent = "q"
    }

    func menuWillOpen(_ menu: NSMenu) { app.library.reloadIfStale() }

    @discardableResult
    private func add(_ title: String, _ action: Selector, symbol: String?) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.addItem(i)
        return i
    }

    @objc private func newRecording() { app.newRecording() }
    @objc private func stopRecording() { app.recording.stop() }
    @objc private func togglePause() { app.recording.togglePause() }
    @objc private func restart() { app.recording.restart() }
    @objc private func discard() { app.recording.confirmDiscard() }
    @objc private func openLibrary() { app.openLibrary() }
    @objc private func openSettings() { app.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        app.open(bundle: ProjectBundle(url: url))
    }
}
