import Foundation

/// `voice/stem.json`: describes the rendered voice stem, the enhanced copy of the microphone track that preview
/// and export play instead of the raw microphone. Regenerable: deleting `voice/` only means it renders again.
public struct VoiceStemInfo: Codable, Hashable, Sendable {
    /// Bumped whenever the processing chain changes, so stems from older chains render again.
    public static let chainVersion = 1

    public var version: Int = VoiceStemInfo.chainVersion
    /// The denoiser that ran, e.g. "AUSoundIsolation.hq", or "none" when no denoiser was available.
    public var engine: String
    /// `settingsHash(...)` of the settings and source this stem was rendered from.
    public var settingsHash: String
    public var strength: EnhanceStrength
    public var mix: Double
    /// Bundle-relative raw microphone file that was processed, and its size then.
    public var sourceFile: String
    public var sourceSize: Int64
    /// Bundle-relative stem file (mono, lossless, same sample rate and length as the source).
    public var file: String
    public var sampleRate: Double
    public var frames: Int
    /// Processing delay that was removed, in frames (the stem is sample-aligned with the raw microphone).
    public var latencyFrames: Int
    /// High-pass corner used, in Hz.
    public var highPassHz: Double
    /// Wall-clock seconds the render took.
    public var renderSeconds: Double
    public var createdAt: Date

    public init(engine: String, settingsHash: String, strength: EnhanceStrength, mix: Double, sourceFile: String, sourceSize: Int64,
                file: String, sampleRate: Double, frames: Int, latencyFrames: Int, highPassHz: Double, renderSeconds: Double,
                createdAt: Date = Date()) {
        self.engine = engine; self.settingsHash = settingsHash; self.strength = strength; self.mix = mix
        self.sourceFile = sourceFile; self.sourceSize = sourceSize; self.file = file; self.sampleRate = sampleRate
        self.frames = frames; self.latencyFrames = latencyFrames; self.highPassHz = highPassHz
        self.renderSeconds = renderSeconds; self.createdAt = createdAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? "unknown"
        settingsHash = try c.decodeIfPresent(String.self, forKey: .settingsHash) ?? ""
        strength = (try? c.decodeIfPresent(EnhanceStrength.self, forKey: .strength)) ?? .medium
        mix = try c.decodeIfPresent(Double.self, forKey: .mix) ?? 1
        sourceFile = try c.decodeIfPresent(String.self, forKey: .sourceFile) ?? ""
        sourceSize = try c.decodeIfPresent(Int64.self, forKey: .sourceSize) ?? -1
        file = try c.decodeIfPresent(String.self, forKey: .file) ?? ""
        sampleRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 0
        frames = try c.decodeIfPresent(Int.self, forKey: .frames) ?? 0
        latencyFrames = try c.decodeIfPresent(Int.self, forKey: .latencyFrames) ?? 0
        highPassHz = try c.decodeIfPresent(Double.self, forKey: .highPassHz) ?? 0
        renderSeconds = try c.decodeIfPresent(Double.self, forKey: .renderSeconds) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
    }

    /// The mix as stored and hashed: two decimals, so slider noise doesn't trigger renders.
    public static func quantizedMix(_ mix: Double) -> Double { (min(1, max(0, mix)) * 100).rounded() / 100 }

    /// A stable hash (FNV-1a 64, hex) of everything that changes the stem's samples.
    public static func settingsHash(strength: EnhanceStrength, mix: Double, sourceFile: String, sourceSize: Int64) -> String {
        let key = "v\(chainVersion)|\(strength.rawValue)|\(String(format: "%.2f", quantizedMix(mix)))|\(sourceFile)|\(sourceSize)"
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return String(format: "%016llx", h)
    }
}

/// Where the voice stem stands for a recording and its current settings.
public enum VoiceStemStatus: String, Codable, Hashable, Sendable {
    /// No microphone track, or enhance is off.
    case off
    /// Enhance is on but nothing has been rendered yet.
    case missing
    /// A stem exists, rendered with other settings (it still plays until the new one is ready).
    case stale
    /// The stem matches the current settings.
    case ready
}

extension ProjectBundle {
    /// `voice/`: the rendered voice stem and its `stem.json`.
    public var voiceDirectory: URL { url.appendingPathComponent("voice", isDirectory: true) }
    public var voiceStemInfoURL: URL { voiceDirectory.appendingPathComponent("stem.json") }

    /// `stem.json`, or `nil` when missing or unreadable.
    public func readVoiceStem() -> VoiceStemInfo? {
        guard let d = try? Data(contentsOf: voiceStemInfoURL) else { return nil }
        return try? JSONCoding.decoder.decode(VoiceStemInfo.self, from: d)
    }

    public func writeVoiceStem(_ info: VoiceStemInfo) throws {
        try FileManager.default.createDirectory(at: voiceDirectory, withIntermediateDirectories: true)
        try JSONCoding.writeAtomically(info, to: voiceStemInfoURL)
    }

