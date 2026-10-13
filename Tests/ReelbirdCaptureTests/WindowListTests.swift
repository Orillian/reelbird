import CoreGraphics
import Testing
@testable import ReelbirdCapture

/// `CaptureSources.arrange`: which windows the picker lists and in what order.
struct WindowListTests {
    static let own: pid_t = 999

    func window(_ id: CGWindowID, _ app: String, _ title: String?, pid: pid_t, onScreen: Bool = true, layer: Int = 0,
                size: CGSize = CGSize(width: 1200, height: 800), bundle: String? = nil) -> WindowCandidate {
        WindowCandidate(id: id, layer: layer, frame: CGRect(origin: CGPoint(x: 40, y: 40), size: size), title: title,
                        appName: app, bundleID: bundle ?? "com.example.\(app.lowercased())", processID: pid, isOnScreen: onScreen)
    }

    var rules: CaptureSources.WindowRules {
        CaptureSources.WindowRules(ownProcessID: Self.own, ownBundleID: "app.reelbird", regularApps: [1, 2, 3, 4, 5])
    }

    @Test func onScreenWindowsComeFirstFrontToBackThenOffScreenGroupedByApp() {
        let input = [
            window(10, "Safari", "Docs", pid: 1, onScreen: false),
            window(11, "Xcode", "App.swift", pid: 2),
            window(12, "Mail", "Inbox", pid: 3, onScreen: false),
            window(13, "Safari", "Pull request", pid: 1),
            window(14, "Safari", "Archive", pid: 1, onScreen: false),
            window(15, "Terminal", "zsh", pid: 4),
            window(16, "Mail", "Draft", pid: 3, onScreen: false),
        ]
        // 15 is frontmost, then 13, then 11.
        let out = CaptureSources.arrange(input, rules: rules, zOrder: [15: 0, 13: 4, 11: 9])
        #expect(out.map(\.id) == [15, 13, 11, 16, 12, 14, 10])
        #expect(out.prefix(3).allSatisfy { $0.isOnScreen })
        #expect(out.dropFirst(3).allSatisfy { !$0.isOnScreen })
    }

    @Test func onScreenWindowsMissingFromTheStackingOrderGoLastInListOrder() {
        let input = [window(1, "A", "one", pid: 1), window(2, "B", "two", pid: 2), window(3, "C", "three", pid: 3)]
        let out = CaptureSources.arrange(input, rules: rules, zOrder: [3: 0])
        #expect(out.map(\.id) == [3, 1, 2])
    }

    @Test func keepsTheQualityFilters() {
        let input = [
            window(1, "Keep", "Real window", pid: 1),
            window(2, "Menu", "Overlay", pid: 1, layer: 25),                                 // not normal layer
            window(3, "Tiny", "Palette", pid: 1, size: CGSize(width: 150, height: 300)),     // too narrow
            window(4, "Short", "Strip", pid: 1, size: CGSize(width: 600, height: 90)),       // too short
            window(5, "Reelbird", "Picker", pid: Self.own),                                  // ours (process)
            window(6, "Reelbird", "Editor", pid: 5, bundle: "app.reelbird"),                 // ours (bundle)
            window(7, "Dock", "Dock", pid: 2, bundle: "com.apple.dock"),                     // system UI
            window(8, "Ghost", "Invisible", pid: 1),                                         // transparent
            window(9, "Helper", nil, pid: 1, size: CGSize(width: 380, height: 500)),         // small and untitled
            window(10, "Big", nil, pid: 1, size: CGSize(width: 900, height: 600)),           // big untitled: app name
        ]
        var r = rules
        r.transparent = [8]
        let out = CaptureSources.arrange(input, rules: r, zOrder: [:])
        #expect(out.map(\.id) == [1, 10])
        #expect(out.last?.displayTitle == "Big")
    }

    @Test func offScreenWindowsNeedATitleAndADockApp() {
        let input = [
            window(1, "Chrome", "Release notes", pid: 1, onScreen: false),
            window(2, "Chrome", nil, pid: 1, onScreen: false),                    // hidden untitled helper
            window(3, "Chrome", "", pid: 1, onScreen: false),
            window(4, "AutoFill", "AutoFill", pid: 42, onScreen: false),          // not a Dock app
            window(5, "MenuApp", "Settings", pid: 43, onScreen: true),            // on screen: kept
        ]
        let out = CaptureSources.arrange(input, rules: rules, zOrder: [:])
        #expect(out.map(\.id) == [5, 1])
        // Without a running-apps list the Dock-app check is skipped.
        var r = rules
        r.regularApps = nil
        #expect(CaptureSources.arrange(input, rules: r, zOrder: [:]).map(\.id) == [5, 4, 1])
    }

    @Test func twoCopiesOfAnAppStayTogether() {
        let input = [
            window(1, "Notes", "B", pid: 2, onScreen: false),
            window(2, "Notes", "A", pid: 3, onScreen: false),
            window(3, "Notes", "C", pid: 2, onScreen: false),
        ]
        #expect(CaptureSources.arrange(input, rules: rules, zOrder: [:]).map(\.id) == [1, 3, 2])
    }
}
