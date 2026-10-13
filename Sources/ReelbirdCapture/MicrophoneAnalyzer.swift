import Foundation
import ReelbirdCore
import Synchronization

/// Running analysis of the raw microphone input (before pause muting): peak and RMS in dBFS, a noise
/// floor, clipping, too-quiet speech, speech while paused, and how much of the take had any sound.
///
/// Fed once per capture buffer (10–20 ms) on the microphone queue. Fixed-size state, no allocation
/// after `init`. Times are buffer timestamps in seconds (host clock when live).
struct MicrophoneAnalyzer: Sendable {
    /// −0.5 dBFS.
    static let clipLinear: Float = 0.944_06
    /// Clipped buffers closer together than this are one clipping event.
    static let clipMergeGap = 0.1
    static let clipWindow = 2.0
    /// Clipping events within `clipWindow` that count as "repeatedly".
    static let clipEventsForWarning = 3
    /// Speech peaks below this for `quietWindowSeconds` are too quiet.
    static let tooQuietPeakDB = -30.0
    static let quietWindowSeconds = 10
    /// Seconds of speech-like energy the quiet window needs before it can judge the level.
    static let quietMinSpeechSeconds = 2.0
    /// A buffer is speech-like when its RMS is this far above the noise floor…
    static let speechAboveFloorDB = 10.0
    /// …and above this absolute level (below it, nothing is audible).
    static let speechMinDB = -70.0
    /// Anything at or above this RMS counts as "picked something up" for the take summary.
    static let soundDB = -60.0
    /// The noise floor follows quieter buffers instantly and rises this fast otherwise.
    static let floorRiseDBPerSecond = 1.5
    static let floorMinDB = -100.0
    /// Net seconds of speech while paused before "You're talking while paused".
    static let pausedTalkSeconds = 0.6
    /// Analysis older than this (no buffers arriving) stops raising level warnings.
    static let staleSeconds = 1.0

    private struct Bin: Sendable {
        var number = -1
        var maxSpeechPeakDB = -160.0
        var speechSeconds = 0.0
    }

    private(set) var reading = MicLevelReading()
    private(set) var floorDB: Double?
    private(set) var lastTime: Double?
    /// Unpaused seconds analysed.
    private(set) var activeSeconds = 0.0
    /// Unpaused seconds with speech-like energy or a level at or above `soundDB`.
    private(set) var soundSeconds = 0.0
    private var clipTimes: [Double]
    private var clipCursor = 0
    private var lastClipBuffer = -Double.infinity
    private var bins: [Bin]
    private var pausedSpeech = 0.0

    init() {
        clipTimes = Array(repeating: -.infinity, count: 8)
        bins = Array(repeating: Bin(), count: Self.quietWindowSeconds)
    }

    /// Analyses one buffer of interleaved Float32 samples at 48 kHz starting at `time`.
    mutating func ingest(_ samples: UnsafePointer<Float>, frames: Int, channels: Int, at time: Double, paused: Bool,
                         sampleRate: Double = 48_000) {
        guard frames > 0, channels > 0 else { return }
        var peak: Float = 0
        var sum: Float = 0
        let n = frames * channels
        for i in 0..<n {
            let v = samples[i]
            sum += v * v
            let a = abs(v)
            if a > peak { peak = a }
        }
        let rms = (sum / Float(n)).squareRoot()
        ingest(peak: Double(peak), rms: Double(rms), duration: Double(frames) / sampleRate, at: time, paused: paused)
    }

    /// Analyses one buffer from its linear peak and RMS (0...1).
    mutating func ingest(peak: Double, rms: Double, duration dt: Double, at time: Double, paused: Bool) {
        let peakDB = MicLevelReading.dB(peak)
        let rmsDB = MicLevelReading.dB(rms)
        let end = time + dt
        lastTime = end

        // Meter ballistics: instant attack, 24 dB/s fall for the peak and 18 dB/s for the RMS.
        reading.peakDB = max(max(peakDB, MicLevelReading.floorDB), reading.peakDB - 24 * dt)
        reading.rmsDB = max(max(rmsDB, MicLevelReading.floorDB), reading.rmsDB - 18 * dt)

        let floor = floorDB ?? max(Self.floorMinDB, rmsDB)
        let speechLike = rmsDB >= Self.speechMinDB && rmsDB >= floor + Self.speechAboveFloorDB
        floorDB = rmsDB < floor ? max(Self.floorMinDB, rmsDB) : min(rmsDB, floor + Self.floorRiseDBPerSecond * dt)

        guard !paused else {
            pausedSpeech = min(3, max(0, pausedSpeech + (speechLike ? dt : -0.5 * dt)))
            return
        }
        pausedSpeech = 0
        activeSeconds += dt
        if speechLike || rmsDB >= Self.soundDB { soundSeconds += dt }

        if Float(peak) >= Self.clipLinear {
            if time - lastClipBuffer > Self.clipMergeGap {
                clipTimes[clipCursor] = time
                clipCursor = (clipCursor + 1) % clipTimes.count
            }
            lastClipBuffer = end
        }

        // One-second bins over unpaused time for the too-quiet check.
        let number = Int(activeSeconds)
        let i = number % bins.count
        if bins[i].number != number { bins[i] = Bin(number: number) }
        if speechLike {
            bins[i].speechSeconds += dt
            bins[i].maxSpeechPeakDB = max(bins[i].maxSpeechPeakDB, peakDB)
        }
    }

