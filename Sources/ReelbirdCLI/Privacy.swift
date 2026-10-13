import Foundation
import ReelbirdAI
import ReelbirdCore
import ReelbirdRender

/// `reelbird blur`, `reelbird redact` and `reelbird annotate`, and the matching MCP tools: privacy blurs and
/// overlays in edit.json. Find Sensitive Info runs on this Mac; its JSON shows masked previews only.
enum PrivacyCLI {
    static let blurSpec = CommandSpec(name: "blur", summary: "Blur (or pixelate) an area of the screen for a stretch of time.",
                                      positionals: ["PROJECT"], options: [
        .value("rect", "X,Y,W,H", "The area: 0–1 fractions of the screen video, or its pixels"),
        .value("from", "TIME", "Start, in seconds or m:ss (default 0)"),
        .value("to", "TIME", "End (default: the end of the recording)"),
        .flag("pixelate", "Pixelate instead of blur"),
        .value("strength", "0-1", "Coarseness (default 0.5); every strength leaves text unreadable"),
    ], discussion: "Rects are in screen-video coordinates (top-left origin), so the blur stays on the content through zoom, crop and aspect. Prints the new overlay's ID.")

    static let redactSpec = CommandSpec(name: "redact", summary: "Find emails, API keys, card and phone numbers on screen and blur them.",
                                        positionals: ["PROJECT"], options: [
        .flag("auto", "Scan the screen video on this Mac (required)"),
        .flag("keep-all", "Blur everything found"),
        .value("keep", "ID", "Blur only these findings (from a --dry-run)", repeatable: true),
        .flag("dry-run", "List what was found without changing anything (the default)"),
        .value("kinds", "LIST", "Only these: email,key,card,phone (default all)"),
        .value("word", "WORD", "Also find this word or phrase", repeatable: true),
        .flag("pixelate", "Pixelate instead of blur"),
        .value("strength", "0-1", "Coarseness of the blurs (default 0.5)"),
    ], discussion: "Text recognition and matching run on this Mac; nothing is uploaded. Findings show masked previews (sk-p…F2), never the full value. IDs stay the same between scans, so you can --dry-run, choose, then --keep.")

    static let annotateSpec = CommandSpec(name: "annotate", summary: "List, add or remove overlays: blur, arrow, box, text, highlight.",
                                          positionals: ["PROJECT"], options: [
        .value("add", "KIND", "Add one: blur, pixelate, arrow, box, text or highlight"),
        .value("rect", "X,Y,W,H", "Its area (0–1 fractions of the screen video, or pixels)"),
        .value("arrow", "X1,Y1,X2,Y2", "An arrow from (X1, Y1) to its head at (X2, Y2)"),
        .value("from", "TIME", "Start (default 0)"),
        .value("to", "TIME", "End (default: the end)"),
        .value("text", "TEXT", "The label (text)"),
        .value("size", "FRACTION", "Text size as a fraction of the screen's height (default 0.03)"),
        .value("color", "#RRGGBB", "Colour of an arrow, box or label (default coral #FF5A36)"),
        .value("strength", "0-1", "Blur coarseness (default 0.5)"),
        .value("remove", "ID", "Remove an overlay", repeatable: true),
        .flag("clear", "Remove every overlay"),
    ], discussion: "With no changes, lists the overlays. Positions are in screen-video coordinates (top-left origin).")

