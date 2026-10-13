import AppKit
import ReelbirdCore

/// The alert sound, skipped in automated runs (self tests, snapshots, test suites).
@MainActor enum Beep {
    /// How many beeps were skipped (self test checks).
    private(set) static var skipped = 0

    static func play() {
        if AutomatedRun.isSilent { skipped += 1; return }
        NSSound.beep()
    }
}
