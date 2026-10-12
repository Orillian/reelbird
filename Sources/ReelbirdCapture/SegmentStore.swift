import Foundation
import ReelbirdCore

/// Reads the fMP4 segments of a track directory, validates them and concatenates them into one file.
/// Pure byte-level work (no AVFoundation), so it also runs synchronously during crash recovery.
enum SegmentStore {
    struct TrackSummary: Sendable, Hashable {
        /// Relative path inside the bundle, e.g. "screen/screen.mp4".
        var file: String
        var segmentCount: Int
        /// Seconds of media in the consolidated file (longest track inside it).
        var duration: Double
        var codec: String
        var pixelSize: PixelSize?
        var sampleRate: Int?
        var channels: Int?
    }

    static func segmentFiles(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        // Numeric order, so seg_100000 (past ~55 h at 2 s) still sorts after seg_99999.
        return names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("seg_"), name.hasSuffix(".m4s"), let n = Int(name.dropFirst(4).dropLast(4)) else { return nil }
            return (n, name)
        }
        .sorted { $0.0 < $1.0 }
        .map { directory.appendingPathComponent($0.1) }
    }

    /// Concatenates `init.mp4` and every complete segment (in order, stopping at the first damaged one)
    /// into `<kind>.mp4` in the track directory. Returns `nil` when there is nothing playable.
    static func consolidate(directory: URL, kind: TrackKind) throws -> TrackSummary? {
        let initURL = directory.appendingPathComponent("init.mp4")
        guard let initData = try? Data(contentsOf: initURL), MP4.isValidInit(initData) else { return nil }
        let info = MP4.initInfo(initData)
        let outName = "\(kind.rawValue).mp4"
        let outURL = directory.appendingPathComponent(outName)
        let tmpURL = directory.appendingPathComponent(".\(outName).partial")
        FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmpURL)
        var ok = false
        defer {
            try? handle.close()
            if !ok { try? FileManager.default.removeItem(at: tmpURL) }
        }
        try handle.write(contentsOf: initData)
        var count = 0
        var firstStart: [UInt32: UInt64] = [:]
        var lastEnd: [UInt32: UInt64] = [:]
        for url in segmentFiles(in: directory) {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let frags = MP4.fragments(data) else { break }  // truncated: everything after it is unusable
            for f in frags {
                if firstStart[f.trackID] == nil { firstStart[f.trackID] = f.baseDecodeTime }
                lastEnd[f.trackID] = max(lastEnd[f.trackID] ?? 0, f.baseDecodeTime + f.duration)
            }
            try handle.write(contentsOf: data)
            count += 1
        }
        guard count > 0 else { return nil }
        try handle.synchronize()
        try handle.close()
        if FileManager.default.fileExists(atPath: outURL.path) { try FileManager.default.removeItem(at: outURL) }
        try FileManager.default.moveItem(at: tmpURL, to: outURL)
        ok = true
        var duration = 0.0
        for (track, end) in lastEnd {
            let scale = Double(info.timescales[track] ?? info.timescales.values.first ?? 1)
            duration = max(duration, Double(end - min(end, firstStart[track] ?? 0)) / max(1, scale))
        }
        return TrackSummary(file: "\(directory.lastPathComponent)/\(outName)", segmentCount: count, duration: duration,
                            codec: info.codec, pixelSize: info.pixelSize, sampleRate: info.sampleRate, channels: info.channels)
    }
}

/// Minimal ISO-BMFF box reading: enough to validate fMP4 segments and sum fragment durations.
enum MP4 {
    struct Box {
        var type: String
        var start: Int
        var headerSize: Int
        var size: Int
        var payload: Range<Int> { (start + headerSize)..<(start + size) }
    }

    struct Fragment {
        var trackID: UInt32
        var baseDecodeTime: UInt64
        var duration: UInt64
    }

    struct InitInfo {
        var timescales: [UInt32: UInt32] = [:]
        var defaultDurations: [UInt32: UInt32] = [:]
        var codec = "unknown"
        var pixelSize: PixelSize?
        var sampleRate: Int?
        var channels: Int?
    }

