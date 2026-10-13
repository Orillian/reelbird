import Foundation
import ReelbirdCore

// MCP tools for privacy blurs and overlays, so an agent can redact a recording before sharing it.
extension MCPTools {
    private static let rect: JSONValue = object([
        "x": ["type": "number"], "y": ["type": "number"],
        "width": ["type": "number", "exclusiveMinimum": 0], "height": ["type": "number", "exclusiveMinimum": 0],
    ], required: ["x", "y", "width", "height"])
    private static let time: JSONValue = ["type": ["number", "string"], "description": "Seconds, or \"m:ss\"."]

    static let privacyDefinitions: [JSONValue] = [
        tool("blur_region", "Blur a region",
             "Blurs (or pixelates) an area of the screen for a stretch of time. rect is in 0–1 fractions of the screen video (top-left origin), or its pixels when any value is above 1; the blur stays on that content through zoom, crop and aspect. Every strength leaves text unreadable.",
             object([
                "project": project,
                "rect": rect,
                "from": time, "to": time,
                "style": ["type": "string", "enum": ["blur", "pixelate"], "default": "blur"],
                "strength": ["type": "number", "minimum": 0, "maximum": 1, "default": 0.5],
             ], required: ["project", "rect"])),
        tool("find_sensitive_info", "Find and blur sensitive info",
             "Reads the screen video on this Mac (Vision text recognition, nothing uploaded) and finds emails, API keys and tokens, card numbers (Luhn-checked) and phone numbers, plus any `words`. Returns each finding with a stable id, a masked preview (never the full value), its time range and area. Nothing changes unless keep_all is true or `keep` lists ids; kept findings become blurs that follow the text if it moves. Run this before sharing a recording that showed settings, terminals or dashboards.",
             object([
                "project": project,
                "keep_all": ["type": "boolean", "default": false, "description": "Blur every finding."],
                "keep": ["type": "array", "items": ["type": "string"], "description": "Blur only these finding ids (from an earlier call)."],
                "kinds": ["type": "array", "items": ["type": "string", "enum": ["email", "key", "card", "phone"]],
                          "description": "Only these kinds; default all."],
                "words": ["type": "array", "items": ["type": "string"], "description": "Also find these words or phrases (names, code names)."],
                "style": ["type": "string", "enum": ["blur", "pixelate"], "default": "blur"],
                "strength": ["type": "number", "minimum": 0, "maximum": 1, "default": 0.5],
             ], required: ["project"])),
        tool("list_annotations", "List overlays", "Lists the project's overlays (blur, pixelate, arrow, box, text, highlight) with ids, times and areas.",
             object(["project": project], required: ["project"]), readOnly: true),
        tool("add_annotation", "Add an overlay",
             "Adds an overlay. kind: blur, pixelate, arrow, box, text or highlight. Areas are 0–1 fractions of the screen video (top-left origin). An arrow goes from `tail` to `head`; text needs `text` (size is a fraction of the screen's height, default 0.03). color is #RRGGBB (default coral #FF5A36).",
             object([
                "project": project,
                "kind": ["type": "string", "enum": ["blur", "pixelate", "arrow", "box", "text", "highlight"]],
                "rect": rect,
                "tail": object(["x": ["type": "number"], "y": ["type": "number"]], required: ["x", "y"]),
                "head": object(["x": ["type": "number"], "y": ["type": "number"]], required: ["x", "y"]),
                "from": time, "to": time,
                "text": ["type": "string"],
                "size": ["type": "number", "minimum": 0.005, "maximum": 0.5],
                "color": ["type": "string", "description": "#RRGGBB"],
                "strength": ["type": "number", "minimum": 0, "maximum": 1],
             ], required: ["project", "kind"])),
        tool("remove_annotations", "Remove overlays", "Removes overlays by id, or all of them with all: true.",
             object([
                "project": project,
                "ids": ["type": "array", "items": ["type": "string"]],
                "all": ["type": "boolean", "default": false],
             ], required: ["project"]), destructive: true),
    ]
}

