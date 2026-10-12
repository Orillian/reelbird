import AppKit
import Foundation

// Entry point. `--snapshot <dir> [filter]` renders the UI to PNGs (design review) and exits.
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
    let filter = i + 2 < args.count ? args[i + 2] : nil
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        SnapshotRunner.run(dir: dir, filter: filter)
    }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
