import Foundation

/// A `.reelbird` project directory. Self-contained: every path inside is relative.
///
///     Demo.reelbird/
///       project.json        ProjectManifest (what was recorded)
///       edit.json           EditDocument (every edit)
///       events.jsonl        InputEvent per line (cursor, clicks, keys, focus, pauses)
///       cursors/            <id>.png + cursors.json ([CursorImageInfo])
///       screen/             screen.mp4 once finished (while recording: init.mp4, seg_00001.m4s …, index.m3u8)
///       camera/  microphone/  systemAudio/  share/   (same layout, when recorded)
///       captions.vtt        optional, from transcription
///       transcript.json     optional, word-timed transcript (ReelbirdAI.Transcript) behind captions.vtt
///       analysis.json       optional cache: loudness, noise floor and speech ranges of the audio (AudioAnalysis)
///       voice/              optional cache: the enhanced voice stem (voice-<hash>.caf + stem.json, VoiceStemInfo)
///       exports/            rendered outputs
///       .lock               BundleLock (recorder / recovery)
///       .edit.lock          EditLock (held only while `edit.json` is checked and written)
public struct ProjectBundle: Hashable, Sendable {
    public static let pathExtension = "reelbird"

    public let url: URL
    public init(url: URL) { self.url = url }

    public var manifestURL: URL { url.appendingPathComponent("project.json") }
    public var editURL: URL { url.appendingPathComponent("edit.json") }
    public var eventsURL: URL { url.appendingPathComponent("events.jsonl") }
    public var cursorsURL: URL { url.appendingPathComponent("cursors", isDirectory: true) }
    public var cursorIndexURL: URL { cursorsURL.appendingPathComponent("cursors.json") }
    public var exportsURL: URL { url.appendingPathComponent("exports", isDirectory: true) }
    public var captionsURL: URL { url.appendingPathComponent("captions.vtt") }
    public var transcriptURL: URL { url.appendingPathComponent("transcript.json") }
    public var analysisURL: URL { url.appendingPathComponent("analysis.json") }

    public func directory(for kind: TrackKind) -> URL { url.appendingPathComponent(kind.rawValue, isDirectory: true) }
    public func resolve(_ relative: String) -> URL {
        relative.hasPrefix("/") ? URL(fileURLWithPath: relative) : url.appendingPathComponent(relative)
    }

    /// Creates a new empty bundle with its directories.
    public static func create(at url: URL) throws -> ProjectBundle {
        let b = ProjectBundle(url: url)
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try fm.createDirectory(at: b.cursorsURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: b.exportsURL, withIntermediateDirectories: true)
        return b
    }

    public func readManifest() throws -> ProjectManifest {
        try JSONCoding.decoder.decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
    }

    /// Writes `project.json` durably. While recording (rewritten every 2 s) a barrier keeps a power cut
    /// from tearing it; a finished or recovered manifest is fully flushed (`F_FULLFSYNC`), since
    /// segment cleanup and recovery rely on it.
    public func writeManifest(_ m: ProjectManifest) throws {
        try JSONCoding.writeAtomically(m, to: manifestURL, sync: m.status == .recording ? .barrier : .full)
    }

    /// Whether a recorder (the app or the CLI) still seems to be writing this bundle: `manifest` says
    /// `.recording` and either a recorder holds the bundle's lock (it does for the whole take, including
    /// while it consolidates) or `project.json` changed in the last `window`
    /// seconds (a live session rewrites it every 2 s, paused or not). A take cut short by a crash has
    /// neither, so it can be recovered. Don't open, recover or trash a live bundle; its recorder will
    /// finish it.
    public func isBeingRecorded(_ manifest: ProjectManifest, window: TimeInterval = 10, now: Date = Date()) -> Bool {
        guard manifest.status == .recording else { return false }
        return wasWrittenRecently(manifest, window: window, now: now) || BundleLock.holder(self) == .recording
    }