    static func run(_ name: String, _ a: ParsedArguments, ops: Operations, project: String) async throws -> Report {
        switch name {
        case "blur":
            guard let rect = a.value("rect") else { throw CLIError.usage("Missing --rect X,Y,W,H.", hint: "See: reelbird blur --help") }
            return try ops.addOverlay(project, kind: a.has("pixelate") ? "pixelate" : "blur", rect: rect, arrow: nil,
                                      from: a.value("from"), to: a.value("to"), text: nil, size: nil, color: nil, strength: try a.double("strength"))
        case "redact":
            guard a.has("auto") else {
                throw CLIError.usage("redact needs --auto (scan the recording for sensitive text).", hint: "To blur an area by hand: reelbird blur --help")
            }
            if a.has("keep-all") && (a.has("dry-run") || !a.all("keep").isEmpty) {
                throw CLIError.usage("Use --keep-all, --keep or --dry-run, not several.")
            }
            let keep: Operations.RedactKeep = a.has("keep-all") ? .all : a.all("keep").isEmpty ? .none : .ids(Set(a.all("keep")))
            let bar = ProgressLine("Reading the screen…")
            defer { bar.finish() }
            return try await ops.redact(project, keep: keep, kinds: try kinds(a.value("kinds")), words: a.all("word"),
                                        pixelate: a.has("pixelate"), strength: try a.double("strength"), progress: { bar.update($0) })
        default:
            let removing = !a.all("remove").isEmpty || a.has("clear")
            if let kind = a.value("add") {
                if removing { throw CLIError.usage("Add and remove in separate commands.") }
                return try ops.addOverlay(project, kind: kind, rect: a.value("rect"), arrow: a.value("arrow"), from: a.value("from"), to: a.value("to"),
                                          text: a.value("text"), size: try a.double("size"), color: a.value("color"), strength: try a.double("strength"))
            }
            if removing { return try ops.removeOverlays(project, ids: a.all("remove"), all: a.has("clear")) }
            return try ops.listOverlays(project)
        }
    }

    static func kinds(_ list: String?) throws -> Set<SensitiveKind> {
        guard let list else { return Set(SensitiveKind.allCases).subtracting([.custom]) }
        var out = Set<SensitiveKind>()
        for part in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            guard let k = SensitiveKind(cliName: part) else { throw CLIError.usage("Unknown kind '\(part)'. Use email, key, card, phone.") }
            out.insert(k)
        }
        return out
    }
}

extension Operations {
    enum RedactKeep: Sendable, Equatable { case none, all, ids(Set<String>) }

    /// "X,Y,W,H" in 0–1 fractions, or pixels of the screen video when any value is above 1.
    static func parseRect(_ s: String, screen: PixelSize) throws -> NormRect {
        let v = try numbers(s, count: 4, what: "--rect X,Y,W,H")
        let pixels = v.contains { $0 > 1 }
        let sw = pixels ? Double(max(1, screen.width)) : 1, sh = pixels ? Double(max(1, screen.height)) : 1
        let r = NormRect(x: v[0] / sw, y: v[1] / sh, width: v[2] / sw, height: v[3] / sh)
        guard r.width > 0, r.height > 0, r.x < 1, r.y < 1, r.x + r.width > 0, r.y + r.height > 0 else {
            throw CLIError.usage("The area '\(s)' is empty or off the screen.")
        }
        guard r.x < 0 || r.y < 0 || r.x + r.width > 1 || r.y + r.height > 1 else { return r }
        let x0 = max(0, r.x), y0 = max(0, r.y)
        return NormRect(x: x0, y: y0, width: min(1, r.x + r.width) - x0, height: min(1, r.y + r.height) - y0)
    }

    static func numbers(_ s: String, count: Int, what: String) throws -> [Double] {
        let v = s.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard v.count == count, v.allSatisfy({ $0 != nil && $0!.isFinite }) else { throw CLIError.usage("Expected \(what), got '\(s)'.") }
        return v.map { $0! }
    }

    /// A time range from --from / --to (seconds or m:ss), within the recording.
    static func overlayRange(from: String?, to: String?, duration: Double) throws -> TimeRange {
        func t(_ s: String?, _ name: String, _ fallback: Double) throws -> Double {
            guard let s else { return fallback }
            if s.lowercased() == "end" { return duration }
            guard let v = TimeParsing.seconds(s) else { throw CLIError.usage("--\(name) expects seconds or m:ss, got '\(s)'.") }
            return v
        }
        let start = try t(from, "from", 0), end = min(duration, try t(to, "to", duration))
        guard start < duration else { throw CLIError.usage("--from \(Format.seconds(start)) is past the end (\(Format.seconds(duration)) s).") }
        guard end > start else { throw CLIError.usage("--to must be after --from.") }
        return TimeRange(start: start, end: end)
    }

