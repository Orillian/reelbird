import Foundation

/// One piece of sensitive text seen in one sampled frame.
public struct SensitiveSighting: Hashable, Sendable {
    public var kind: SensitiveKind
    /// Normalised text (`SensitivePatterns.normalize`), used to recognise it again in the next sample.
    public var value: String
    /// Where it is, in normalized screen coordinates (already padded).
    public var rect: NormRect
    public init(kind: SensitiveKind, value: String, rect: NormRect) { self.kind = kind; self.value = value; self.rect = rect }
}

/// Everything found in one sampled frame at recording time `t`.
public struct SensitiveSample: Hashable, Sendable {
    public var t: Double
    public var sightings: [SensitiveSighting]
    public init(t: Double, sightings: [SensitiveSighting]) { self.t = t; self.sightings = sightings }
}

/// A piece of sensitive text followed through the recording: when it is on screen and where.
public struct SensitiveDetection: Codable, Hashable, Sendable, Identifiable {
    /// Stable for the same recording and settings: kind, text and first sighting, hashed.
    public var id: String
    public var kind: SensitiveKind
    /// Masked text, safe to show and log (`SensitivePatterns.mask`).
    public var preview: String
    /// When to hide it (recording timeline): from the sample before it was first seen to the sample after it
    /// was last seen.
    public var range: TimeRange
    /// The area covering it over the whole range.
    public var rect: NormRect
    /// Where it is over time (sorted; between two keys a blur covers both).
    public var keys: [Annotation.Key]
    /// When it was first seen (for a thumbnail).
    public var firstSeen: Double
    /// Samples it was seen in.
    public var sightings: Int

    public init(id: String, kind: SensitiveKind, preview: String, range: TimeRange, rect: NormRect, keys: [Annotation.Key],
                firstSeen: Double, sightings: Int) {
        self.id = id; self.kind = kind; self.preview = preview; self.range = range; self.rect = rect
        self.keys = keys; self.firstSeen = firstSeen; self.sightings = sightings
    }

    /// The blur that hides it.
    public func annotation(style: Annotation.BlurStyle = .blur, strength: Double = Annotation.defaultStrength) -> Annotation {
        var a = Annotation(id: id, kind: .blur, range: range, rect: rect)
        a.style = style
        a.strength = strength
        a.keys = Set(keys.map(\.rect)).count > 1 ? keys : nil
        if a.keys == nil, let only = keys.first { a.rect = only.rect }
        a.detected = kind.rawValue
        return a
    }
}

/// Links sightings across sampled frames into detections. Two sightings in neighbouring samples are the same
/// item when they are the same kind with the same (or nearly the same, allowing for a misread character) text;
/// where one text shows several times, the nearest box continues each. A box that moves between samples (the
/// text scrolled) adds a key, so the blur follows it.
public enum SensitiveTracker {
    /// - Parameters:
    ///   - samples: OCR'd frames (sorted or not).
    ///   - duration: recording length (the last detection can run to it).
    ///   - maxGap: an item missing from the samples for longer than this is a new item when it comes back.
    public static func link(samples: [SensitiveSample], duration: Double, maxGap: Double = 1.2) -> [SensitiveDetection] {
        linkWithValues(samples: samples, duration: duration, maxGap: maxGap).map(\.detection)
    }

