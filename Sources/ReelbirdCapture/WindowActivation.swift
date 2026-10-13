import AppKit
import ApplicationServices
import CoreGraphics

/// Brings a window that isn't on screen (another desktop, a full-screen Space, minimized, hidden
/// app) onto the screen so it can be recorded.
///
/// Public API only, so it is best effort:
/// - Activating the owning app makes macOS switch to a Space with its windows (unless "When
///   switching to an application, switch to a Space with open windows" is off in Desktop & Dock),
///   but it picks the app's most recent window's Space, not necessarily this window's.
/// - A minimized window is restored directly when Reelbird has Accessibility access (optional; the
///   user grants it in System Settings). Otherwise a reopen event (what clicking the Dock icon sends)
///   restores it only when the app has no other visible window.
public enum WindowActivation {
    /// Tries to bring the window on screen and waits up to `timeout` for the window server to show
    /// it. Returns whether it is on screen.
    public static func bringOnScreen(windowID: CGWindowID, processID: pid_t, title: String,
                                     timeout: Duration = .seconds(2)) async -> Bool {
        if CaptureSources.isOnScreen(windowID: windowID) { return true }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        if AXIsProcessTrusted() {
            await Task.detached(priority: .userInitiated) { restoreWithAccessibility(processID: processID, title: title) }.value
        }
        let bundleURL = await MainActor.run { () -> URL? in
            guard let app = NSRunningApplication(processIdentifier: processID) else { return nil }
            if app.isHidden { app.unhide() }
            // Activation is cooperative since macOS 14: the active app must let it happen. The
            // picker panel doesn't activate Reelbird, so take activation first (a click just landed
            // on it), then pass it on.
            NSApp?.activate()
            app.activate(from: .current, options: [])
            return app.bundleURL
        }
        if await waitUntilOnScreen(windowID, until: min(deadline, clock.now + .milliseconds(700))) { return true }
        // Still off screen: send a reopen event, like a click on the app's Dock icon. Launch Services
        // activation is honoured even when cooperative activation wasn't, and AppKit apps restore a
        // minimized window on reopen when nothing else of theirs is visible.
        if let bundleURL {
            await MainActor.run {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                config.addsToRecentItems = false
                NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in }
            }
        }
        return await waitUntilOnScreen(windowID, until: deadline)
    }

    private static func waitUntilOnScreen(_ id: CGWindowID, until deadline: ContinuousClock.Instant) async -> Bool {
        while ContinuousClock.now < deadline {
            if CaptureSources.isOnScreen(windowID: id) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return CaptureSources.isOnScreen(windowID: id)
    }

    /// Un-minimizes and raises the app's window with this title through the Accessibility API.
    /// Windows on other Spaces usually aren't in the app's AX window list; activation covers those.
    private static func restoreWithAccessibility(processID: pid_t, title: String) {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.5) // a hung app must not stall Start
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for window in windows {
            var t: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &t) == .success,
                  (t as? String) == title else { continue }
            var minimized: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
               (minimized as? Bool) == true {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            return
        }
    }
}