    /// `manifest` says `.recording` and `project.json` changed in the last `window` seconds.
    public func wasWrittenRecently(_ manifest: ProjectManifest, window: TimeInterval = 10, now: Date = Date()) -> Bool {
        guard manifest.status == .recording,
              let modified = (try? manifestURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return false }
        return now.timeIntervalSince(modified) < window
    }

    /// Reads `edit.json`, or the initial edit if it does not exist yet.
    public func readEdit() throws -> EditDocument {
        if FileManager.default.fileExists(atPath: editURL.path) {
            return try JSONCoding.decoder.decode(EditDocument.self, from: Data(contentsOf: editURL))
        }
        return try initialEdit()
    }

    /// The edit for a recording opened for the first time: `EditDocument.initial`, with the camera placed
    /// where the live bubble was (read from `events.jsonl` when there is a camera track).
    public func initialEdit(manifest: ProjectManifest? = nil, events: [InputEvent]? = nil) throws -> EditDocument {
        let m = try manifest ?? readManifest()
        guard m.track(.camera) != nil else { return EditDocument.initial(for: m) }
        return EditDocument.initial(for: m, events: try events ?? ((try? readEvents()) ?? []))
    }

    /// Writes `edit.json` (fully flushed) with the next `revision` (one more than the file on disk), so
    /// every writer (the editor, `reelbird edit`, MCP `set_edit`) leaves a trace others can notice.
    /// Returns the revision written.
    @discardableResult
    public func writeEdit(_ e: EditDocument) throws -> Int {
        try writeEdit(e, ifRevision: nil)
    }

    /// Like `writeEdit(_:)`, but only if `edit.json` is still at `expected` (0 = no file yet); otherwise
    /// throws `EditConflict` and writes nothing, so the caller can merge the other writer's changes first.
    /// The read, check and write happen under `EditLock`, so of two writers (in any process) starting
    /// from the same revision exactly one succeeds.
    @discardableResult
    public func writeEdit(_ e: EditDocument, ifRevision expected: Int?) throws -> Int {
        try EditLock.withLock(self) { try writeEditLocked(e, ifRevision: expected) }
    }

    /// Reads `edit.json`, lets `body` change it and writes it back, holding `EditLock` throughout so no
    /// other writer (the editor, another CLI or MCP call) can slip in between and have its change lost.
    /// `body` must not write `edit.json` itself. Returns what `body` returns.
    public func updateEdit<T>(_ body: (inout EditDocument) throws -> T) throws -> T {
        try EditLock.withLock(self) {
            var (edit, revision) = try readEditStamped()
            let result = try body(&edit)
            try writeEditLocked(edit, ifRevision: revision)
            return result
        }
    }

    @discardableResult
    private func writeEditLocked(_ e: EditDocument, ifRevision expected: Int?) throws -> Int {
        let current = readEditRevision()
        if let expected, current != expected { throw EditConflict(expected: expected, found: current) }
        let next = current + 1
        let data = try JSONCoding.encoder.encode(StampedEdit(edit: e, revision: next))
        try DurableFile.write(data, to: editURL, sync: .full)
        return next
    }

    /// `edit.json` and its `revision` (0 for a file without one, or no file: then the initial edit).
    public func readEditStamped() throws -> (edit: EditDocument, revision: Int) {
        guard FileManager.default.fileExists(atPath: editURL.path) else { return (try initialEdit(), 0) }
        let data = try Data(contentsOf: editURL)
        let edit = try JSONCoding.decoder.decode(EditDocument.self, from: data)
        let revision = (try? JSONCoding.decoder.decode(EditRevision.self, from: data))?.revision ?? 0
        return (edit, revision)
    }

    /// The `revision` in `edit.json` (0 when missing or unreadable).
    public func readEditRevision() -> Int {
        guard let data = try? Data(contentsOf: editURL) else { return 0 }
        return (try? JSONCoding.decoder.decode(EditRevision.self, from: data))?.revision ?? 0
    }

    /// The cached `analysis.json`, or `nil` when missing, unreadable or from another analysis version.
    public func readAnalysis() -> AudioAnalysis? {
        guard let d = try? Data(contentsOf: analysisURL),
              let a = try? JSONCoding.decoder.decode(AudioAnalysis.self, from: d),
              a.version == AudioAnalysis.currentVersion else { return nil }
        return a
    }

