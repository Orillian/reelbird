import Foundation

/// A `.reelbird` project directory. Self-contained: every path inside is relative.
///
///     Demo.reelbird/
///       project.json        ProjectManifest (what was recorded)
///       edit.json           EditDocument (every edit)
///       events.jsonl        InputEvent per line (cursor, clicks, keys, focus, pauses)
///       cursors/            <id>.png + cursors.json ([CursorImageInfo])
///       screen/             init.mp4, seg_00001.m4s …, index.m3u8   (+ screen.mp4 when consolidated)
///       camera/  microphone/  systemAudio/  share/   (same layout, when recorded)
///       captions.vtt        optional, from transcription
///       transcript.json     optional, word-timed transcript (ReelbirdAI.Transcript) behind captions.vtt
///       analysis.json       optional cache: loudness, noise floor and speech ranges of the audio (AudioAnalysis)
///       voice/              optional cache: the enhanced voice stem (voice-<hash>.caf + stem.json, VoiceStemInfo)
///       exports/            rendered outputs
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

    public func writeManifest(_ m: ProjectManifest) throws {
        try JSONCoding.writeAtomically(m, to: manifestURL)
    }

    /// Whether a recorder (the app or the CLI) still seems to be writing this bundle: `manifest` says
    /// `.recording` and `project.json` changed in the last `window` seconds (a live session rewrites it
    /// every 2 s, paused or not). A take cut short by a crash stops changing, so it isn't live and can be
    /// recovered. Don't open, recover or trash a live bundle; its recorder will finish it.
    public func isBeingRecorded(_ manifest: ProjectManifest, window: TimeInterval = 10, now: Date = Date()) -> Bool {
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
        return EditDocument.initial(for: try readManifest())
    }

    public func writeEdit(_ e: EditDocument) throws {
        try JSONCoding.writeAtomically(e, to: editURL)
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

    /// Media file for a track: the consolidated file if present.
    public func mediaURL(for kind: TrackKind, in manifest: ProjectManifest) -> URL? {
        guard let t = manifest.track(kind), let f = t.file else { return nil }
        return resolve(f)
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
    /// Encodes and writes via a temporary file + rename, so readers never see a partial file.
    public static func writeAtomically<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
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
