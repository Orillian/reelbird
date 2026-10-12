import Foundation
import ReelbirdCore

/// What the health check looks at, sampled ~10 times a second while recording.
struct HealthInputs: Sendable {
    /// Recording timeline time.
    var now: Double
    var paused = false
    var realTime = true
    var microphoneEnabled = false
    /// Seconds since the microphone last delivered a sample above the silence threshold
    /// (or since recording started, if it never did).
    var microphoneSilentFor = 0.0
    /// Seconds since the screen source last delivered anything (frame or idle heartbeat).
    var screenQuietFor = 0.0
    /// Whether a click, scroll or key press happened after the last screen frame (so the screen
    /// should have changed).
    var inputSinceLastFrame = false
    /// Audio realignment so far (silence inserted + audio dropped), seconds.
    var audioCorrection = 0.0
    var freeDiskBytes: Int64?
    var uploadBacklog = 0
    var shareFailure: String?
    var missingPermission: Permission?
}

/// Turns `HealthInputs` into warnings. A warning keeps its `since` time while it stays active.
struct HealthMonitor: Sendable {
    static let silenceRMS: Float = 0.000_25          // ≈ -72 dBFS: a muted or dead input
    static let silenceSeconds = 3.0
    static let stallSeconds = 2.0
    static let driftSeconds = 0.2
    static let lowDiskBytes: Int64 = 2_000_000_000
    static let backlogLimit = 5

    private var active: [HealthWarning.Kind: HealthWarning] = [:]

    mutating func evaluate(_ i: HealthInputs) -> [HealthWarning] {
        var now: [HealthWarning.Kind: String] = [:]
        if i.microphoneEnabled, !i.paused, i.microphoneSilentFor > Self.silenceSeconds {
            now[.microphoneSilent] = "Your microphone is silent. Check that it isn't muted or in use by another app."
        }
        if i.realTime, !i.paused, i.screenQuietFor > Self.stallSeconds, i.inputSinceLastFrame {
            now[.captureStalled] = "The screen stopped updating. Recording continues; check that the captured window is still open."
        }
        if i.audioCorrection > Self.driftSeconds {
            now[.avDrift] = "Audio dropped out or drifted by \(Int(i.audioCorrection * 1000)) ms; Reelbird kept it in sync."
        }
        if let free = i.freeDiskBytes, free < Self.lowDiskBytes {
            now[.lowDisk] = "Less than 2 GB of disk space left (\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)))."
        }
        if let failure = i.shareFailure {
            now[.shareFailed] = "The share link couldn't start: \(failure). The recording is saved locally."
        }
        if i.uploadBacklog > Self.backlogLimit {
            now[.uploadBacklog] = "Uploads are falling behind (\(i.uploadBacklog) segments waiting). The link catches up after you stop."
        }
        if let p = i.missingPermission {
            now[.permissionMissing] = "\(p.displayName) is off, so keystrokes aren't recorded."
        }
        var next: [HealthWarning.Kind: HealthWarning] = [:]
        for (kind, message) in now {
            let since = active[kind]?.since ?? i.now
            next[kind] = HealthWarning(kind: kind, message: message, since: since)
        }
        active = next
        return next.values.sorted { $0.since < $1.since }
    }
}
