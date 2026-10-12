import AppKit
import ReelbirdCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var model: AppModel!
    private var statusItem: StatusItemController?
    private var pendingOpen: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--mock` simulates the engine; `--synthetic` records generated frames instead of the screen.
        let args = CommandLine.arguments
        let services = args.contains("--mock") ? Services.mock() : Services.live(synthetic: args.contains("--synthetic"))
        model = AppModel(services: services, prefs: Preferences())
        NSApp.mainMenu = MainMenu.build(target: self, prefs: model.prefs)
        statusItem = StatusItemController(app: model)
        model.registerHotKeys()
        NSApp.setActivationPolicy(.accessory)

        model.library.recoverInterruptedRecordings()

        if !pendingOpen.isEmpty {
            pendingOpen.forEach(openURL)
            pendingOpen.removeAll()
        } else if !model.prefs.onboardingDone {
            model.showOnboarding()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard model != nil else { pendingOpen.append(contentsOf: urls); return }
        urls.forEach(openURL)
    }

    private func openURL(_ url: URL) {
        guard url.pathExtension == ProjectBundle.pathExtension else { return }
        model.open(bundle: ProjectBundle(url: url))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model.openLibrary() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let rec = model?.recording, rec.isActive else { return .terminateNow }
        // Never lose a take: finish the recording before quitting.
        rec.stop(openEditor: false) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: Menu actions

    @objc func newRecording(_ sender: Any?) { model.newRecording() }
    @objc func openLibrary(_ sender: Any?) { model.openLibrary() }
    @objc func openSettings(_ sender: Any?) { model.openSettings() }
    @objc func openAbout(_ sender: Any?) { model.openSettings(.about) }
    @objc func showOnboarding(_ sender: Any?) { model.showOnboarding() }
    @objc func openRepository(_ sender: Any?) {
        if let u = URL(string: ReelbirdInfo.repositoryURL) { NSWorkspace.shared.open(u) }
    }
    @objc func openSupport(_ sender: Any?) {
        if let u = URL(string: ReelbirdInfo.supportURL) { NSWorkspace.shared.open(u) }
    }
    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: ProjectBundle.pathExtension, conformingTo: .package) ?? .package]
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = model.prefs.library.root
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { openURL(url) }
    }
}
