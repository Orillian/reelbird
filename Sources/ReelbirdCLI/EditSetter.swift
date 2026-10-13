import Foundation
import ReelbirdCore

/// Applies dotted-key assignments (`zoom.intensity=0.7`, `background.colors=#112233,#445566`,
/// `chapters.0.title=Intro`) to an `EditDocument` through a JSON round trip, so every field of the
/// document is settable without per-field code, and the document's own decoder validates the result.
enum EditSetter {
    enum Value: Sendable {
        /// Text from the command line: parsed as JSON when it is valid JSON, otherwise taken as a string.
        case raw(String)
        /// A value from MCP arguments.
        case json(JSONValue)
    }

    struct Assignment: Sendable {
        var path: String
        var value: Value
    }

    /// Parses "key=value".
    static func assignment(_ s: String) throws -> Assignment {
        guard let eq = s.firstIndex(of: "="), eq != s.startIndex else {
            throw CLIError.usage("--set expects KEY=VALUE, e.g. --set zoom.intensity=0.7 (got '\(s)').")
        }
        return Assignment(path: String(s[..<eq]).trimmingCharacters(in: .whitespaces), value: .raw(String(s[s.index(after: eq)...])))
    }

    static func apply(_ assignments: [Assignment], to edit: EditDocument) throws -> EditDocument {
        var doc = try JSONValue.encode(edit)
        var applied: [(path: [String], value: JSONValue)] = []
        for a in assignments {
            let path = a.path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !path.isEmpty, !path.contains(where: \.isEmpty) else {
                throw CLIError.usage("Invalid edit key '\(a.path)'.")
            }
            let current = value(at: path, in: doc)
            let v = try coerce(a.value, current: current, key: a.path)
            doc = try setting(v, at: path[...], in: doc, fullPath: a.path)
            applied.append((path, v))
        }
        let result: EditDocument
        do { result = try doc.decode(EditDocument.self) } catch let e as DecodingError {
            throw CLIError(describe(e, assignments: assignments), code: .dataError)
        }
        // The decoder ignores unknown keys; catch typos by checking each value survived.
        let check = try JSONValue.encode(result)
        for (path, v) in applied {
            let after = value(at: path, in: check)
            let survived = v.isNull ? (after == nil || after?.isNull == true) : (after.map { $0.numericallyEquals(v) } ?? false)
            if !survived {
                let key = path.joined(separator: ".")
                if after == nil, value(at: path, in: try JSONValue.encode(EditDocument())) == nil, !optionalKeys.contains(key) {
                    let suggestion = ArgumentParser.closest(key, among: knownKeys()).map { " Did you mean '\($0)'?" } ?? ""
                    throw CLIError("Unknown edit key '\(key)'.\(suggestion)", code: .dataError,
                                   hint: "Run `reelbird edit PROJECT --json` to see every key and its current value.")
                }
                throw CLIError("'\(v.serialized())' isn't a valid value for \(key).", code: .dataError)
            }
        }
        return result
    }

    /// Optional keys that are absent from a default document but settable.
    static let optionalKeys: Set<String> = ["trim", "trim.start", "trim.end", "title", "background.imagePath",
                                            "canvas.outputHeight", "canvas.frameRate", "captions.file",
                                            "crop", "crop.x", "crop.y", "crop.width", "crop.height", "camera.x", "camera.y"]

    /// Every leaf key of a default document, e.g. "zoom.intensity".
    static func knownKeys() -> [String] {
        guard let doc = try? JSONValue.encode(EditDocument()) else { return [] }
        var keys: [String] = Array(optionalKeys)
        func walk(_ v: JSONValue, _ prefix: String) {
            if case .object(let o) = v, !o.isEmpty, !isColor(v) {
                for (k, child) in o { walk(child, prefix.isEmpty ? k : "\(prefix).\(k)") }
            } else if !prefix.isEmpty {
                keys.append(prefix)
            }
        }
        walk(doc, "")
        return keys.sorted()
    }

    // MARK: - Internals

    static func value(at path: [String], in v: JSONValue) -> JSONValue? {
        var cur = v
        for k in path {
            switch cur {
            case .object(let o): guard let n = o[k] else { return nil }; cur = n
            case .array(let a): guard let i = Int(k), a.indices.contains(i) else { return nil }; cur = a[i]
            default: return nil
            }
        }
        return cur
    }

