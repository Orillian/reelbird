import AppKit
import Foundation

// Entry point. `--snapshot <dir> [filter]` renders the UI to PNGs (design review) and exits;
// `--selftest` / `--selftest-live` drive the app's models against mock / real services and exit;
// `--probe-thumbnails <dir>` (debug builds only) checks which off-screen windows macOS lets us capture.
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
    let filter = i + 2 < args.count && !args[i + 2].hasPrefix("--") ? args[i + 2] : nil
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        SnapshotRunner.run(dir: dir, filter: filter, live: args.contains("--live"))
    }
    exit(0)
}

#if DEBUG
if let i = args.firstIndex(of: "--probe-thumbnails"), i + 1 < args.count {
    let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        Task { @MainActor in await ThumbnailProbe.run(dir: dir); exit(0) }
    }
    RunLoop.main.run()
}
#endif

if args.contains("--selftest") || args.contains("--selftest-live") {
    let live = args.contains("--selftest-live")
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        Task { @MainActor in exit(await (live ? LiveSelfTest.run() : SelfTest.run()) ? 0 : 1) }
    }
    RunLoop.main.run()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
