import AppKit

/// Show in Finder that brings Finder forward. Since macOS 14 activation is cooperative: on its own,
/// `activateFileViewerSelecting` sometimes leaves Finder's window behind ours, so a click looked like it did nothing.
/// Handing activation to Finder first and then activating it explicitly brought it forward every time in testing.
@MainActor enum Finder {
    static func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: "com.apple.finder")
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
    }
}
