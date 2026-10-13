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
    /// Clipping events (peaks at or above −0.5 dBFS) in the last two seconds.
    var microphoneClipEvents = 0
    /// Speech-like energy for the last ten seconds with no peak reaching −30 dBFS.
    var microphoneTooQuiet = false
    /// Speech while paused.
    var talkingWhilePaused = false
    /// The microphone the take is locked to (explicit device), when known.
    var lockedMicrophoneID: String?
    var lockedMicrophoneName: String?
    /// The locked microphone is no longer connected.
    var microphoneMissing = false
    /// macOS's current default input.
    var systemDefaultMicrophoneID: String?
    var systemDefaultMicrophoneName: String?
    var freeDiskBytes: Int64?
    var uploadBacklog = 0
    var shareFailure: String?
    var missingPermission: Permission?
}

/// Turns `HealthInputs` into warnings. A warning keeps its `since` time while it stays active, so the UI
/// can tell one episode from the next (a dismissed warning comes back only when its condition ends and
/// starts again). Level warnings are held for a few seconds after their condition clears so they don't
/// flicker between syllables.
struct HealthMonitor: Sendable {
    static let silenceRMS: Float = 0.000_25          // ≈ -72 dBFS: a muted or dead input
    static let silenceSeconds = 3.0
    static let stallSeconds = 2.0
    static let driftSeconds = 0.2
    static let lowDiskBytes: Int64 = 2_000_000_000
    static let backlogLimit = 5
    /// Clipping events within two seconds that raise the clipping warning.
    static let clipEvents = MicrophoneAnalyzer.clipEventsForWarning
    /// How long "macOS switched its input" stays up.
    static let switchNoticeSeconds = 8.0
    /// Seconds a level warning stays after its condition clears.
    static let holds: [HealthWarning.Kind: Double] = [.microphoneClipping: 4, .microphoneTooQuiet: 3, .talkingWhilePaused: 1.5]

    private var active: [HealthWarning.Kind: HealthWarning] = [:]
    private var lastSeen: [HealthWarning.Kind: Double] = [:]
    private var lastDefaultID: String?
    private var sawDefault = false
    private var switched: (at: Double, message: String)?

    mutating func evaluate(_ i: HealthInputs) -> [HealthWarning] {
        var now: [HealthWarning.Kind: String] = [:]
        let mic = i.microphoneEnabled
        let missing = mic && i.microphoneMissing
        let live = mic && !missing && !i.paused
        let micName = i.lockedMicrophoneName ?? "Your microphone"
        if missing {
            now[.microphoneDisconnected] = "\(micName) disconnected. Your voice may be missing until it's back."
        }
        if live, i.microphoneSilentFor > Self.silenceSeconds {
            now[.microphoneSilent] = "Your mic is silent. Is it muted or in use by another app?"
        }
        if live, i.microphoneClipEvents >= Self.clipEvents {
            now[.microphoneClipping] = "Your mic is clipping. Move back or lower its input level."
        }
        if live, i.microphoneTooQuiet, now[.microphoneSilent] == nil {
            now[.microphoneTooQuiet] = "Your voice is very quiet. Move closer to the mic."
        }
        if mic, !missing, i.paused, i.talkingWhilePaused {
            now[.talkingWhilePaused] = "You're talking while paused."
        }
        if mic, let id = i.systemDefaultMicrophoneID {
            if sawDefault, id != lastDefaultID, id != i.lockedMicrophoneID, let locked = i.lockedMicrophoneName {
                switched = (i.now, "macOS switched to \(i.systemDefaultMicrophoneName ?? "another mic"). Still recording from \(locked).")
            }
            if id == i.lockedMicrophoneID { switched = nil }
            sawDefault = true
            lastDefaultID = id
        }
        if let s = switched, i.now - s.at < Self.switchNoticeSeconds, !missing {
            now[.microphoneChanged] = s.message
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

        // Hold level warnings briefly, but only while they still make sense (e.g. not after resuming).
        for kind in Self.holds.keys where now[kind] != nil { lastSeen[kind] = i.now }
        for (kind, hold) in Self.holds where now[kind] == nil {
            guard let previous = active[kind], let seen = lastSeen[kind], i.now - seen < hold else { continue }
            let stillValid = kind == .talkingWhilePaused ? (mic && !missing && i.paused) : live
            if stillValid { now[kind] = previous.message }
        }

        var next: [HealthWarning.Kind: HealthWarning] = [:]
        for (kind, message) in now {
            let since = active[kind]?.since ?? i.now
            next[kind] = HealthWarning(kind: kind, message: message, since: since)
        }
        active = next
        return next.values.sorted { $0.since < $1.since || ($0.since == $1.since && $0.kind.rawValue < $1.kind.rawValue) }
    }
}