    private func load(_ project: String) throws -> (ProjectBundle, ProjectManifest, EditDocument) {
        let bundle = try locator.resolve(project)
        let manifest: ProjectManifest
        do { manifest = try bundle.readManifest() } catch { throw CLIError("Can't read project.json: \(error.localizedDescription)", code: .dataError) }
        do { return (bundle, manifest, try bundle.readEdit()) } catch {
            throw CLIError("Can't read edit.json: \(error.localizedDescription)", code: .dataError)
        }
    }

    /// Read, change and write edit.json, starting again if someone else wrote it in between (MCP calls run
    /// concurrently; the editor may be saving too), so no change is lost. Returns what `body` returns.
    private func mutateEdit<T>(_ bundle: ProjectBundle, _ body: (inout EditDocument) throws -> T) throws -> T {
        try Self.editLock.withLock {
            for _ in 0..<8 {
                var (edit, revision) = try bundle.readEditStamped()
                let result = try body(&edit)
                do {
                    try bundle.writeEdit(edit, ifRevision: revision)
                    return result
                } catch is EditConflict {
                    continue
                } catch {
                    throw CLIError("Can't write edit.json: \(error.localizedDescription)")
                }
            }
            throw CLIError("edit.json kept changing while saving; try again.")
        }
    }
    private static let editLock = NSLock()