    static func setting(_ new: JSONValue, at path: ArraySlice<String>, in v: JSONValue, fullPath: String) throws -> JSONValue {
        guard let k = path.first else { return new }
        let rest = path.dropFirst()
        switch v {
        case .object(var o):
            o[k] = try setting(new, at: rest, in: o[k] ?? .object([:]), fullPath: fullPath)
            return .object(o)
        case .array(var a):
            guard let i = Int(k), i >= 0, i <= a.count else {
                throw CLIError("'\(fullPath)': index \(k) is out of range (the list has \(a.count) item\(a.count == 1 ? "" : "s")).", code: .dataError)
            }
            if i == a.count { a.append(try setting(new, at: rest, in: .object([:]), fullPath: fullPath)) } else {
                a[i] = try setting(new, at: rest, in: a[i], fullPath: fullPath)
            }
            return .array(a)
        case .null:
            return .object([k: try setting(new, at: rest, in: .object([:]), fullPath: fullPath)])
        default:
            throw CLIError("'\(fullPath)': can't set a key inside a \(v.typeName).", code: .dataError)
        }
    }

    static func isColor(_ v: JSONValue) -> Bool {
        guard case .object(let o) = v else { return false }
        return Set(o.keys) == ["r", "g", "b", "a"]
    }

    static func color(_ hex: String) -> JSONValue? {
        guard let c = RGBA(hex: hex) else { return nil }
        return try? JSONValue.encode(c)
    }

    /// Turns the input into the JSON shape the document expects at that key (colours from hex, strings kept as strings).
    static func coerce(_ input: Value, current: JSONValue?, key: String) throws -> JSONValue {
        let parsed: JSONValue
        switch input {
        case .json(let j): parsed = j
        case .raw(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            if let j = try? JSONValue.parse(t) { parsed = j } else { parsed = .string(s) }
        }
        // Colours: "#RRGGBB" for a colour, "#A,#B" (or a JSON array of hex strings) for a colour list.
        if let current, isColor(current), case .string(let s) = parsed {
            guard let c = color(s) else { throw CLIError("\(key) expects a colour like #FF5A36 (got '\(s)').", code: .dataError) }
            return c
        }
        if case .array(let items)? = current, items.first.map(isColor) ?? key.hasSuffix("colors") {
            var hexes: [String] = []
            if case .string(let s) = parsed { hexes = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            if case .array(let a) = parsed, a.allSatisfy({ $0.stringValue != nil }) { hexes = a.compactMap(\.stringValue) }
            if !hexes.isEmpty {
                let colors = hexes.compactMap(color)
                guard colors.count == hexes.count else {
                    throw CLIError("\(key) expects colours like #F6C68B,#E2795C.", code: .dataError)
                }
                return .array(colors)
            }
        }
        // A string field given something that parsed as a number or bool keeps the literal text.
        if case .raw(let s) = input, case .string? = current, parsed.stringValue == nil, !parsed.isNull {
            return .string(s)
        }
        if case .raw(let s) = input, current == nil, optionalKeys.contains(key), key == "title" || key.hasSuffix("Path") || key.hasSuffix("file"),
           parsed.stringValue == nil, !parsed.isNull {
            return .string(s)
        }
        return parsed
    }

    static func describe(_ e: DecodingError, assignments: [Assignment]) -> String {
        func path(_ ctx: DecodingError.Context) -> String {
            ctx.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        switch e {
        case .dataCorrupted(let ctx):
            let key = path(ctx)
            let allowed = allowedValues(forKey: key)
            return "Invalid value for \(key)." + (allowed.map { " Use one of: \($0.joined(separator: ", "))." } ?? " \(ctx.debugDescription)")
        case .typeMismatch(let type, let ctx):
            return "Invalid value for \(path(ctx)): expected \(friendly(type))."
        case .valueNotFound(let type, let ctx):
            return "Missing value for \(path(ctx)): expected \(friendly(type))."
        case .keyNotFound(let k, let ctx):
            let p = path(ctx)
            return "Missing key '\(p.isEmpty ? k.stringValue : p + "." + k.stringValue)'."
        @unknown default:
            return "Invalid edit: \(e.localizedDescription)"
        }
    }

    static func friendly(_ type: Any.Type) -> String {
        let n = String(describing: type)
        if n.contains("Double") || n.contains("Int") { return "a number" }
        if n.contains("Bool") { return "true or false" }
        if n.contains("String") { return "text" }
        if n.contains("Array") { return "a list" }
        return "an object"
    }

    static func allowedValues(forKey key: String) -> [String]? {
        switch key {
        case "zoom.mode": return [ZoomSettings.Mode.auto, .manual, .off].map(\.rawValue)
        case "cursor.clickEffect": return [CursorSettings.ClickEffect.none, .ripple, .ring, .press].map(\.rawValue)
        case "background.kind": return [BackgroundSettings.Kind.none, .solid, .gradient, .image].map(\.rawValue)
        case "camera.shape": return CameraLayout.Shape.allCases.map(\.rawValue)
        case "camera.corner": return CameraLayout.Corner.allCases.map(\.rawValue)
        case "canvas.aspect": return CanvasSettings.Aspect.allCases.map(\.rawValue)
        default: return nil
        }
    }
}
