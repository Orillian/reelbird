import CoreMedia
import Foundation
import ReelbirdCore

/// Errors the recorder surfaces to the app. Every message is written for the person recording.
public enum CaptureError: LocalizedError, Equatable, Sendable {
    case permissionDenied(Permission)
    case sourceNotFound(String)
    case noFrames
    case encoderUnavailable(String)
    case writerFailed(String)
    case alreadyStarted
    case notRecording
    case consolidationFailed(TrackKind, String)
    case unsupportedSource

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let p): "Reelbird needs \(p.displayName) permission. Turn it on in System Settings › Privacy & Security."
        case .sourceNotFound(let what): "Couldn't find \(what). It may have been closed or disconnected."
        case .noFrames: "The screen didn't deliver any frames. Check Screen Recording permission and try again."
        case .encoderUnavailable(let detail): "The hardware video encoder isn't available (\(detail))."
        case .writerFailed(let detail): "Writing the recording failed: \(detail)"
        case .alreadyStarted: "This recording has already started."
        case .notRecording: "Nothing is being recorded."
        case .consolidationFailed(let kind, let detail): "Couldn't finish the \(kind.rawValue) track: \(detail). The segments are kept in the project."
        case .unsupportedSource: "This capture source can't be recorded by ScreenCaptureKit."
        }
    }
}

/// Host clock (`CMClockGetHostTimeClock`) helpers. Every timestamp in the recorder is on this clock.
enum HostClock {
    static let clock = CMClockGetHostTimeClock()
    @inline(__always) static func now() -> Double { CMClockGetTime(clock).seconds }
    @inline(__always) static func nowTime() -> CMTime { CMClockGetTime(clock) }
}

extension CMTime {
    /// A CMTime with a 90 kHz-multiple timescale that represents video and 48 kHz audio exactly enough.
    static func seconds(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600_000) }
}

/// Rounds down to an even number (4:2:0 video needs even dimensions).
@inline(__always) func even(_ v: Double) -> Int { max(2, Int(v.rounded(.down)) & ~1) }

/// Simple logging for the capture pipeline (stderr only when RB_CAPTURE_LOG is set).
enum CaptureLog {
    static let enabled = ProcessInfo.processInfo.environment["RB_CAPTURE_LOG"] != nil
    static func debug(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("[capture] \(message())\n".utf8))
    }
}

/// A lock around a value that may be non-Sendable (pixel buffers, writers). The closure runs under
/// an unfair lock; keep it short and never await inside.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    @inline(__always) func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
}

/// Crash- and power-loss-safe small file writes for segments and playlists.
enum DurableFile {
    /// Writes `data` to a hidden temporary file next to `url`, flushes it to stable storage with
    /// `F_BARRIERFSYNC` (orders the data before the rename without the cost of `F_FULLFSYNC`), then
    /// renames it over `url`. Readers see either the old file or the complete new one, never a torn one.
    /// Throws the POSIX error (e.g. `ENOSPC`) and leaves no temporary file behind on failure.
    static func write(_ data: Data, to url: URL) throws {
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
            if fcntl(fd, F_BARRIERFSYNC) != 0 && fsync(fd) != 0 { throw posixError(errno, tmp) }
        } catch {
            close(fd)
            throw error
        }
        guard close(fd) == 0 else { throw posixError(errno, tmp) }
        guard rename(tmp.path, url.path) == 0 else { throw posixError(errno, url) }
        ok = true
    }

    static func posixError(_ code: Int32, _ url: URL) -> any Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code)), NSFilePathErrorKey: url.path])
    }

    /// Whether an error means the volume is out of space.
    static func isOutOfSpace(_ error: any Error) -> Bool {
        let e = error as NSError
        if e.domain == NSPOSIXErrorDomain && (e.code == Int(ENOSPC) || e.code == Int(EDQUOT)) { return true }
        if e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError { return true }
        if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError { return isOutOfSpace(u) }
        return false
    }
}