extension ToolArguments {
    /// "X,Y,W,H" from an object {x, y, width, height}.
    func rectString(_ key: String) throws -> String? {
        guard let v = raw[key], !v.isNull else { return nil }
        guard case .object(let o) = v, let x = o["x"]?.doubleValue, let y = o["y"]?.doubleValue,
              let w = o["width"]?.doubleValue, let h = o["height"]?.doubleValue else {
            throw CLIError.usage("Argument '\(key)' must be {x, y, width, height}.")
        }
        return "\(x),\(y),\(w),\(h)"
    }

    func point(_ key: String) throws -> (Double, Double)? {
        guard let v = raw[key], !v.isNull else { return nil }
        guard case .object(let o) = v, let x = o["x"]?.doubleValue, let y = o["y"]?.doubleValue else {
            throw CLIError.usage("Argument '\(key)' must be {x, y}.")
        }
        return (x, y)
    }

    /// A time as seconds or "m:ss".
    func timeString(_ key: String) throws -> String? {
        guard let v = raw[key], !v.isNull else { return nil }
        if let d = v.doubleValue { return String(d) }
        if let s = v.stringValue { return s }
        throw CLIError.usage("Argument '\(key)' must be seconds or \"m:ss\".")
    }

    func strings(_ key: String) throws -> [String] {
        guard let v = raw[key], !v.isNull else { return [] }
        guard case .array(let items) = v, items.allSatisfy({ $0.stringValue != nil }) else {
            throw CLIError.usage("Argument '\(key)' must be a list of strings.")
        }
        return items.compactMap(\.stringValue)
    }
}

extension MCPServer {
    /// The privacy tools, or nil for another tool name.
    func runPrivacyTool(_ name: String, _ a: ToolArguments, progress: @escaping @Sendable (Double) -> Void) async throws -> Report? {
        switch name {
        case "blur_region":
            guard let rect = try a.rectString("rect") else { throw CLIError.usage("Missing required argument 'rect'.") }
            let style = try a.string("style") ?? "blur"
            guard ["blur", "pixelate"].contains(style) else { throw CLIError.usage("style must be blur or pixelate.") }
            return try ops.addOverlay(try a.requiredString("project"), kind: style, rect: rect, arrow: nil,
                                      from: try a.timeString("from"), to: try a.timeString("to"), text: nil, size: nil, color: nil,
                                      strength: try a.double("strength"))
        case "find_sensitive_info":
            let keepIDs = try a.strings("keep")
            let keepAll = try a.bool("keep_all") ?? false
            if keepAll && !keepIDs.isEmpty { throw CLIError.usage("Use keep_all or keep, not both.") }
            let style = try a.string("style") ?? "blur"
            guard ["blur", "pixelate"].contains(style) else { throw CLIError.usage("style must be blur or pixelate.") }
            let kinds = try a.strings("kinds")
            return try await ops.redact(try a.requiredString("project"), keep: keepAll ? .all : keepIDs.isEmpty ? .none : .ids(Set(keepIDs)),
                                        kinds: try PrivacyCLI.kinds(kinds.isEmpty ? nil : kinds.joined(separator: ",")),
                                        words: try a.strings("words"), pixelate: style == "pixelate", strength: try a.double("strength"),
                                        progress: progress)
        case "list_annotations":
            return try ops.listOverlays(try a.requiredString("project"))
        case "add_annotation":
            let kind = try a.requiredString("kind")
            var arrow: String?
            if let t = try a.point("tail"), let h = try a.point("head") { arrow = "\(t.0),\(t.1),\(h.0),\(h.1)" }
            return try ops.addOverlay(try a.requiredString("project"), kind: kind, rect: try a.rectString("rect"), arrow: arrow,
                                      from: try a.timeString("from"), to: try a.timeString("to"), text: try a.string("text"),
                                      size: try a.double("size"), color: try a.string("color"), strength: try a.double("strength"))
        case "remove_annotations":
            return try ops.removeOverlays(try a.requiredString("project"), ids: try a.strings("ids"), all: try a.bool("all") ?? false)
        default:
            return nil
        }
    }
}
