import Foundation
import ReelbirdCore

/// A JSON value: the CLI's `--json` output, MCP messages and dotted-key edits all go through it.
enum JSONValue: Codable, Hashable, Sendable, CustomStringConvertible {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not a JSON value") }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d.isFinite ? d : 0)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // MARK: Access

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }
    var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }
    /// Integers, and doubles with no fractional part.
    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d && abs(d) < 1e15: return Int(d)
        default: return nil
        }
    }

    /// Equality that treats 1 and 1.0 as the same number.
    func numericallyEquals(_ other: JSONValue) -> Bool {
        if let a = doubleValue, let b = other.doubleValue { return a == b }
        switch (self, other) {
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.numericallyEquals($1) }
        case (.object(let a), .object(let b)):
            return a.keys == b.keys && a.allSatisfy { k, v in b[k].map { v.numericallyEquals($0) } ?? false }
        default:
            return self == other
        }
    }

    var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .int, .double: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    // MARK: Conversion

    /// Encodes any `Encodable` with the project file encoder (ISO 8601 dates).
    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONCoding.encoder.encode(value))
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONCoding.decoder.decode(T.self, from: JSONEncoder().encode(self))
    }

    /// Parses JSON text (objects, arrays or bare scalars).
    static func parse(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    func serialized(pretty: Bool = false) -> String {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        guard let d = try? e.encode(self), let s = String(data: d, encoding: .utf8) else { return "null" }
        return s
    }

    var description: String { serialized() }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral v: String) { self = .string(v) }
    init(integerLiteral v: Int) { self = .int(v) }
    init(floatLiteral v: Double) { self = .double(v) }
    init(booleanLiteral v: Bool) { self = .bool(v) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
    init(nilLiteral: ()) { self = .null }
}

extension JSONValue {
    init(_ s: String?) { self = s.map(JSONValue.string) ?? .null }
    init(_ d: Double?) { self = d.map { .double(($0 * 1000).rounded() / 1000) } ?? .null }
    init(_ i: Int?) { self = i.map(JSONValue.int) ?? .null }
}
