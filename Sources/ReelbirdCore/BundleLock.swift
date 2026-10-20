import Foundation

/// An exclusive advisory lock (`flock`) on a bundle's `.lock` file, shared by every process (app,
/// CLI, MCP server). The recorder holds it for the whole take and recovery holds it while it rebuilds,
/// so two writers never consolidate the same segments at once. The kernel drops it when the process
/// exits, so a crash never leaves a bundle locked. The file itself stays (empty) and is never deleted:
/// unlinking a lock file while another process waits on it would split the lock in two.
public final class BundleLock: @unchecked Sendable {
    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    deinit { release() }

    public static func url(for bundle: ProjectBundle) -> URL { bundle.url.appendingPathComponent(".lock") }

    /// Why the lock is held, written into the lock file so other processes can tell a live recorder
    /// from a recovery in progress.
    public enum Purpose: String, Sendable {
        case recording, recovering, cleanup
    }

    /// Takes the lock. `wait == false` returns `nil` at once when another holder has it; `wait == true`
    /// blocks until it is free (call it off the main thread). Throws if the bundle doesn't exist.
    public static func acquire(_ bundle: ProjectBundle, purpose: Purpose, wait: Bool) throws -> BundleLock? {
        let path = url(for: bundle).path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw DurableFile.posixError(errno, url(for: bundle)) }
        while flock(fd, LOCK_EX | (wait ? 0 : LOCK_NB)) != 0 {
            let e = errno
            if e == EINTR { continue }
            close(fd)
            if e == EWOULDBLOCK { return nil }
            throw DurableFile.posixError(e, url(for: bundle))
        }
        let tag = Array(purpose.rawValue.utf8)
        _ = ftruncate(fd, 0)
        _ = tag.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        return BundleLock(fd: fd)
    }

    /// What the current holder is doing, or `nil` when the lock is free.
    public static func holder(_ bundle: ProjectBundle) -> Purpose? {
        guard isHeld(bundle), let data = try? Data(contentsOf: url(for: bundle)) else { return nil }
        return Purpose(rawValue: String(decoding: data, as: UTF8.self)) ?? .recording
    }

    /// Whether some holder (this process or another) has the lock right now.
    public static func isHeld(_ bundle: ProjectBundle) -> Bool {
        let fd = open(url(for: bundle).path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }
}

/// A short exclusive lock (`flock` on the bundle's `.edit.lock`) held while `edit.json` is checked and
/// written, so the app, the CLI and the MCP server can't both write from the same revision. Separate from
/// `BundleLock`, which a recorder holds for a whole take. Waits at most `timeout` seconds, then throws.
public enum EditLock {
    public static func url(for bundle: ProjectBundle) -> URL { bundle.url.appendingPathComponent(".edit.lock") }

    public static func withLock<T>(_ bundle: ProjectBundle, timeout: TimeInterval = 10, _ body: () throws -> T) throws -> T {
        let lockURL = url(for: bundle)
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw DurableFile.posixError(errno, lockURL) }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(timeout)
        var pause: useconds_t = 500
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let e = errno
            if e == EINTR { continue }
            guard e == EWOULDBLOCK else { throw DurableFile.posixError(e, lockURL) }
            guard Date() < deadline else { throw DurableFile.posixError(ETIMEDOUT, lockURL) }
            usleep(pause)
            pause = min(pause * 2, 20_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
