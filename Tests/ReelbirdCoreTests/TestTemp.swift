import Foundation

/// Where tests write scratch files: scripts/test.sh points RB_TEST_TMP at a per-run folder it deletes
/// afterwards. (`FileManager.temporaryDirectory` ignores TMPDIR inside the test runner.)
let testTemporaryDirectory: URL = {
    if let p = ProcessInfo.processInfo.environment["RB_TEST_TMP"], !p.isEmpty {
        let url = URL(fileURLWithPath: p, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    return FileManager.default.temporaryDirectory
}()
