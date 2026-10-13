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
        /// Every segment on disk went into the file (none was cut short or damaged), so the segments
        /// can be deleted without losing anything.
        var includesEverySegment = true
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
    ///
    /// The copy goes to a uniquely named hidden file, is flushed with `F_FULLFSYNC`, read back and checked
    /// (size and box structure), and only then renamed into place, so an interrupted or concurrent
    /// consolidation never leaves a broken `<kind>.mp4`.
    static func consolidate(directory: URL, kind: TrackKind) throws -> TrackSummary? {
        let initURL = directory.appendingPathComponent("init.mp4")
        guard let initData = try? Data(contentsOf: initURL), MP4.isValidInit(initData) else { return nil }
        let info = MP4.initInfo(initData)
        let outName = "\(kind.rawValue).mp4"
        let outURL = directory.appendingPathComponent(outName)
        let tmpURL = directory.appendingPathComponent(".\(outName).\(UInt32.random(in: 0...UInt32.max)).partial")
        guard FileManager.default.createFile(atPath: tmpURL.path, contents: nil) else {
            throw DurableFile.posixError(errno == 0 ? EIO : errno, tmpURL)
        }
        let handle = try FileHandle(forWritingTo: tmpURL)
        var ok = false
        var closed = false
        defer {
            if !closed { try? handle.close() }
            if !ok { try? FileManager.default.removeItem(at: tmpURL) }
        }
        try handle.write(contentsOf: initData)
        var count = 0
        var bytes = Int64(initData.count)
        var firstStart: [UInt32: UInt64] = [:]
        var lastEnd: [UInt32: UInt64] = [:]
        let segments = segmentFiles(in: directory)
        for url in segments {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let frags = MP4.fragments(data) else { break }  // truncated: everything after it is unusable
            for f in frags {
                if firstStart[f.trackID] == nil { firstStart[f.trackID] = f.baseDecodeTime }
                lastEnd[f.trackID] = max(lastEnd[f.trackID] ?? 0, f.baseDecodeTime + f.duration)
            }
            try handle.write(contentsOf: data)
            bytes += Int64(data.count)
            count += 1
        }
        guard count > 0 else { return nil }
        try DurableFile.flush(handle.fileDescriptor, .full, tmpURL)
        try handle.close()
        closed = true
        guard verify(tmpURL, expectedBytes: bytes) else {
            throw CaptureError.consolidationFailed(kind, "the copied file didn't read back correctly")
        }
        if FileManager.default.fileExists(atPath: outURL.path) { try FileManager.default.removeItem(at: outURL) }
        try FileManager.default.moveItem(at: tmpURL, to: outURL)
        ok = true
        DurableFile.syncDirectory(directory)
        var duration = 0.0
        for (track, end) in lastEnd {
            let scale = Double(info.timescales[track] ?? info.timescales.values.first ?? 1)
            duration = max(duration, Double(end - min(end, firstStart[track] ?? 0)) / max(1, scale))
        }
        return TrackSummary(file: "\(directory.lastPathComponent)/\(outName)", segmentCount: count, duration: duration,
                            codec: info.codec, pixelSize: info.pixelSize, sampleRate: info.sampleRate, channels: info.channels,
                            includesEverySegment: count == segments.count)
    }

    /// Reads a consolidated file back from disk: the expected size, a movie header and complete,
    /// well-formed top-level boxes with at least one fragment.
    static func verify(_ url: URL, expectedBytes: Int64) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.int64Value == expectedBytes,
              let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let top = MP4.boxes(data, in: 0..<data.count) else { return false }
        return top.contains { $0.type == "moov" } && top.contains { $0.type == "moof" } && top.contains { $0.type == "mdat" }
    }

    /// Describes an already consolidated `<kind>.mp4` (used when `project.json` has to be rebuilt).
    static func summarize(file url: URL, relativePath: String) -> TrackSummary? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), MP4.isValidInit(data),
              let frags = MP4.fragments(data) else { return nil }
        let info = MP4.initInfo(data)
        var firstStart: [UInt32: UInt64] = [:]
        var lastEnd: [UInt32: UInt64] = [:]
        for f in frags {
            if firstStart[f.trackID] == nil { firstStart[f.trackID] = f.baseDecodeTime }
            lastEnd[f.trackID] = max(lastEnd[f.trackID] ?? 0, f.baseDecodeTime + f.duration)
        }
        var duration = 0.0
        for (track, end) in lastEnd {
            let scale = Double(info.timescales[track] ?? info.timescales.values.first ?? 1)
            duration = max(duration, Double(end - min(end, firstStart[track] ?? 0)) / max(1, scale))
        }
        return TrackSummary(file: relativePath, segmentCount: 0, duration: duration, codec: info.codec,
                            pixelSize: info.pixelSize, sampleRate: info.sampleRate, channels: info.channels, includesEverySegment: true)
    }

    /// See `ProjectBundle.removeSegments(of:)`.
    @discardableResult
    static func removeSegments(directory: URL, kind: TrackKind) -> Int64 {
        ProjectBundle.removeSegments(in: directory, kind: kind)
    }

    /// Whether a track directory still holds segments (a take not yet cleaned up, or a live upload's).
    static func hasSegments(_ directory: URL) -> Bool { !segmentFiles(in: directory).isEmpty }
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
    public enum Failure: LocalizedError, Equatable {
        /// A recorder is still writing the take (it holds the bundle's lock and `project.json` changed in
        /// the last few seconds).
        case stillRecording
        /// `project.json` is unreadable and there's no screen track to rebuild it from.
        case nothingToRecover

        public var errorDescription: String? {
            switch self {
            case .stillRecording: "This recording is still in progress. Stop it first."
            case .nothingToRecover: "The project file is damaged and no recorded screen video was found."
            }
        }
    }

    /// Whether `bundle` looks like it needs `recoverIfNeeded`: its manifest says `.recording`, or the
    /// manifest is unreadable but recorded media is there. Cheap; doesn't take the lock.
    public static func needsRecovery(_ bundle: ProjectBundle) -> Bool {
        if let m = try? bundle.readManifest() { return m.status == .recording }
        guard FileManager.default.fileExists(atPath: bundle.url.path) else { return false }
        let screen = bundle.directory(for: .screen)
        return FileManager.default.fileExists(atPath: screen.appendingPathComponent("init.mp4").path)
            || FileManager.default.fileExists(atPath: screen.appendingPathComponent("screen.mp4").path)
    }

    /// If the bundle's manifest still says `.recording`, consolidates whatever complete segments exist
    /// (a truncated last segment is ignored), recomputes the duration and marks the project `.recovered`.
    /// A damaged `project.json` is rebuilt from the track folders and `events.jsonl` first.
    ///
    /// Holds the bundle's lock (`BundleLock`) throughout, so the app, the CLI and the MCP server never
    /// rebuild the same bundle at once. `waitForLock == false` returns `false` at once when someone else
    /// holds it (a recorder still finishing, or another recovery); `true` waits, then finds the work done.
    /// Blocks, so call it off the main thread.
    ///
    /// Once the project is safely marked `.recovered`, the segments of every track that went into its
    /// consolidated file in full are deleted (`share/` stays until its upload is finished).
    /// Returns `true` if the bundle was recovered, `false` if it didn't need it.
    @discardableResult
    public static func recoverIfNeeded(_ bundle: ProjectBundle, waitForLock: Bool = true) throws -> Bool {
        let before = try? bundle.readManifest()
        if let m = before {
            guard m.status == .recording else { return false }
        } else if !needsRecovery(bundle) {
            // Neither a readable manifest nor media: surface the original read error.
            _ = try bundle.readManifest()
            return false
        }
        // A free lock means no recorder is alive for this take (the kernel drops a crashed process's lock).
        var held = try BundleLock.acquire(bundle, purpose: .recovering, wait: false)
        if held == nil {
            guard waitForLock else { return false }
            // A recorder mid-take (project.json still changing): waiting would block until it stops.
            if BundleLock.holder(bundle) == .recording, let m = before, bundle.wasWrittenRecently(m) { throw Failure.stillRecording }
            // Otherwise a recorder is consolidating its take or another recovery runs: wait, then re-check.
            held = try BundleLock.acquire(bundle, purpose: .recovering, wait: true)
        }
        guard let lock = held else { return false }
        defer { lock.release() }

        var manifest: ProjectManifest
        var rebuilt = false
        do {
            manifest = try bundle.readManifest()
        } catch {
            guard let m = rebuildManifest(bundle) else { throw Failure.nothingToRecover }
            manifest = m
            rebuilt = true
        }
        guard manifest.status == .recording else {
            // Rebuilt from finished files only (the take was complete): write it back and stop.
            if rebuilt { try bundle.writeManifest(manifest) }
            return rebuilt
        }

        var end = 0.0
        var cleanable: [TrackKind] = []
        for kind in TrackKind.allCases {
            let dir = bundle.directory(for: kind)
            // Temporary files of writes the crash interrupted (never renamed into place). Safe to delete:
            // we hold the lock, so no other consolidation is writing here.
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            where name.hasPrefix(".") && (name.hasSuffix(".tmp") || name.hasSuffix(".partial")) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
            guard let summary = try SegmentStore.consolidate(directory: dir, kind: kind) else {
                if let existing = manifest.track(kind), let file = existing.file,
                   FileManager.default.fileExists(atPath: bundle.resolve(file).path), !SegmentStore.hasSegments(dir) {
                    // Already consolidated (and its segments removed) before the interruption.
                    end = max(end, existing.startTime + existing.duration)
                    continue
                }
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
            if summary.includesEverySegment && kind != .share { cleanable.append(kind) }
        }
        manifest.tracks.sort { TrackKind.allCases.firstIndex(of: $0.kind)! < TrackKind.allCases.firstIndex(of: $1.kind)! }
        manifest.duration = end
        manifest.pauses = manifest.pauses.filter { $0.start < end }.map { TimeRange(start: $0.start, end: min($0.end, end)) }
        manifest.status = .recovered
        try bundle.writeManifest(manifest)   // fully flushed before anything is deleted
        for kind in cleanable { SegmentStore.removeSegments(directory: bundle.directory(for: kind), kind: kind) }
        return true
    }

    /// A minimal manifest rebuilt from what is on disk, for a `project.json` that a power cut or a bad
    /// write left unreadable: tracks from their folders (segments or a consolidated file), pauses from
    /// `events.jsonl`. The capture source, scale (2) and frame rate (60) aren't recorded anywhere else,
    /// so they are guesses. `nil` when there's no screen track.
    static func rebuildManifest(_ bundle: ProjectBundle) -> ProjectManifest? {
        let fm = FileManager.default
        var tracks: [TrackInfo] = []
        var hasSegments = false
        for kind in TrackKind.allCases {
            let dir = bundle.directory(for: kind)
            let initURL = dir.appendingPathComponent("init.mp4")
            if SegmentStore.hasSegments(dir), let data = try? Data(contentsOf: initURL), MP4.isValidInit(data) {
                let info = MP4.initInfo(data)
                hasSegments = true
                tracks.append(TrackInfo(kind: kind, directory: kind.rawValue, codec: info.codec, pixelSize: info.pixelSize,
                                        sampleRate: info.sampleRate, channels: info.channels))
            } else if let s = SegmentStore.summarize(file: dir.appendingPathComponent("\(kind.rawValue).mp4"),
                                                     relativePath: "\(kind.rawValue)/\(kind.rawValue).mp4") {
                tracks.append(TrackInfo(kind: kind, directory: kind.rawValue, file: s.file, codec: s.codec, pixelSize: s.pixelSize,
                                        sampleRate: s.sampleRate, channels: s.channels, duration: s.duration))
            }
        }
        guard let screen = tracks.first(where: { $0.kind == .screen }), let size = screen.pixelSize else { return nil }
        var pauses: [TimeRange] = []
        var pauseStart: Double?
        for e in (try? bundle.readEvents()) ?? [] {
            if e.type == .pause { pauseStart = e.t }
            if e.type == .resume, let p = pauseStart { pauses.append(TimeRange(start: p, end: max(p, e.t))); pauseStart = nil }
        }
        let created = (try? fm.attributesOfItem(atPath: bundle.url.path))?[.creationDate] as? Date ?? Date()
        return ProjectManifest(createdAt: created, title: bundle.url.deletingPathExtension().lastPathComponent,
                               appVersion: ReelbirdInfo.version, status: hasSegments ? .recording : .recovered,
                               capture: CaptureInfo(source: .display(id: 0, name: "Unknown display"), pixelSize: size, scale: 2, frameRate: 60),
                               clock: ClockInfo(originHostTime: 0), tracks: tracks, pauses: pauses,
                               duration: tracks.map { $0.startTime + $0.duration }.max() ?? 0)
    }
}
