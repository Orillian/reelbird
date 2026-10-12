import CoreGraphics
import Foundation
import ReelbirdCore

// Stand-ins for the public types of ReelbirdCapture, ReelbirdRender, ReelbirdShare and ReelbirdAI,
// copied from the module contract in REELBIRD-BRIEF.md. They exist only so the app builds before
// those modules land. INTEGRATION: delete this file once the real modules export these types; the
// app code uses the same names and fields.

/// A permission Reelbird may need.
public enum Permission: String, CaseIterable, Hashable, Sendable {
    case screen, microphone, camera, accessibility, inputMonitoring
}

public enum PermissionState: String, Hashable, Sendable {
    case granted, denied, notDetermined
}

/// A display or window that can be recorded.
public struct AvailableSource: Identifiable, Hashable, @unchecked Sendable {
    public enum Kind: String, Hashable, Sendable { case display, window }
    public var id: String
    public var kind: Kind
    public var title: String
    public var appName: String?
    public var pixelSize: PixelSize
    public var source: CaptureSource
    public var thumbnail: CGImage?

    public init(id: String, kind: Kind, title: String, appName: String? = nil, pixelSize: PixelSize,
                source: CaptureSource, thumbnail: CGImage? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.appName = appName
        self.pixelSize = pixelSize; self.source = source; self.thumbnail = thumbnail
    }

    public static func == (a: AvailableSource, b: AvailableSource) -> Bool { a.id == b.id && a.title == b.title }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

/// A microphone or camera.
public struct MediaDevice: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var isDefault: Bool
    public init(id: String, name: String, isDefault: Bool) { self.id = id; self.name = name; self.isDefault = isDefault }
}

/// How to render a file.
public struct ExportOptions: Codable, Hashable, Sendable {
    public enum Format: String, Codable, Hashable, Sendable, CaseIterable { case mp4H264, mp4HEVC, proRes, gif }
    public var format: Format
    /// Output height in pixels; `nil` = the edit's canvas height.
    public var height: Int?
    public var frameRate: Int?
    /// Where to write; `nil` = the bundle's `exports/` folder.
    public var destination: URL?
    public init(format: Format = .mp4H264, height: Int? = nil, frameRate: Int? = nil, destination: URL? = nil) {
        self.format = format; self.height = height; self.frameRate = frameRate; self.destination = destination
    }
}

/// An on-device transcript.
public struct Transcript: Codable, Hashable, Sendable {
    public struct Word: Codable, Hashable, Sendable {
        public var range: TimeRange
        public var text: String
        public init(range: TimeRange, text: String) { self.range = range; self.text = text }
    }
    public struct Segment: Codable, Hashable, Sendable {
        public var range: TimeRange
        public var text: String
        public var words: [Word]
        public init(range: TimeRange, text: String, words: [Word] = []) { self.range = range; self.text = text; self.words = words }
    }
    public var segments: [Segment]
    public var locale: String
    public init(segments: [Segment], locale: String) { self.segments = segments; self.locale = locale }
}
