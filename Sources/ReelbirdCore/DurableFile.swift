import Foundation

/// Crash- and power-loss-safe small file writes (segments, playlists, `project.json`, `edit.json`).
///
/// Every write goes to a hidden temporary file next to the target, is flushed, then renamed over the
/// target, so readers (and a Mac that lost power) see either the old file or the complete new one,
/// never a torn one.
public enum DurableFile {
    public enum Sync: Sendable {
        /// `F_BARRIERFSYNC` on the file before the rename: the data is ordered before the rename, so
        /// a power cut leaves the old or the new file. Cheap enough to run every couple of seconds
        /// while recording.
        case barrier
        /// `F_FULLFSYNC` on the file, the rename, then `F_FULLFSYNC` on the directory: the new file is
        /// on stable storage when this returns. For final states (a finished take, a saved edit).
        case full
    }

    /// Writes `data` to `url` durably (see `Sync`). Throws the POSIX error (e.g. `ENOSPC`) and leaves
    /// no temporary file behind on failure.
    public static func write(_ data: Data, to url: URL, sync: Sync = .barrier) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UInt32.random(in: 0...UInt32.max)).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw posixError(errno, tmp) }
        var ok = false
        defer {
            if !ok { unlink(tmp.path) }
        }
        do {
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw posixError(errno, tmp)
                    }
                    offset += n
                }
            }
            try flush(fd, sync, tmp)
        } catch {
            close(fd)
            throw error
        }
        guard close(fd) == 0 else { throw posixError(errno, tmp) }
        guard rename(tmp.path, url.path) == 0 else { throw posixError(errno, url) }
        ok = true
        if sync == .full { syncDirectory(dir) }
    }

    /// Flushes an open file: `F_FULLFSYNC` (or `F_BARRIERFSYNC`), falling back to `fsync` where the
    /// file system doesn't support them.
    public static func flush(_ fd: Int32, _ sync: Sync, _ url: URL) throws {
        let op = sync == .full ? F_FULLFSYNC : F_BARRIERFSYNC
        if fcntl(fd, op) != 0 && fsync(fd) != 0 { throw posixError(errno, url) }
    }

    /// Makes renames and deletions in `dir` durable. Best effort: a failure here leaves the files
    /// themselves intact.
    public static func syncDirectory(_ dir: URL) {
        let fd = open(dir.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        if fcntl(fd, F_FULLFSYNC) != 0 { _ = fsync(fd) }
        close(fd)
    }

    public static func posixError(_ code: Int32, _ url: URL) -> any Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code)), NSFilePathErrorKey: url.path])
    }

    /// Whether an error means the volume is out of space.
    public static func isOutOfSpace(_ error: any Error) -> Bool {
        let e = error as NSError
        if e.domain == NSPOSIXErrorDomain && (e.code == Int(ENOSPC) || e.code == Int(EDQUOT)) { return true }
        if e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError { return true }
        if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError { return isOutOfSpace(u) }
        return false
    }
}