    private func fresh(_ now: Double?) -> Bool {
        guard let lastTime else { return false }
        guard let now else { return true }
        return now - lastTime <= Self.staleSeconds
    }

    /// Clipping events in the last `clipWindow` seconds before `now` (`nil` = the latest buffer's time).
    func clipEvents(now: Double? = nil) -> Int {
        guard fresh(now), let reference = now ?? lastTime else { return 0 }
        return clipTimes.reduce(0) { $0 + ($1 > reference - Self.clipWindow && $1 <= reference ? 1 : 0) }
    }

    /// Speech-like energy was present over the last ten seconds of recording, but no speech peak reached
    /// −30 dBFS.
    func isTooQuiet(now: Double? = nil) -> Bool {
        guard fresh(now), activeSeconds >= Double(Self.quietWindowSeconds) else { return false }
        let current = Int(activeSeconds)
        var speech = 0.0
        var maxPeak = -160.0
        for b in bins where b.number > current - Self.quietWindowSeconds {
            speech += b.speechSeconds
            maxPeak = max(maxPeak, b.maxSpeechPeakDB)
        }
        return speech >= Self.quietMinSpeechSeconds && maxPeak < Self.tooQuietPeakDB
    }

    /// Someone is speaking while the recording is paused.
    func isTalkingWhilePaused(now: Double? = nil) -> Bool {
        fresh(now) && pausedSpeech >= Self.pausedTalkSeconds
    }
}

/// Thread-safe holder for the microphone analysis, shared by the capture queue (writes), the session
/// actor (health checks) and the UI (meter reads, take summary).
final class MicrophoneMonitor: Sendable {
    private struct State {
        var analyzer = MicrophoneAnalyzer()
        var enabled = false
        var realTime = true
        var summary: MicTakeSummary?
    }
    private let state = Mutex(State())

    /// The take records a microphone (only then is there a summary). `realTime`: buffer times are on
    /// the host clock, so staleness is judged against now.
    func enable(realTime: Bool) { state.withLock { $0.enabled = true; $0.realTime = realTime } }

    /// Whether buffer times are host-clock times.
    var isRealTime: Bool { state.withLock { $0.realTime } }

    func ingest(_ samples: UnsafePointer<Float>, frames: Int, channels: Int, at time: Double, paused: Bool) {
        state.withLock { $0.analyzer.ingest(samples, frames: frames, channels: channels, at: time, paused: paused) }
    }

    /// Live level for the meter. Falls back to silence once buffers stop arriving.
    func reading() -> MicLevelReading {
        let host = HostClock.now()
        return state.withLock { s in
            guard let last = s.analyzer.lastTime else { return MicLevelReading() }
            if s.realTime, host - last > MicrophoneAnalyzer.staleSeconds { return MicLevelReading() }
            return s.analyzer.reading
        }
    }

    struct Health: Sendable {
        var clipEvents = 0
        var tooQuiet = false
        var talkingWhilePaused = false
    }

    func health(now: Double?) -> Health {
        state.withLock { s in
            Health(clipEvents: s.analyzer.clipEvents(now: now), tooQuiet: s.analyzer.isTooQuiet(now: now),
                   talkingWhilePaused: s.analyzer.isTalkingWhilePaused(now: now))
        }
    }

    /// Records the take's unpaused length at stop. Time the microphone delivered nothing (unplugged,
    /// dead driver) counts as silent.
    func finish(activeSeconds: Double) {
        state.withLock { s in
            guard s.enabled else { return }
            s.summary = MicTakeSummary(activeSeconds: max(activeSeconds, 0), soundSeconds: min(s.analyzer.soundSeconds, max(activeSeconds, 0)))
        }
    }

    /// Set after stop when the take had a microphone.
    var summary: MicTakeSummary? { state.withLock { $0.summary } }
}
