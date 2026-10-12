import Foundation
import ReelbirdCore

/// `r/<id>/meta.json`: everything the viewer page needs. Also embedded in the page itself so
/// the first paint needs no extra request. Asset fields are file names relative to `baseURL`.
public struct ViewerMeta: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        /// Still recording; the HLS playlist grows (EVENT) and the page polls meta.json.
        case recording
        /// Recording ended; the last segments are still uploading.
        case processing
        /// Complete.
        case ready
    }

    public var version = 1
    public var id: String
    public var title: String
    public var status: Status
    public var createdAt: Date
    public var updatedAt: Date
    /// Seconds, when known.
    public var duration: Double?
    /// Canonical public link, e.g. "https://pub-x.r2.dev/r/AbC/".
    public var pageURL: String
    /// Absolute URL of the share folder, ending in "/". Asset names resolve against it.
    public var baseURL: String
    /// HLS playlist of the quick-share stream ("hls/index.m3u8"), once the first segment is up.
    public var hls: String?
    /// Polished MP4, when published.
    public var video: String?
    public var videoBytes: Int64?
    public var width: Int?
    public var height: Int?
    public var poster: String?
    /// 1200×630 title card used for link previews when there is no poster.
    public var card: String?
    public var captions: String?
    public var captionsLanguage: String?
    public var chapters: [Chapter]
    /// Increases with every publish; versioned asset names make them safe to cache forever.
    public var revision: Int

    public init(id: String, title: String, status: Status, createdAt: Date = Date(), updatedAt: Date = Date(),
                duration: Double? = nil, pageURL: String, baseURL: String, hls: String? = nil, video: String? = nil,
                videoBytes: Int64? = nil, width: Int? = nil, height: Int? = nil, poster: String? = nil,
                card: String? = nil, captions: String? = nil, captionsLanguage: String? = nil,
                chapters: [Chapter] = [], revision: Int = 0) {
        self.id = id; self.title = title; self.status = status; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.duration = duration; self.pageURL = pageURL; self.baseURL = baseURL; self.hls = hls; self.video = video
        self.videoBytes = videoBytes; self.width = width; self.height = height; self.poster = poster; self.card = card
        self.captions = captions; self.captionsLanguage = captionsLanguage; self.chapters = chapters; self.revision = revision
    }

    /// Absolute URL for an asset name.
    public func url(_ name: String?) -> String? { name.map { baseURL + $0 } }

    var jsonData: Data { (try? JSONCoding.encoder.encode(self)) ?? Data("{}".utf8) }
}

/// Object keys and URLs of one share. Bucket layout:
///
///     r/<id>/index.html     viewer (also at "r/<id>/" and "r/<id>" so every form of the link works)
///     r/<id>/meta.json      ViewerMeta (no-store)
///     r/<id>/card.jpg       link-preview title card
///     r/<id>/hls/           index.m3u8 (no-store), init.mp4, seg_00001.m4s …
///     r/<id>/video.<rev>.mp4, poster.<rev>.jpg, captions.<rev>.vtt   (immutable)
public struct ShareLayout: Hashable, Sendable {
    public let id: String
    public let prefix: String
    public let publicBase: String

    public init(id: String, destination: ShareDestination) {
        self.id = id
        let p = destination.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.prefix = p.isEmpty ? "r" : p
        var base = destination.publicBaseURL
        while base.hasSuffix("/") { base.removeLast() }
        self.publicBase = base
    }

    /// Recovers the layout from a stored `ShareInfo.key` ("r/<id>").
    public init?(info: ShareInfo, destination: ShareDestination) {
        guard let id = info.key.split(separator: "/").last.map(String.init), !id.isEmpty else { return nil }
        self.init(id: id, destination: destination)
    }

    /// "r/<id>": `ShareInfo.key`.
    public var key: String { "\(prefix)/\(id)" }
    /// "r/<id>/": the folder prefix (for listing and deleting).
    public var folder: String { key + "/" }
    public var pageURL: String { "\(publicBase)/\(folder)" }
    public var baseURL: String { pageURL }

    public var pageKeys: [String] { [folder + "index.html", folder, key] }
    public var metaKey: String { folder + "meta.json" }
    public var cardKey: String { folder + "card.jpg" }
    public var playlistKey: String { folder + "hls/index.m3u8" }
    public var initKey: String { folder + "hls/init.mp4" }
    public func segmentName(_ index: Int) -> String { String(format: "seg_%05d.m4s", index) }
    public func segmentKey(_ index: Int) -> String { folder + "hls/" + segmentName(index) }
    public func key(_ asset: String) -> String { folder + asset }

    static let immutable = "public, max-age=31536000, immutable"
    static let noStore = "no-store, max-age=0"
    static let revalidate = "public, max-age=0, must-revalidate"
}

/// HLS media playlists for the quick-share stream.
public enum HLSPlaylist {
    /// An EVENT playlist over segments 1...count. `ended` appends EXT-X-ENDLIST.
    public static func event(durations: [Double], ended: Bool, initName: String = "init.mp4",
                             segmentName: (Int) -> String) -> String {
        let target = max(1, Int((durations.max() ?? 2).rounded(.up)))
        var s = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-PLAYLIST-TYPE:EVENT
        #EXT-X-TARGETDURATION:\(max(target, 2))
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MAP:URI="\(initName)"

        """
        for (i, d) in durations.enumerated() {
            s += String(format: "#EXTINF:%.5f,\n", d)
            s += segmentName(i + 1) + "\n"
        }
        if ended { s += "#EXT-X-ENDLIST\n" }
        return s
    }

    /// Segment durations from a local playlist (as written by the capture writer), keyed by
    /// the number in "seg_NNNNN.m4s".
    public static func durations(fromPlaylist text: String) -> [Int: Double] {
        var out: [Int: Double] = [:]
        var pending: Double?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                pending = Double(line.dropFirst(8).split(separator: ",").first ?? "")
            } else if !line.hasPrefix("#"), let d = pending, let n = segmentNumber(line) {
                out[n] = d
                pending = nil
            }
        }
        return out
    }

    /// 12 for "seg_00012.m4s" (any prefix, digits before the extension).
    public static func segmentNumber(_ name: String) -> Int? {
        let base = (name as NSString).lastPathComponent
        guard base.hasSuffix(".m4s") else { return nil }
        let stem = base.dropLast(4)
        let digits = stem.reversed().prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(String(digits.reversed()))
    }
}
