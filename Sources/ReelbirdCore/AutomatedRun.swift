import Foundation
import Synchronization

/// Automated runs make no sound. The app's `--selftest`, `--selftest-live` and `--snapshot` modes mark
/// themselves with `begin()`, and test processes (XCTest or Swift Testing) are detected. While silent, preview
/// players are muted (audio processing still runs, so its measurements hold) and alert beeps are skipped.
/// Normal use is unchanged.
public enum AutomatedRun {
    private static let marked = Atomic<Bool>(false)

    /// Marks this process as an automated run.
    public static func begin() { marked.store(true, ordering: .relaxed) }

    /// Whether this process is running a test suite.
    public static let isTestProcess: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil || env["XCTestSessionIdentifier"] != nil {
            return true
        }
        let name = ProcessInfo.processInfo.processName.lowercased()
        if name == "xctest" || name.contains("swiftpm-testing-helper") || name.hasSuffix("packagetests") { return true }
        return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }()

    /// Whether this run should stay silent.
    public static var isSilent: Bool { marked.load(ordering: .relaxed) || isTestProcess }
}