    public func writeAnalysis(_ a: AudioAnalysis) throws {
        try JSONCoding.writeAtomically(a, to: analysisURL)
    }

    public func readEvents() throws -> [InputEvent] {
        guard FileManager.default.fileExists(atPath: eventsURL.path) else { return [] }
        return try EventLog.read(eventsURL)
    }

    public func readCursorImages() -> [CursorImageInfo] {
        guard let d = try? Data(contentsOf: cursorIndexURL) else { return [] }
        return (try? JSONCoding.decoder.decode([CursorImageInfo].self, from: d)) ?? []
    }

    /// Deletes a finished track's recording files (`init.mp4`, `seg_*.m4s`, `index.m3u8`) and leftover
    /// temporary files, keeping `<kind>/<kind>.mp4`. Does nothing when that file is missing. Call only
    /// once the file is verified and a finished `project.json` pointing at it is durably written.
    /// Returns the bytes freed.
    @discardableResult
    public func removeSegments(of kind: TrackKind) -> Int64 {
        Self.removeSegments(in: directory(for: kind), kind: kind)
    }

    @discardableResult
    public static func removeSegments(in directory: URL, kind: TrackKind) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.appendingPathComponent("\(kind.rawValue).mp4").path) else { return 0 }
        var freed: Int64 = 0
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] {
            let segment = name.hasPrefix("seg_") && name.hasSuffix(".m4s")
            let leftover = name.hasPrefix(".") && (name.hasSuffix(".tmp") || name.hasSuffix(".partial"))
            guard segment || leftover || name == "init.mp4" || name == "index.m3u8" else { continue }
            let url = directory.appendingPathComponent(name)
            let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
            if (try? fm.removeItem(at: url)) != nil { freed += size }
        }
        DurableFile.syncDirectory(directory)
        return freed
    }

    /// Media file for a track: the consolidated file if present.
    public func mediaURL(for kind: TrackKind, in manifest: ProjectManifest) -> URL? {
        guard let t = manifest.track(kind), let f = t.file else { return nil }
        return resolve(f)
    }
}

/// `edit.json` changed since the caller read it (another process wrote it).
public struct EditConflict: Error, Equatable {
    public var expected: Int
    public var found: Int
}

private struct EditRevision: Decodable { var revision: Int? }

/// An `EditDocument` plus the file's `revision` counter, written side by side in one JSON object.
private struct StampedEdit: Encodable {
    let edit: EditDocument
    let revision: Int
    enum Key: String, CodingKey { case revision }
    func encode(to encoder: any Encoder) throws {
        try edit.encode(to: encoder)
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(revision, forKey: .revision)
    }
}

public enum JSONCoding {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
    /// Encodes and writes via a flushed temporary file + rename (`DurableFile`), so readers never see
    /// a partial file, even after a power cut.
    public static func writeAtomically<T: Encodable>(_ value: T, to url: URL, sync: DurableFile.Sync = .barrier) throws {
        let data = try encoder.encode(value)
        try DurableFile.write(data, to: url, sync: sync)
    }
}

/// Where projects live: `~/Movies/Reelbird` by default.
public struct ProjectLibrary: Sendable {
    public let root: URL
    public init(root: URL = ProjectLibrary.defaultRoot) { self.root = root }

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Reelbird", isDirectory: true)
    }

    /// A fresh bundle URL named after the date, e.g. "Reelbird 2026-10-12 at 14.03.22.reelbird".
    public func newBundleURL(date: Date = Date()) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        var url = root.appendingPathComponent("Reelbird \(f.string(from: date)).\(ProjectBundle.pathExtension)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("Reelbird \(f.string(from: date)) \(n).\(ProjectBundle.pathExtension)")
            n += 1
        }
        return url
    }

    /// All bundles in the library, newest first.
    public func list() -> [ProjectBundle] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        return items.filter { $0.pathExtension == ProjectBundle.pathExtension }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a > b
            }
            .map(ProjectBundle.init(url:))
    }
}
