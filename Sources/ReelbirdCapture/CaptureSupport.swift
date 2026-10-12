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
