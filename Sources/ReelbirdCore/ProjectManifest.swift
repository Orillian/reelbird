import Foundation

/// `project.json`: what was recorded. Written by the recorder; never changed by editing.
///
/// All times in a project are seconds on one timeline whose zero is the host-clock time
/// of the first screen frame (`clock.originHostTime`). Media, events and edits share it.
public struct ProjectManifest: Codable, Hashable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var id: String
    public var createdAt: Date
    public var title: String
    public var appVersion: String
    public var status: RecordingStatus
    public var capture: CaptureInfo
    public var clock: ClockInfo
    public var tracks: [TrackInfo]
    /// Ranges where recording was paused. Media has a gap there; edits cut them by default.
    public var pauses: [TimeRange]
    /// Length of the recording timeline in seconds (including paused ranges).
    public var duration: Double
    /// Share link reserved for this recording, if sharing was on.
    public var share: ShareInfo?

    public init(
        id: String = ShortID.make(),
        createdAt: Date = Date(),
        title: String,
        appVersion: String,
        status: RecordingStatus = .recording,
        capture: CaptureInfo,
        clock: ClockInfo,
        tracks: [TrackInfo] = [],
        pauses: [TimeRange] = [],
        duration: Double = 0,
        share: ShareInfo? = nil
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.appVersion = appVersion
        self.status = status
        self.capture = capture
        self.clock = clock
        self.tracks = tracks
        self.pauses = pauses
        self.duration = duration
        self.share = share
    }

    public func track(_ kind: TrackKind) -> TrackInfo? { tracks.first { $0.kind == kind } }
}

public enum RecordingStatus: String, Codable, Hashable, Sendable {
    /// Still recording, or the app quit before finishing (see `ProjectRecovery.recoverIfNeeded`).
    case recording
    /// Finished normally.
    case complete
    /// Rebuilt from segments after a crash.
    case recovered
}

public struct CaptureInfo: Codable, Hashable, Sendable {
    public var source: CaptureSource
    /// Size of the captured screen video in pixels.
    public var pixelSize: PixelSize
    /// Backing scale factor of the captured display (2 on Retina).
    public var scale: Double
    public var frameRate: Int
    /// Whether the system cursor was hidden in the screen video (it is re-drawn from events).
    public var cursorHidden: Bool
    public var colorSpace: String
    public init(source: CaptureSource, pixelSize: PixelSize, scale: Double, frameRate: Int,
                cursorHidden: Bool = true, colorSpace: String = "sRGB") {
        self.source = source; self.pixelSize = pixelSize; self.scale = scale
        self.frameRate = frameRate; self.cursorHidden = cursorHidden; self.colorSpace = colorSpace
    }
}

public enum CaptureSource: Codable, Hashable, Sendable {
    case display(id: UInt32, name: String)
    case window(id: UInt32, app: String, title: String)
    /// A rectangle in global display points, top-left origin, on the given display.
    case area(displayID: UInt32, x: Double, y: Double, width: Double, height: Double)
    /// Generated frames (tests, demos).
    case synthetic(name: String)
}

public struct ClockInfo: Codable, Hashable, Sendable {
    /// Host time (seconds, `CMClockGetHostTimeClock`) of timeline zero.
    public var originHostTime: Double
    public init(originHostTime: Double) { self.originHostTime = originHostTime }
}

public enum TrackKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// Full-quality screen video (HEVC by default). Cursor hidden.
    case screen
    /// Camera video, recorded separately so layout can change after recording.
    case camera
    case microphone
    case systemAudio
    /// Quick-share stream: screen + camera bubble + mixed audio, H.264, uploaded live.
    case share
}

public struct TrackInfo: Codable, Hashable, Sendable {
    public var kind: TrackKind
    /// Directory (relative to the bundle) holding `init.mp4` + `seg_NNNNN.m4s` + `index.m3u8`.
    public var directory: String
    /// Single-file media (relative path), produced by `SegmentStore.consolidate` once recording ends.
    /// Readable by AVAsset / AVAssetReader. `nil` while recording.
    public var file: String?
    public var codec: String
    public var pixelSize: PixelSize?
    public var sampleRate: Int?
    public var channels: Int?
    public var segmentDuration: Double
    public var segmentCount: Int
    public var duration: Double
    /// Time of this track's first sample on the project timeline (seconds).
    public var startTime: Double

    public init(kind: TrackKind, directory: String, file: String? = nil, codec: String,
                pixelSize: PixelSize? = nil, sampleRate: Int? = nil, channels: Int? = nil,
                segmentDuration: Double = 2, segmentCount: Int = 0, duration: Double = 0, startTime: Double = 0) {
        self.kind = kind; self.directory = directory; self.file = file; self.codec = codec
        self.pixelSize = pixelSize; self.sampleRate = sampleRate; self.channels = channels
        self.segmentDuration = segmentDuration; self.segmentCount = segmentCount
        self.duration = duration; self.startTime = startTime
    }
}

public struct ShareInfo: Codable, Hashable, Sendable {
    /// Object key prefix in the bucket, e.g. "r/7Hk2pQx9aB".
    public var key: String
    /// Public URL of the viewer page.
    public var url: String
    /// Whether the polished render has replaced the quick stream.
    public var polished: Bool
    public var updatedAt: Date
    public init(key: String, url: String, polished: Bool = false, updatedAt: Date = Date()) {
        self.key = key; self.url = url; self.polished = polished; self.updatedAt = updatedAt
    }
}

/// Short, URL-safe, unambiguous IDs (base58, 10 characters, ~58 bits).
public enum ShortID {
    static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    public static func make(length: Int = 10) -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet[Int(rng.next(upperBound: UInt32(alphabet.count)))] })
    }
}