    /// `link`, with each detection's (unmasked, normalised) text, for the scanner's own use. Don't log the values.
    public static func linkWithValues(samples: [SensitiveSample], duration: Double,
                                      maxGap: Double = 1.2) -> [(detection: SensitiveDetection, value: String)] {
        let samples = samples.sorted { $0.t < $1.t }
        struct Track {
            var kind: SensitiveKind
            /// The first reading (keeps the ID stable) and how often each reading was seen.
            var value: String
            var readings: [String: Int]
            var obs: [(t: Double, rect: NormRect, sample: Int)]
            /// The sample before the first sighting (when it wasn't there yet), or nil at the start.
            var before: Double?
        }
        var open: [Track] = []
        var closed: [Track] = []
        for (i, s) in samples.enumerated() {
            let sightings = merged(s.sightings)
            // Close tracks not seen for too long.
            var still: [Track] = []
            for tr in open {
                if let last = tr.obs.last, s.t - last.t > maxGap { closed.append(tr) } else { still.append(tr) }
            }
            open = still
            // Greedy one-to-one assignment by box distance among compatible pairs: the same kind, and the same
            // text (allowing misreads) or the same place (text read differently from one frame to the next).
            var pairs: [(track: Int, sighting: Int, cost: Double)] = []
            for (ti, tr) in open.enumerated() {
                let lastRect = tr.obs.last!.rect
                for (si, sg) in sightings.enumerated() where sg.kind == tr.kind {
                    let sameText = tr.readings[sg.value] != nil || similar(sg.value, tr.value)
                    guard sameText || overlapRatio(lastRect, sg.rect) >= 0.4 else { continue }
                    let a = lastRect.center, b = sg.rect.center
                    pairs.append((ti, si, hypot(a.x - b.x, a.y - b.y) + (sameText ? 0 : 0.5)))
                }
            }
            pairs.sort { ($0.cost, $0.track, $0.sighting) < ($1.cost, $1.track, $1.sighting) }
            var usedTracks = Set<Int>(), usedSightings = Set<Int>()
            for p in pairs where !usedTracks.contains(p.track) && !usedSightings.contains(p.sighting) {
                usedTracks.insert(p.track); usedSightings.insert(p.sighting)
                let sg = sightings[p.sighting]
                let last = open[p.track].obs.last!.rect
                // A box that moved by less than a fifth of a line is the same place read slightly differently:
                // keep one steady area (covering both) instead of a jittering one.
                let rect = nearlySame(last, sg.rect) ? last.union(sg.rect) : sg.rect
                open[p.track].obs.append((s.t, rect, i))
                open[p.track].readings[sg.value, default: 0] += 1
            }
            for (si, sg) in sightings.enumerated() where !usedSightings.contains(si) {
                open.append(Track(kind: sg.kind, value: sg.value, readings: [sg.value: 1], obs: [(s.t, sg.rect, i)],
                                  before: i > 0 ? samples[i - 1].t : nil))
            }
        }
        closed += open
        return closed.map { tr in
            let first = tr.obs.first!, last = tr.obs.last!
            let start = max(0, tr.before ?? 0)
            let after = last.sample + 1 < samples.count ? samples[last.sample + 1].t : max(duration, last.t)
            let end = min(max(duration, last.t), after)
            var keys: [Annotation.Key] = [Annotation.Key(t: start, rect: first.rect)]
            for o in tr.obs { keys.append(Annotation.Key(t: o.t, rect: o.rect)) }
            keys.append(Annotation.Key(t: end, rect: last.rect))
            keys = simplified(keys)
            let bbox = keys.dropFirst().reduce(keys[0].rect) { $0.union($1.rect) }
            let d = SensitiveDetection(id: stableID(tr.kind, tr.value, first.t, first.rect), kind: tr.kind,
                                       preview: SensitivePatterns.mask(tr.readings.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? tr.value,
                                                                       kind: tr.kind),
                                       range: TimeRange(start: start, end: max(end, start + Annotation.minimumDuration)),
                                       rect: bbox, keys: keys, firstSeen: first.t, sightings: tr.obs.count)
            return (d, tr.value)
        }
        .sorted { a, b in
            (a.detection.range.start, a.detection.rect.y, a.detection.rect.x, a.detection.id)
                < (b.detection.range.start, b.detection.rect.y, b.detection.rect.x, b.detection.id)
        }
    }

    /// Sightings of one kind in one frame that overlap (one key read as two matches) become one, with the
    /// longer reading.
    static func merged(_ sightings: [SensitiveSighting]) -> [SensitiveSighting] {
        var out: [SensitiveSighting] = []
        for sg in sightings {
            if let i = out.firstIndex(where: { $0.kind == sg.kind && overlapRatio($0.rect, sg.rect) >= 0.5 }) {
                let keep = out[i].value.count >= sg.value.count ? out[i].value : sg.value
                out[i] = SensitiveSighting(kind: sg.kind, value: keep, rect: out[i].rect.union(sg.rect))
            } else {
                out.append(sg)
            }
        }
        return out
    }

    /// Overlap area over the smaller box's area (1 = one inside the other).
    static func overlapRatio(_ a: NormRect, _ b: NormRect) -> Double {
        guard let i = a.intersection(b) else { return 0 }
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 ? i.width * i.height / smaller : 0
    }

    /// The same box to within a fifth of its height in position and a tenth in size.
    static func nearlySame(_ a: NormRect, _ b: NormRect) -> Bool {
        let h = max(a.height, b.height)
        return abs(a.x - b.x) <= 0.2 * h && abs(a.y - b.y) <= 0.2 * h
            && abs(a.width - b.width) <= 0.1 * max(a.width, b.width) + 0.2 * h && abs(a.height - b.height) <= 0.2 * h
    }

    /// Drops keys that repeat both neighbours (and equal-time duplicates), keeping the first and last.
    static func simplified(_ keys: [Annotation.Key]) -> [Annotation.Key] {
        var out: [Annotation.Key] = []
        for (i, k) in keys.enumerated() {
            if let last = out.last, abs(last.t - k.t) < 1e-9 { out[out.count - 1] = k; continue }
            if i > 0, i < keys.count - 1, let last = out.last, last.rect == k.rect, keys[i + 1].rect == k.rect { continue }
            out.append(k)
        }
        // Two keys with one area say no more than one.
        if out.count == 2, out[0].rect == out[1].rect { return [out[0], out[1]] }
        return out
    }

    /// Same text, or one misread character per ten (OCR differs a little between frames).
    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let n = min(a.count, b.count)
        guard n >= 6, abs(a.count - b.count) <= max(1, n / 10) else { return false }
        return editDistance(a, b, limit: max(1, n / 10)) <= max(1, n / 10)
    }

    /// Levenshtein distance, giving up (returning `limit + 1`) once every path exceeds `limit`.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > limit { return limit + 1 }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// `s` + 8 hex digits of an FNV-1a hash: the same text first seen at the same moment and place keeps its ID
    /// across scans.
    static func stableID(_ kind: SensitiveKind, _ value: String, _ t: Double, _ r: NormRect) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        let c = r.center
        let key = "\(kind.rawValue)|\(value)|\(Int((t * 10).rounded()))|\(Int((c.x * 50).rounded()))|\(Int((c.y * 50).rounded()))"
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return "s" + String(format: "%08x", UInt32(truncatingIfNeeded: h ^ (h >> 32)))
    }
}