    /// Size of a bundle file in bytes, or -1 when it doesn't exist.
    public func fileSize(_ relative: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: resolve(relative).path)[.size]) as? NSNumber)?.int64Value ?? -1
    }

    /// The stem when it was rendered from the current raw microphone file with the current chain and its file
    /// exists, whatever settings it used. `nil` otherwise.
    public func usableVoiceStem(manifest: ProjectManifest) -> VoiceStemInfo? {
        guard let raw = manifest.track(.microphone)?.file, let info = readVoiceStem(),
              info.version == VoiceStemInfo.chainVersion, info.sourceFile == raw, !info.file.isEmpty,
              info.sourceSize == fileSize(raw), fileSize(info.file) > 0 else { return nil }
        return info
    }

    /// The hash a stem rendered now with `settings` would carry, or `nil` without a microphone file.
    public func expectedVoiceStemHash(manifest: ProjectManifest, settings: AudioSettings) -> String? {
        guard let raw = manifest.track(.microphone)?.file else { return nil }
        return VoiceStemInfo.settingsHash(strength: settings.enhanceStrength, mix: settings.enhanceMix,
                                          sourceFile: raw, sourceSize: fileSize(raw))
    }

    public func voiceStemStatus(manifest: ProjectManifest, settings: AudioSettings) -> VoiceStemStatus {
        guard settings.enhance, manifest.track(.microphone)?.file != nil else { return .off }
        guard let info = usableVoiceStem(manifest: manifest) else { return .missing }
        return info.settingsHash == expectedVoiceStemHash(manifest: manifest, settings: settings) ? .ready : .stale
    }

    /// The bundle-relative file that carries the voice for `settings`: the stem when enhance is on and one has been
    /// rendered from the current microphone file (even with older settings, until the new one is ready), else
    /// the raw microphone track.
    public func voiceFile(manifest: ProjectManifest, settings: AudioSettings) -> String? {
        guard let raw = manifest.track(.microphone)?.file else { return nil }
        if settings.enhance, let stem = usableVoiceStem(manifest: manifest) { return stem.file }
        return raw
    }
}

/// Energy-based voice activity detection with hangover, for ducking. Works on 10 ms frame levels in dB.
public enum VoiceActivity {
    public static let frameDuration = 0.01

    /// Speech ranges (seconds from the first frame). A frame is speech when its level is 9 dB over the noise
    /// floor (10th percentile) and within 40 dB of the loud speech level (98th percentile), and above −65 dBFS.
    /// Onsets need 30 ms of speech; each range is held 150 ms past its last speech frame (hangover), and gaps
    /// under 200 ms are bridged.
    public static func detect(frameDB: [Float], frameDuration: Double = VoiceActivity.frameDuration) -> [TimeRange] {
        guard frameDB.count > 3 else { return [] }
        let sorted = frameDB.sorted()
        func percentile(_ p: Double) -> Float { sorted[min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))] }
        let floor = percentile(0.10), loud = percentile(0.98)
        let threshold = max(floor + 9, loud - 40, -65)
        guard loud > threshold else { return [] }
        let onset = 3, hangover = Int((0.15 / frameDuration).rounded()), bridge = Int((0.2 / frameDuration).rounded())
        var ranges: [(Int, Int)] = []
        var run = 0, i = 0
        while i < frameDB.count {
            if frameDB[i] > threshold {
                run += 1
                if run == onset {
                    let start = i - onset + 1
                    var end = i
                    var j = i + 1, quiet = 0
                    while j < frameDB.count {
                        if frameDB[j] > threshold { end = j; quiet = 0 } else { quiet += 1; if quiet > hangover + bridge { break } }
                        j += 1
                    }
                    let held = min(frameDB.count, end + 1 + hangover)
                    if let last = ranges.last, start - last.1 <= bridge { ranges[ranges.count - 1].1 = held } else { ranges.append((start, held)) }
                    i = j; run = 0
                    continue
                }
            } else {
                run = 0
            }
            i += 1
        }
        return ranges.map { TimeRange(start: Double($0.0) * frameDuration, end: Double($0.1) * frameDuration) }
    }
}

/// Gain automation for ducking system audio under the voice, as a pure function of output time so preview,
/// seeks and export all agree. The duck starts `attack` before each speech range (the speech ranges are known
/// ahead of time), holds `depthDB` through it, and recovers over `release` after it. Ramps are linear in dB.
public struct DuckCurve: Hashable, Sendable {
    /// Speech ranges on the output timeline, sorted and non-overlapping.
    public let ranges: [TimeRange]
    public var depthDB: Double = 12
    public var attack: Double = 0.02
    public var release: Double = 0.6

    public init(outputRanges: [TimeRange]) {
        var merged: [TimeRange] = []
        for r in outputRanges.sorted(by: { $0.start < $1.start }) where r.duration > 0 {
            if let last = merged.last, r.start <= last.end { merged[merged.count - 1].end = max(last.end, r.end) } else { merged.append(r) }
        }
        ranges = merged
    }

    /// Maps speech ranges on the recording timeline onto the edited output timeline.
    public init(recordingRanges: [TimeRange], timeline: EditTimeline) {
        var out: [TimeRange] = []
        var acc = 0.0
        for k in timeline.kept {
            for r in recordingRanges where r.overlaps(k) {
                out.append(TimeRange(start: acc + max(r.start, k.start) - k.start, end: acc + min(r.end, k.end) - k.start))
            }
            acc += k.duration
        }
        self.init(outputRanges: out)
    }

    /// How far ducked at `t`, 0 (not at all) … 1 (fully).
    public func depth(at t: Double) -> Double {
        // Index of the last range whose attack has begun by t.
        var lo = 0, hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ranges[mid].start - attack <= t { lo = mid + 1 } else { hi = mid }
        }
        var d = 0.0
        for k in max(0, lo - 2)..<lo {
            let r = ranges[k]
            let c: Double = t < r.end ? min(1, max(0, (t - (r.start - attack)) / attack)) : max(0, 1 - (t - r.end) / release)
            d = max(d, c)
        }
        return d
    }

    /// Linear gain at `t`.
    public func gain(at t: Double) -> Float {
        let d = depth(at: t)
        return d <= 0 ? 1 : Float(pow(10, -depthDB * d / 20))
    }

    /// Whether any ducking happens between `a` and `b`.
    public func isActive(from a: Double, to b: Double) -> Bool {
        ranges.contains { $0.start - attack < b && $0.end + release > a }
    }
}