    /// Boxes inside `range`; `nil` if any box is malformed or runs past the end (truncated file).
    static func boxes(_ d: Data, in range: Range<Int>) -> [Box]? {
        var out: [Box] = []
        var p = range.lowerBound
        while p < range.upperBound {
            guard range.upperBound - p >= 8 else { return nil }
            var size = Int(u32(d, p))
            let type = fourCC(d, p + 4)
            var header = 8
            if size == 1 {
                guard range.upperBound - p >= 16 else { return nil }
                size = Int(u64(d, p + 8)); header = 16
            } else if size == 0 {
                size = range.upperBound - p
            }
            guard size >= header, p + size <= range.upperBound else { return nil }
            out.append(Box(type: type, start: p, headerSize: header, size: size))
            p += size
        }
        return out
    }

    static func isValidInit(_ d: Data) -> Bool {
        guard let top = boxes(d, in: 0..<d.count) else { return false }
        return top.contains { $0.type == "moov" }
    }

    /// Fragments in a media segment, or `nil` if it is truncated or has no complete moof + mdat.
    static func fragments(_ data: Data) -> [Fragment]? {
        let d = data
        guard let top = boxes(d, in: 0..<d.count) else { return nil }
        var out: [Fragment] = []
        var sawMdat = false
        for b in top where b.type == "moof" {
            guard let children = boxes(d, in: b.payload) else { return nil }
            for traf in children where traf.type == "traf" {
                guard let parts = boxes(d, in: traf.payload) else { return nil }
                var track: UInt32 = 0, base: UInt64 = 0, defaultDuration: UInt32 = 0, total: UInt64 = 0
                for part in parts {
                    let p = part.payload.lowerBound
                    switch part.type {
                    case "tfhd":
                        let flags = u32(d, p) & 0xFFFFFF
                        track = u32(d, p + 4)
                        var q = p + 8
                        if flags & 0x01 != 0 { q += 8 }
                        if flags & 0x02 != 0 { q += 4 }
                        if flags & 0x08 != 0 { defaultDuration = u32(d, q) }
                    case "tfdt":
                        base = u8(d, p) == 1 ? u64(d, p + 4) : UInt64(u32(d, p + 4))
                    case "trun":
                        let flags = u32(d, p) & 0xFFFFFF
                        let count = Int(u32(d, p + 4))
                        var q = p + 8
                        if flags & 0x01 != 0 { q += 4 }
                        if flags & 0x04 != 0 { q += 4 }
                        let fieldCount = [0x100, 0x200, 0x400, 0x800].filter { flags & UInt32($0) != 0 }.count
                        if flags & 0x100 != 0 {
                            guard q + count * fieldCount * 4 <= part.payload.upperBound else { return nil }
                            for i in 0..<count { total += UInt64(u32(d, q + i * fieldCount * 4)) }
                        } else {
                            total += UInt64(count) * UInt64(defaultDuration)
                        }
                    default: break
                    }
                }
                out.append(Fragment(trackID: track, baseDecodeTime: base, duration: total))
            }
        }
        sawMdat = top.contains { $0.type == "mdat" }
        return out.isEmpty || !sawMdat ? nil : out
    }

    static func initInfo(_ d: Data) -> InitInfo {
        var info = InitInfo()
        guard let top = boxes(d, in: 0..<d.count), let moov = top.first(where: { $0.type == "moov" }),
              let moovKids = boxes(d, in: moov.payload) else { return info }
        for trak in moovKids where trak.type == "trak" {
            guard let kids = boxes(d, in: trak.payload) else { continue }
            var trackID: UInt32 = 0
            if let tkhd = kids.first(where: { $0.type == "tkhd" }) {
                let p = tkhd.payload.lowerBound
                trackID = u8(d, p) == 1 ? u32(d, p + 20) : u32(d, p + 12)
            }
            if let mdia = kids.first(where: { $0.type == "mdia" }), let mk = boxes(d, in: mdia.payload),
               let mdhd = mk.first(where: { $0.type == "mdhd" }) {
                let p = mdhd.payload.lowerBound
                info.timescales[trackID] = u8(d, p) == 1 ? u32(d, p + 20) : u32(d, p + 12)
            }
        }
        if let mvex = moovKids.first(where: { $0.type == "mvex" }), let mk = boxes(d, in: mvex.payload) {
            for trex in mk where trex.type == "trex" {
                let p = trex.payload.lowerBound
                info.defaultDurations[u32(d, p + 4)] = u32(d, p + 12)
            }
        }
        // Sample entries: find the first video and audio codec 4CC inside the init segment.
        for (cc, name) in [("hvc1", "hevc"), ("hev1", "hevc"), ("avc1", "h264"), ("avc3", "h264")] {
            if let pos = find(d, cc), pos + 32 <= d.count {
                info.codec = name
                info.pixelSize = PixelSize(width: Int(u16(d, pos + 28)), height: Int(u16(d, pos + 30)))
                break
            }
        }
        if let pos = find(d, "mp4a"), pos + 32 <= d.count {
            if info.pixelSize == nil { info.codec = "aac" }
            info.channels = Int(u16(d, pos + 20))
            info.sampleRate = Int(u32(d, pos + 28) >> 16)
        }
        return info
    }

