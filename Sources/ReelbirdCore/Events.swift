import Foundation

/// One line of `events.jsonl`. Positions are normalized to the captured area (top-left origin);
/// they may fall outside 0...1 when the pointer leaves the area.
public struct InputEvent: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        /// Pointer position sample.
        case move
        case down
        case up
        case scroll
        /// A key press (only recorded when keystroke capture is enabled and permitted).
        case key
        /// The cursor image changed; `image` is the file stem in `cursors/`.
        case cursor
        /// The focused UI element moved to `rect` (Accessibility, optional).
        case focus
        case pause
        case resume
    }

    public var t: Double
    public var type: Kind
    public var x: Double?
    public var y: Double?
    /// Mouse button: 0 left, 1 right, 2 other.
    public var button: Int?
    public var dx: Double?
    public var dy: Double?
    /// Characters for `key` events, e.g. "a", "⏎", "⌫".
    public var chars: String?
    /// Modifier symbols for `key` events, e.g. ["⌘", "⇧"].
    public var mods: [String]?
    public var image: String?
    public var rect: NormRect?

    public init(t: Double, type: Kind, x: Double? = nil, y: Double? = nil, button: Int? = nil,
                dx: Double? = nil, dy: Double? = nil, chars: String? = nil, mods: [String]? = nil,
                image: String? = nil, rect: NormRect? = nil) {
        self.t = t; self.type = type; self.x = x; self.y = y; self.button = button
        self.dx = dx; self.dy = dy; self.chars = chars; self.mods = mods; self.image = image; self.rect = rect
    }

    public var point: NormPoint? {
        guard let x, let y else { return nil }
        return NormPoint(x: x, y: y)
    }

    public static func move(_ t: Double, _ p: NormPoint) -> InputEvent { InputEvent(t: t, type: .move, x: p.x, y: p.y) }
    public static func down(_ t: Double, _ p: NormPoint, button: Int = 0) -> InputEvent {
        InputEvent(t: t, type: .down, x: p.x, y: p.y, button: button)
    }
    public static func up(_ t: Double, _ p: NormPoint, button: Int = 0) -> InputEvent {
        InputEvent(t: t, type: .up, x: p.x, y: p.y, button: button)
    }
}

/// Metadata for a cursor image in `cursors/<id>.png`.
public struct CursorImageInfo: Codable, Hashable, Sendable {
    public var id: String
    /// Hot spot in image pixels from the top-left.
    public var hotX: Double
    public var hotY: Double
    /// Image size in points (the PNG is stored at 2x).
    public var width: Double
    public var height: Double
    public init(id: String, hotX: Double, hotY: Double, width: Double, height: Double) {
        self.id = id; self.hotX = hotX; self.hotY = hotY; self.width = width; self.height = height
    }
}

/// Reads and appends `events.jsonl`. Appending is line-buffered and safe to call from one queue.
public final class EventLogWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let encoder: JSONEncoder
    private let lock = NSLock()

    public init(url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    public func append(_ event: InputEvent) {
        guard var data = try? encoder.encode(event) else { return }
        data.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        try? handle.write(contentsOf: data)
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        try? handle.synchronize()
        try? handle.close()
    }
}

public enum EventLog {
    /// Reads every event, skipping malformed lines (a crash can leave a partial last line).
    public static func read(_ url: URL) throws -> [InputEvent] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        var out: [InputEvent] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let e = try? decoder.decode(InputEvent.self, from: Data(line)) { out.append(e) }
        }
        return out.sorted { $0.t < $1.t }
    }
}
