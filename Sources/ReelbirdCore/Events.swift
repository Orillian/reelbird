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
        /// The live camera bubble's place: logged when recording starts and whenever a drag (or resize) ends.
        /// `x`, `y` is its centre and `rect` its frame, moved fully inside the captured area; `shape` its shape;
        /// `layout` the live layout (logged again when the layout shortcut switches it).
        case camera
        /// A marker dropped while recording (the marker shortcut, the control bar or MCP `add_marker`);
        /// `label` is its name when one was given. Older versions skip these lines.
        case marker
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
    /// `CameraLayout.Shape` raw value for `camera` events.
    public var shape: String?
    /// `LayoutSegment.Kind` raw value for `camera` events: `overlay`, `fullCamera` or `screenOnly` (absent in
    /// older logs = `overlay`).
    public var layout: String?
    /// The name of a `marker` event, when one was given.
    public var label: String?

    public init(t: Double, type: Kind, x: Double? = nil, y: Double? = nil, button: Int? = nil,
                dx: Double? = nil, dy: Double? = nil, chars: String? = nil, mods: [String]? = nil,
                image: String? = nil, rect: NormRect? = nil, shape: String? = nil, layout: String? = nil, label: String? = nil) {
        self.t = t; self.type = type; self.x = x; self.y = y; self.button = button
        self.dx = dx; self.dy = dy; self.chars = chars; self.mods = mods; self.image = image; self.rect = rect
        self.shape = shape; self.layout = layout; self.label = label
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
    /// The camera bubble at `frame` (normalized to the captured area).
    public static func camera(_ t: Double, frame: NormRect, shape: CameraLayout.Shape? = nil,
                              layout: LayoutSegment.Kind? = nil) -> InputEvent {
        let c = frame.center
        return InputEvent(t: t, type: .camera, x: c.x, y: c.y, rect: frame, shape: shape?.rawValue, layout: layout?.rawValue)
    }
    /// A marker, named `label` when given.
    public static func marker(_ t: Double, label: String? = nil) -> InputEvent { InputEvent(t: t, type: .marker, label: label) }
}

/// Metadata for a cursor image in `cursors/<id>.png`.
public struct CursorImageInfo: Codable, Hashable, Sendable {
    public var id: String
    /// Hot spot in image pixels from the top-left.
    public var hotX: Double
    public var hotY: Double
    /// Image size in points. The PNG is stored at a higher scale (4x by default); the scale is the
    /// PNG's pixel width divided by `width`.
    public var width: Double
    public var height: Double
    public init(id: String, hotX: Double, hotY: Double, width: Double, height: Double) {
        self.id = id; self.hotX = hotX; self.hotY = hotY; self.width = width; self.height = height
    }
}

/// Reads and appends `events.jsonl`. Each event is one unbuffered write of a whole line, behind a lock.
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
        out.reserveCapacity(data.count / 48)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var lineStart = 0
            for i in 0...bytes.count {
                guard i == bytes.count || bytes[i] == 0x0A else { continue }
                if i > lineStart {
                    let line = UnsafeBufferPointer(rebasing: bytes[lineStart..<i])
                    if let e = FlatEventParser.parse(line) {
                        out.append(e)
                    } else if let e = try? decoder.decode(InputEvent.self, from: Data(buffer: line)) {
                        // Nested values or escapes; malformed lines (e.g. cut short by a crash) are skipped.
                        out.append(e)
                    }
                }
                lineStart = i + 1
            }
        }
        if !zip(out, out.dropFirst()).allSatisfy({ $0.t <= $1.t }) { out.sort { $0.t < $1.t } }
        return out
    }
}

/// Parses the common flat event lines (`{"t":1.2,"type":"move","x":0.4,"y":0.2}`) without Codable,
/// which is ~10x faster on hour-long logs. A `rect` of plain numbers is read too (focus and camera events).
/// Returns nil for anything it does not handle (arrays, other nested objects, escaped strings, unknown
/// keys), so the caller can fall back.
enum FlatEventParser {
    static func parse(_ b: UnsafeBufferPointer<UInt8>) -> InputEvent? {
        var i = 0
        let n = b.count
        func skipSpace() { while i < n, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0D { i += 1 } }
        func readString() -> String? {
            guard i < n, b[i] == 0x22 else { return nil }
            i += 1
            let start = i
            while i < n, b[i] != 0x22 { if b[i] == 0x5C { return nil }; i += 1 }
            guard i < n else { return nil }
            let str = String(decoding: UnsafeBufferPointer(rebasing: b[start..<i]), as: UTF8.self)
            i += 1
            return str
        }
        func readNumber() -> Double? {
            let start = i
            while i < n, let c = Optional(b[i]), (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2B || c == 0x2E || c == 0x45 || c == 0x65 { i += 1 }
            guard i > start, i - start < 40 else { return nil }
            let len = i - start
            let v = withUnsafeTemporaryAllocation(of: CChar.self, capacity: len + 1) { p -> Double in
                for k in 0..<len { p[k] = CChar(bitPattern: b[start + k]) }
                p[len] = 0
                var end: UnsafeMutablePointer<CChar>?
                let r = strtod(p.baseAddress!, &end)
                return end == p.baseAddress! + len ? r : .nan
            }
            return v.isNaN ? nil : v
        }
        skipSpace()
        guard i < n, b[i] == 0x7B else { return nil }
        i += 1
        var t: Double?
        var type: InputEvent.Kind?
        var e = InputEvent(t: 0, type: .move)
        while true {
            skipSpace()
            guard i < n else { return nil }
            if b[i] == 0x7D { break }
            if b[i] == 0x2C { i += 1; continue }
            guard let key = readString() else { return nil }
            skipSpace()
            guard i < n, b[i] == 0x3A else { return nil }
            i += 1
            skipSpace()
            switch key {
            case "type", "chars", "image", "shape", "layout", "label":
                guard let v = readString() else { return nil }
                switch key {
                case "type": guard let k = InputEvent.Kind(rawValue: v) else { return nil }; type = k
                case "chars": e.chars = v
                case "image": e.image = v
                case "label": e.label = v
                case "layout": e.layout = v
                default: e.shape = v
                }
            case "rect":
                guard i < n, b[i] == 0x7B else { return nil }
                i += 1
                var rx: Double?, ry: Double?, rw: Double?, rh: Double?
                while true {
                    skipSpace()
                    guard i < n else { return nil }
                    if b[i] == 0x7D { i += 1; break }
                    if b[i] == 0x2C { i += 1; continue }
                    guard let k = readString() else { return nil }
                    skipSpace()
                    guard i < n, b[i] == 0x3A else { return nil }
                    i += 1
                    skipSpace()
                    guard let v = readNumber() else { return nil }
                    switch k {
                    case "x": rx = v
                    case "y": ry = v
                    case "width": rw = v
                    case "height": rh = v
                    default: return nil
                    }
                }
                guard let rx, let ry, let rw, let rh else { return nil }
                e.rect = NormRect(x: rx, y: ry, width: rw, height: rh)
            case "t", "x", "y", "dx", "dy", "button":
                guard let v = readNumber() else { return nil }
                switch key {
                case "t": t = v
                case "x": e.x = v
                case "y": e.y = v
                case "dx": e.dx = v
                case "dy": e.dy = v
                default: e.button = v.isFinite && abs(v) < 1_000 ? Int(v) : 0 // hand-edited logs must not trap
                }
            default:
                return nil
            }
        }
        guard let t, let type else { return nil }
        e.t = t
        e.type = type
        return e
    }
}
