import AppKit
import Observation
import ReelbirdCapture
import ReelbirdCore

/// The menu bar bird. While recording it turns into a red dot and a running timer, and the menu
/// leads with Stop. Idle, the menu leads with New Recording and the five latest recordings.
@MainActor final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private unowned let app: AppModel
    private let menu = NSMenu()
    /// The "Recording · 1:14" line, kept live while the menu is open.
    private weak var statusLine: NSMenuItem?
    private var menuTimer: Timer?

    init(app: AppModel) {
        self.app = app
        super.init()
        item.button?.image = BrandImage.menuBar(recording: false)
        item.button?.imagePosition = .imageLeading
        item.button?.toolTip = "Reelbird"
        item.button?.setAccessibilityLabel("Reelbird")
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
            button.image = rec.phase == .paused
                ? NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "Reelbird, paused")
                : BrandImage.menuBar(recording: true)
            button.attributedTitle = NSAttributedString(
                string: " " + TimeFormat.clock(rec.status.elapsed),
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)])
            button.toolTip = rec.phase == .paused ? "Reelbird: paused" : "Reelbird: recording"
            button.setAccessibilityLabel("\(rec.phase == .paused ? "Paused" : "Recording"), \(TimeFormat.clock(rec.status.elapsed))")
        case .finishing:
            button.title = ""
            button.image = BrandImage.menuBar(recording: true)
            button.toolTip = "Reelbird: saving your recording"
        default:
            button.title = ""
            button.image = BrandImage.menuBar(recording: false)
            button.toolTip = "Reelbird"
            button.setAccessibilityLabel("Reelbird")
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let rec = app.recording
        let prefs = app.prefs

        switch rec.phase {
        case .recording, .paused, .countdown:
            let line = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
            line.isEnabled = false
            line.image = symbol(rec.phase == .paused ? "pause.circle.fill" : "record.circle.fill",
                                tint: rec.phase == .paused ? .secondaryLabelColor : .rbAccent)
            menu.addItem(line)
            statusLine = line
            menu.addItem(.separator())

            let stop = add(rec.phase == .countdown ? "Cancel Countdown" : "Stop Recording",
                           rec.phase == .countdown ? #selector(cancelCountdown) : #selector(stopRecording), symbol: "stop.circle")
            if rec.phase != .countdown {
                stop.keyEquivalent = prefs.recordHotKey.menuKeyEquivalent
                stop.keyEquivalentModifierMask = prefs.recordHotKey.menuModifiers
                let pause = add(rec.phase == .paused ? "Resume" : "Pause", #selector(togglePause),
                                symbol: rec.phase == .paused ? "play.circle" : "pause.circle")
                pause.keyEquivalent = prefs.pauseHotKey.menuKeyEquivalent
                pause.keyEquivalentModifierMask = prefs.pauseHotKey.menuModifiers
                if rec.status.shareURL != nil {
                    add("Copy Live Link", #selector(copyLiveLink), symbol: "link")
                }
                menu.addItem(.separator())
                add("Start Over…", #selector(restart), symbol: "arrow.counterclockwise")
                add("Discard Recording…", #selector(discard), symbol: "trash")
            }
        case .finishing:
            let line = NSMenuItem(title: "Saving your recording…", action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
        case .idle, .picking, .selectingArea:
            if app.services.permissions.status(.screen) != .granted {
                let allow = add("Allow Screen Recording…", #selector(openPermissions), symbol: "exclamationmark.triangle.fill")
                allow.image = symbol("exclamationmark.triangle.fill", tint: .rbWarning)
                menu.addItem(.separator())
            }
            let new = add("New Recording…", #selector(newRecording), symbol: "record.circle")
            new.keyEquivalent = prefs.recordHotKey.menuKeyEquivalent
            new.keyEquivalentModifierMask = prefs.recordHotKey.menuModifiers
            new.isEnabled = rec.phase == .idle || rec.phase == .picking
            addRecents()
        }

        menu.addItem(.separator())
        let lib = add("Open Library", #selector(openLibrary), symbol: "square.grid.2x2")
        lib.keyEquivalent = "l"; lib.keyEquivalentModifierMask = [.command, .shift]
        add("Settings…", #selector(openSettings), symbol: "gearshape").keyEquivalent = ","
        add("About Reelbird", #selector(openAbout), symbol: "info.circle")
        menu.addItem(.separator())
        add("Quit Reelbird", #selector(quit), symbol: nil).keyEquivalent = "q"
    }

    /// Up to five recent recordings with a poster, length and age. Hold Option to reveal in Finder.
    private func addRecents() {
        let recent = app.library.items.prefix(5)
        guard !recent.isEmpty else { return }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Recent"))
        for r in recent {
            let open = NSMenuItem(title: r.title, action: #selector(openRecent(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = r.bundle.url
            open.image = thumbnail(app.library.posters[r.id])
            var detail = [TimeFormat.clock(r.duration), r.createdAt.formatted(.relative(presentation: .named))]
            if r.shareURL != nil { detail.append("Shared") }
            if r.recovered { detail.append("Recovered") }
            open.subtitle = detail.joined(separator: " · ")
            open.toolTip = "Open in the editor. Hold Option to show it in Finder."
            menu.addItem(open)

            let reveal = NSMenuItem(title: "Show “\(r.title)” in Finder", action: #selector(revealRecent(_:)), keyEquivalent: "")
            reveal.target = self
            reveal.representedObject = r.bundle.url
            reveal.image = open.image
            reveal.subtitle = open.subtitle
            reveal.isAlternate = true
            reveal.keyEquivalentModifierMask = .option
            menu.addItem(reveal)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        app.library.reloadIfStale()
        guard app.recording.isActive else { return }
        // Menus run their own event loop; tick in its mode so the timer line stays live.
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusLine?.title = self?.statusText() ?? "" }
        }
        RunLoop.main.add(t, forMode: .eventTracking)
        menuTimer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        menuTimer?.invalidate()
        menuTimer = nil
    }

    private func statusText() -> String {
        let rec = app.recording
        switch rec.phase {
        case .countdown: return "Starting in \(rec.countdownValue)…"
        case .paused: return "Paused · \(TimeFormat.clock(rec.status.elapsed))"
        default:
            let live = rec.status.shareURL == nil ? "" : (rec.status.uploadBacklog > 0 ? " · uploading" : " · link live")
            return "Recording · \(TimeFormat.clock(rec.status.elapsed))\(live)"
        }
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, symbol name: String?) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        if let name { i.image = NSImage(systemSymbolName: name, accessibilityDescription: nil) }
        menu.addItem(i)
        return i
    }

    private func symbol(_ name: String, tint: NSColor) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [tint]))
    }

    /// A 16:10 poster with rounded corners, sized for a menu row with a subtitle.
    private func thumbnail(_ poster: CGImage?) -> NSImage? {
        let size = NSSize(width: 48, height: 30)
        guard let poster else {
            return NSImage(systemSymbolName: "film", accessibilityDescription: nil)
        }
        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            path.addClip()
            // Aspect-fill.
            let pw = CGFloat(poster.width), ph = CGFloat(poster.height)
            let scale = max(rect.width / pw, rect.height / ph)
            let w = pw * scale, h = ph * scale
            NSGraphicsContext.current?.cgContext.interpolationQuality = .high
            NSGraphicsContext.current?.cgContext.draw(poster, in: CGRect(x: (rect.width - w) / 2, y: (rect.height - h) / 2, width: w, height: h))
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }

    @objc private func newRecording() { app.newRecording() }
    @objc private func stopRecording() { app.recording.stop() }
    @objc private func cancelCountdown() { app.recording.cancelCountdown(); app.recording.closePicker() }
    @objc private func togglePause() { app.recording.togglePause() }
    @objc private func restart() { app.recording.confirmRestart() }
    @objc private func discard() { app.recording.confirmDiscard() }
    @objc private func openLibrary() { app.openLibrary() }
    @objc private func openSettings() { app.openSettings() }
    @objc private func openPermissions() { app.openSettings(.permissions) }
    @objc private func openAbout() { app.openSettings(.about) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func copyLiveLink() {
        guard let url = app.recording.status.shareURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        Toast.show(title: "Link copied", detail: "It plays what you've recorded so far, and the rest as it uploads.", symbol: "link")
    }
    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        app.open(bundle: ProjectBundle(url: url))
    }
    @objc private func revealRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