    static func json(_ a: Annotation) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(a.id), "kind": .string(a.kind == .blur && a.blurStyle == .pixelate ? "pixelate" : a.kind.rawValue),
            "start": JSONValue(a.range.start), "end": JSONValue(a.range.end),
            "rect": ["x": JSONValue(a.rect.x), "y": JSONValue(a.rect.y), "width": JSONValue(a.rect.width), "height": JSONValue(a.rect.height)],
        ]
        switch a.kind {
        case .blur:
            o["strength"] = JSONValue(a.blurStrength)
            if let d = a.detected { o["detected"] = .string(d) }
            if let k = a.keys { o["keys"] = .int(k.count) }
        case .arrow:
            let e = a.arrowEnds
            o["tail"] = ["x": JSONValue(e.tail.x), "y": JSONValue(e.tail.y)]
            o["head"] = ["x": JSONValue(e.head.x), "y": JSONValue(e.head.y)]
            o["color"] = .string(a.color.hex)
        case .box: o["color"] = .string(a.color.hex)
        case .text:
            o["text"] = .string(a.text ?? "")
            o["size"] = JSONValue(a.textSize)
            o["color"] = .string(a.color.hex)
        case .highlight: break
        }
        return .object(o)
    }

    static func line(_ a: Annotation) -> String {
        let kind = a.kind == .blur && a.blurStyle == .pixelate ? "pixelate" : a.kind.rawValue
        var s = "\(a.id)  \(kind.padding(toLength: 9, withPad: " ", startingAt: 0)) \(Format.duration(a.range.start))–\(Format.duration(a.range.end))"
        s += String(format: "  at %.3f,%.3f %.3f×%.3f", a.rect.x, a.rect.y, a.rect.width, a.rect.height)
        if let t = a.text, a.kind == .text { s += "  \"\(t)\"" }
        if let d = a.detected { s += "  (\(SensitiveKind(rawValue: d)?.title ?? d))" }
        return s
    }

    func listOverlays(_ project: String) throws -> Report {
        let (_, _, edit) = try load(project)
        let items = edit.annotations.sorted { ($0.range.start, $0.id) < ($1.range.start, $1.id) }
        return Report(json: ["annotations": .array(items.map(Self.json))],
                      text: items.isEmpty ? "No overlays." : items.map(Self.line).joined(separator: "\n"))
    }

    /// Adds one overlay (blur, pixelate, arrow, box, text, highlight).
    func addOverlay(_ project: String, kind kindName: String, rect: String?, arrow: String?, from: String?, to: String?,
                    text: String?, size: Double?, color: String?, strength: Double?) throws -> Report {
        let (bundle, manifest, _) = try load(project)
        let screen = manifest.track(.screen)?.pixelSize ?? manifest.capture.pixelSize
        let name = kindName.lowercased()
        let kind: Annotation.Kind
        switch name {
        case "pixelate": kind = .blur
        default:
            guard let k = Annotation.Kind(rawValue: name) else {
                throw CLIError.usage("Unknown overlay '\(kindName)'. Use blur, pixelate, arrow, box, text or highlight.")
            }
            kind = k
        }
        if let strength, !(0...1).contains(strength) { throw CLIError.usage("--strength must be between 0 and 1.") }
        if let size, !(0.005...0.5).contains(size) { throw CLIError.usage("--size must be between 0.005 and 0.5 (a fraction of the screen's height).") }
        var parsedColor: RGBA?
        if let color {
            guard let c = RGBA(hex: color) else { throw CLIError.usage("--color expects #RRGGBB, got '\(color)'.") }
            parsedColor = c
        }
        let duration = manifest.duration > 0 ? manifest.duration : (manifest.track(.screen)?.duration ?? 0)
        guard duration > 0 else { throw CLIError("This recording has no length yet.", code: .dataError) }
        let range = try Self.overlayRange(from: from, to: to, duration: duration)
        var a: Annotation
        if kind == .arrow {
            guard let arrow else { throw CLIError.usage("An arrow needs --arrow X1,Y1,X2,Y2 (from the tail to the head).") }
            let v = try Self.numbers(arrow, count: 4, what: "--arrow X1,Y1,X2,Y2")
            let pixels = v.contains { $0 > 1 }
            let sw = pixels ? Double(max(1, screen.width)) : 1, sh = pixels ? Double(max(1, screen.height)) : 1
            func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
            a = Annotation(kind: .arrow, range: range, rect: .full)
            a.setArrow(tail: NormPoint(x: clamp(v[0] / sw), y: clamp(v[1] / sh)), head: NormPoint(x: clamp(v[2] / sw), y: clamp(v[3] / sh)))
        } else if kind == .text {
            guard let text, !text.isEmpty else { throw CLIError.usage("A text overlay needs --text.") }
            let r: NormRect
            if let rect { r = try Self.parseRect(rect, screen: screen) } else { r = NormRect(x: 0.05, y: 0.05, width: 0.3, height: 0.05) }
            a = Annotation(kind: .text, range: range, rect: r, text: text)
            a.fontSize = size ?? 0.03
            // The label's box, sized as the renderer draws it (so the editor's handles fit it).
            let label = AnnotationLabel.labelSize(text: text, fontPixels: a.textSize * Double(screen.height))
            a.rect = NormRect(x: r.x, y: r.y, width: min(1, Double(label.width) / Double(max(1, screen.width))),
                              height: min(1, Double(label.height) / Double(max(1, screen.height))))
        } else {
            guard let rect else { throw CLIError.usage("Give the area with --rect X,Y,W,H.") }
            a = Annotation(kind: kind, range: range, rect: try Self.parseRect(rect, screen: screen))
            if kind == .blur {
                a.style = name == "pixelate" ? .pixelate : .blur
                a.strength = strength ?? Annotation.defaultStrength
            }
        }
        if let parsedColor, [.arrow, .box, .text].contains(kind) { a.color = parsedColor }
        let count = try mutateEdit(bundle) { edit -> Int in
            edit.annotations.append(a)
            return edit.annotations.count
        }
        return Report(json: ["added": Self.json(a), "count": .int(count)],
                      text: "Added \(kind == .blur ? (a.blurStyle == .pixelate ? "pixelate" : "blur") : kind.rawValue) \(a.id) from \(Format.duration(range.start)) to \(Format.duration(range.end)).")
    }

    func removeOverlays(_ project: String, ids: [String], all: Bool) throws -> Report {
        let (bundle, _, _) = try load(project)
        let (removed, count) = try mutateEdit(bundle) { edit -> (Int, Int) in
            let known = Set(edit.annotations.map(\.id))
            let missing = ids.filter { !known.contains($0) }
            guard missing.isEmpty else {
                throw CLIError("No overlay with ID \(missing.joined(separator: ", ")).", code: .dataError, hint: "List them with: reelbird annotate \(project)")
            }
            let before = edit.annotations.count
            if all { edit.annotations = [] } else { edit.annotations.removeAll { ids.contains($0.id) } }
            return (before - edit.annotations.count, edit.annotations.count)
        }
        return Report(json: ["removed": .int(removed), "count": .int(count)],
                      text: "Removed \(removed) overlay\(removed == 1 ? "" : "s").")
    }

    /// Scans the screen video for sensitive text and, with `keep`, blurs what was found.
    func redact(_ project: String, keep: RedactKeep, kinds: Set<SensitiveKind>, words: [String], pixelate: Bool, strength: Double?,
                progress: @escaping @Sendable (Double) -> Void) async throws -> Report {
        let (bundle, _, _) = try load(project)
        if let strength, !(0...1).contains(strength) { throw CLIError.usage("--strength must be between 0 and 1.") }
        var options = SensitiveInfoScanner.Options()
        options.kinds = kinds.union(words.isEmpty ? [] : [.custom])
        options.customWords = words
        let result: SensitiveInfoScanner.Result
        do { result = try await SensitiveInfoScanner.scan(bundle: bundle, options: options, progress: progress) } catch let e as SensitiveInfoScanner.ScanError {
            throw CLIError(e.localizedDescription, code: .dataError)
        }
        let chosen: [SensitiveDetection]
        switch keep {
        case .none: chosen = []
        case .all: chosen = result.detections
        case .ids(let ids):
            let unknown = ids.subtracting(result.detections.map(\.id))
            guard unknown.isEmpty else {
                throw CLIError("No finding with ID \(unknown.sorted().joined(separator: ", ")).", code: .dataError,
                               hint: "Run with --dry-run to list the findings and their IDs.")
            }
            chosen = result.detections.filter { ids.contains($0.id) }
        }
        // edit.json is read after the scan, so edits made meanwhile are kept.
        let (existing, added) = try chosen.isEmpty ? (Set((try bundle.readEdit()).annotations.map(\.id)), [])
            : mutateEdit(bundle) { edit -> (Set<String>, [SensitiveDetection]) in
                let existing = Set(edit.annotations.map(\.id))
                let added = chosen.filter { !existing.contains($0.id) }
                for d in added {
                    edit.annotations.append(d.annotation(style: pixelate ? .pixelate : .blur, strength: strength ?? Annotation.defaultStrength))
                }
                return (existing, added)
            }
        let keptIDs = Set(chosen.map(\.id))
        let rows: [JSONValue] = result.detections.map { d in
            ["id": .string(d.id), "kind": .string(d.kind.rawValue), "preview": .string(d.preview),
             "start": JSONValue(d.range.start), "end": JSONValue(d.range.end),
             "rect": ["x": JSONValue(d.rect.x), "y": JSONValue(d.rect.y), "width": JSONValue(d.rect.width), "height": JSONValue(d.rect.height)],
             "sightings": .int(d.sightings), "moves": .bool(Set(d.keys.map(\.rect)).count > 1), "blurred": .bool(keptIDs.contains(d.id) || existing.contains(d.id))]
        }
        var lines = ["\(result.detections.count) finding\(result.detections.count == 1 ? "" : "s") in \(String(format: "%.1f", result.seconds)) s:"]
        for d in result.detections {
            lines.append("  \(d.id)  \(d.kind.title.padding(toLength: 12, withPad: " ", startingAt: 0)) \(d.preview.padding(toLength: 18, withPad: " ", startingAt: 0)) "
                         + "\(Format.duration(d.range.start))–\(Format.duration(d.range.end))\(keptIDs.contains(d.id) ? "  blurred" : "")")
        }
        switch keep {
        case .none: if !result.detections.isEmpty { lines.append("Nothing changed. Blur them with --keep-all, or --keep ID.") }
        default: lines.append("Added \(added.count) blur\(added.count == 1 ? "" : "s") to edit.json.")
        }
        return Report(json: ["detections": .array(rows), "added": .int(added.count), "applied": .bool(keep != .none),
                             "seconds": JSONValue(result.seconds), "samples": .int(result.samples), "recognized": .int(result.recognized)],
                      text: lines.joined(separator: "\n"))
    }
}
