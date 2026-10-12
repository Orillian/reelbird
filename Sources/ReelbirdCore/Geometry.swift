import Foundation

/// A point in normalized coordinates of the captured area: (0,0) is the top-left, (1,1) the bottom-right.
public struct NormPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let center = NormPoint(x: 0.5, y: 0.5)
}

/// A rectangle in normalized coordinates of the captured area (top-left origin).
public struct NormRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public static let full = NormRect(x: 0, y: 0, width: 1, height: 1)
    public var center: NormPoint { NormPoint(x: x + width / 2, y: y + height / 2) }
}

/// A size in whole pixels.
public struct PixelSize: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    public var aspect: Double { height == 0 ? 1 : Double(width) / Double(height) }
}

/// A half-open time range in seconds on the recording timeline.
public struct TimeRange: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
    public var duration: Double { max(0, end - start) }
    public func contains(_ t: Double) -> Bool { t >= start && t < end }
    public func overlaps(_ o: TimeRange) -> Bool { start < o.end && o.start < end }
}

/// An RGBA colour with components in 0...1 (sRGB).
public struct RGBA: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    /// Parses "#RRGGBB" or "#RRGGBBAA".
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
        } else {
            self.init(Double((v >> 24) & 0xff) / 255, Double((v >> 16) & 0xff) / 255,
                      Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
        }
    }
    public var hex: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}