    // MARK: Byte helpers

    static func find(_ d: Data, _ cc: String) -> Int? {
        let pattern = Array(cc.utf8)
        return d.withUnsafeBytes { raw -> Int? in
            let b = raw.bindMemory(to: UInt8.self)
            guard b.count >= 4 else { return nil }
            for i in 4..<(b.count - 3) where b[i] == pattern[0] && b[i + 1] == pattern[1] && b[i + 2] == pattern[2] && b[i + 3] == pattern[3] {
                return i
            }
            return nil
        }
    }

    @inline(__always) static func u8(_ d: Data, _ p: Int) -> UInt8 { d[d.startIndex + p] }

    @inline(__always) static func u16(_ d: Data, _ p: Int) -> UInt16 {
        let i = d.startIndex + p
        return UInt16(d[i]) << 8 | UInt16(d[i + 1])
    }

    @inline(__always) static func u32(_ d: Data, _ p: Int) -> UInt32 {
        let i = d.startIndex + p
        return UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
    }

    @inline(__always) static func u64(_ d: Data, _ p: Int) -> UInt64 { UInt64(u32(d, p)) << 32 | UInt64(u32(d, p + 4)) }

    static func fourCC(_ d: Data, _ p: Int) -> String {
        let i = d.startIndex + p
        return String(decoding: d[i..<(i + 4)], as: UTF8.self)
    }
}

/// Rebuilds bundles left in the `.recording` state by a crash or force quit.
public enum ProjectRecovery {
    /// If the bundle's manifest still says `.recording`, consolidates whatever complete segments exist
    /// (a truncated last segment is ignored), recomputes the duration and marks the project `.recovered`.
    /// Returns `true` if the bundle was recovered, `false` if it didn't need it.
    @discardableResult
    public static func recoverIfNeeded(_ bundle: ProjectBundle) throws -> Bool {
        var manifest = try bundle.readManifest()
        guard manifest.status == .recording else { return false }
        var end = 0.0
        for kind in TrackKind.allCases {
            let dir = bundle.directory(for: kind)
            guard let summary = try SegmentStore.consolidate(directory: dir, kind: kind) else {
                manifest.tracks.removeAll { $0.kind == kind && $0.file == nil && $0.segmentCount == 0 }
                continue
            }
            var track = manifest.track(kind) ?? TrackInfo(kind: kind, directory: kind.rawValue, codec: summary.codec)
            track.file = summary.file
            track.codec = summary.codec
            track.pixelSize = summary.pixelSize ?? track.pixelSize
            track.sampleRate = summary.sampleRate ?? track.sampleRate
            track.channels = summary.channels ?? track.channels
            track.segmentCount = summary.segmentCount
            track.duration = summary.duration
            manifest.tracks.removeAll { $0.kind == kind }
            manifest.tracks.append(track)
            end = max(end, track.startTime + track.duration)
        }
        manifest.tracks.sort { TrackKind.allCases.firstIndex(of: $0.kind)! < TrackKind.allCases.firstIndex(of: $1.kind)! }
        manifest.duration = end
        manifest.pauses = manifest.pauses.filter { $0.start < end }.map { TimeRange(start: $0.start, end: min($0.end, end)) }
        manifest.status = .recovered
        try bundle.writeManifest(manifest)
        return true
    }
}
