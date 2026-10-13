import Foundation

/// The microphone's live level in dBFS, for the HUD meter and its target zone. Read alongside
/// `RecorderStatus` (whose `microphoneLevel` stays the 0...1 RMS meter value).
public struct MicLevelReading: Codable, Hashable, Sendable {
    /// Recent peak, held briefly and then falling (like a peak meter). `-infinity`-free: silence is `floorDB`.
    public var peakDB: Double
    /// Recent RMS level.
    public var rmsDB: Double

    public init(peakDB: Double = MicLevelReading.floorDB, rmsDB: Double = MicLevelReading.floorDB) {
        self.peakDB = peakDB; self.rmsDB = rmsDB
    }

    /// Where speech peaks should land: loud enough to sit above the noise, with headroom before clipping.
    public static let targetPeakRange: ClosedRange<Double> = -18 ... -6
    /// Bottom of the meter scale (same scale as `RecorderStatus.microphoneLevel`).
    public static let floorDB = -60.0
    /// Peaks at or above this are clipping.
    public static let clipDB = -0.5

    /// Maps dBFS to the 0...1 meter scale (-60 dBFS ... 0 dBFS).
    public static func meterPosition(_ db: Double) -> Double {
        guard db.isFinite else { return 0 }
        return min(1, max(0, (db - floorDB) / -floorDB))
    }

    /// Converts a linear amplitude (0...1) to dBFS, clamped to -160.
    public static func dB(_ linear: Double) -> Double {
        linear > 1e-8 ? 20 * log10(linear) : -160
    }

    public var peakPosition: Double { Self.meterPosition(peakDB) }
    public var rmsPosition: Double { Self.meterPosition(rmsDB) }
}

/// How much the microphone picked up over a whole take (pauses excluded). Built from the recorder's
/// running stats at stop, without reading the file back.
public struct MicTakeSummary: Codable, Hashable, Sendable {
    /// Recording time with the microphone on, pauses excluded.
    public var activeSeconds: Double
    /// Time the microphone delivered something above silence (speech-like or louder than -60 dBFS).
    public var soundSeconds: Double

    public init(activeSeconds: Double, soundSeconds: Double) {
        self.activeSeconds = activeSeconds; self.soundSeconds = soundSeconds
    }

    /// Above this silent fraction the take is treated as "the mic didn't pick anything up".
    public static let silentFractionLimit = 0.9
    /// Takes shorter than this never prompt.
    public static let minimumSeconds = 2.0

    public var silentFraction: Double {
        guard activeSeconds > 0 else { return 0 }
        return min(1, max(0, 1 - soundSeconds / activeSeconds))
    }

    /// Whether to offer "Record Again" after stop.
    public var isEssentiallySilent: Bool {
        activeSeconds >= Self.minimumSeconds && silentFraction > Self.silentFractionLimit
    }
}
