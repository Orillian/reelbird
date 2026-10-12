import Foundation
import ReelbirdCore

/// Finds projects by path, name, ID or "latest".
struct ProjectLocator: Sendable {
    let library: ProjectLibrary

    init(libraryPath: String?) {
        if let p = libraryPath ?? ProcessInfo.processInfo.environment["REELBIRD_LIBRARY"], !p.isEmpty {
            library = ProjectLibrary(root: URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true))
        } else {
            library = ProjectLibrary()
        }
    }

    /// Resolves a PROJECT argument: a `.reelbird` path, "latest", a bundle name (or unique prefix) in the library, or a project ID.
    func resolve(_ arg: String) throws -> ProjectBundle {
        let fm = FileManager.default
        let expanded = (arg as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            let bundle = ProjectBundle(url: URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL)
            guard fm.fileExists(atPath: bundle.manifestURL.path) else {
                throw CLIError("\(Format.path(bundle.url)) is not a Reelbird project (no project.json).", code: .noInput)
            }
            return bundle
        }
        let all = library.list()
        if ["latest", "last"].contains(arg.lowercased()) {
            guard let first = all.first else {
                throw CLIError("No projects in \(Format.path(library.root)).", code: .noInput)
            }
            return first
        }
        let key = arg.lowercased().replacingOccurrences(of: ".\(ProjectBundle.pathExtension)", with: "")
        func name(_ b: ProjectBundle) -> String { b.url.deletingPathExtension().lastPathComponent.lowercased() }
        if let exact = all.first(where: { name($0) == key }) { return exact }
        if let byID = all.first(where: { (try? $0.readManifest().id) == arg }) { return byID }
        let prefixed = all.filter { name($0).hasPrefix(key) }
        if prefixed.count == 1 { return prefixed[0] }
        if prefixed.count > 1 {
            throw CLIError("'\(arg)' matches \(prefixed.count) projects; be more specific.", code: .usage,
                           hint: prefixed.prefix(5).map { "  " + $0.url.lastPathComponent }.joined(separator: "\n"))
        }
        throw CLIError("Project not found: \(arg)", code: .noInput,
                       hint: "Pass a .reelbird path, a project name from `reelbird list`, or \"latest\".")
    }
}

/// Read-only summaries of projects.
enum ProjectSummary {
    static func describe(_ source: CaptureSource) -> String {
        switch source {
        case .display(let id, let name): return name.isEmpty ? "Display \(id)" : name
        case .window(_, let app, let title): return title.isEmpty ? app : "\(app) — \(title)"
        case .area(_, let x, let y, let w, let h): return "Area \(Int(w))×\(Int(h)) at \(Int(x)),\(Int(y))"
        case .synthetic(let name): return "Synthetic (\(name))"
        }
    }

    static func brief(_ bundle: ProjectBundle) -> JSONValue {
        guard let m = try? bundle.readManifest() else {
            return ["path": .string(bundle.url.path), "name": .string(bundle.url.deletingPathExtension().lastPathComponent),
                    "error": "unreadable project.json"]
        }
        let edit = try? bundle.readEdit()
        return [
            "path": .string(bundle.url.path),
            "name": .string(bundle.url.deletingPathExtension().lastPathComponent),
            "id": .string(m.id),
            "title": .string(edit?.title ?? m.title),
            "createdAt": .string(Format.iso(m.createdAt)),
            "status": .string(m.status.rawValue),
            "duration": JSONValue(m.duration),
            "shareURL": JSONValue(m.share?.url),
        ]
    }

    static func info(_ bundle: ProjectBundle) throws -> Report {
        let m: ProjectManifest
        do { m = try bundle.readManifest() } catch {
            throw CLIError("Can't read \(Format.path(bundle.manifestURL)): \(error.localizedDescription)", code: .dataError)
        }
        let e: EditDocument
        do { e = try bundle.readEdit() } catch {
            throw CLIError("Can't read \(Format.path(bundle.editURL)): \(error.localizedDescription)", code: .dataError)
        }
        let timeline = EditTimeline(manifest: m, edit: e)
        let fm = FileManager.default
        let hasCaptions = fm.fileExists(atPath: bundle.captionsURL.path)
        let hasTranscript = fm.fileExists(atPath: Operations.transcriptURL(bundle).path)
        let exports = ((try? fm.contentsOfDirectory(at: bundle.exportsURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }.map(\.path).sorted()

        let tracks: [JSONValue] = m.tracks.map { t in
            [
                "kind": .string(t.kind.rawValue), "codec": .string(t.codec), "duration": JSONValue(t.duration),
                "startTime": JSONValue(t.startTime), "file": JSONValue(t.file),
                "width": JSONValue(t.pixelSize?.width), "height": JSONValue(t.pixelSize?.height),
                "sampleRate": JSONValue(t.sampleRate), "segments": .int(t.segmentCount),
            ]
        }
        let json: JSONValue = [
            "path": .string(bundle.url.path),
            "id": .string(m.id),
            "title": .string(e.title ?? m.title),
            "status": .string(m.status.rawValue),
            "createdAt": .string(Format.iso(m.createdAt)),
            "appVersion": .string(m.appVersion),
            "source": .string(describe(m.capture.source)),
            "width": .int(m.capture.pixelSize.width),
            "height": .int(m.capture.pixelSize.height),
            "frameRate": .int(m.capture.frameRate),
            "duration": JSONValue(m.duration),
            "outputDuration": JSONValue(timeline.duration),
            "tracks": .array(tracks),
            "pauses": .int(m.pauses.count),
            "edit": [
                "trim": e.trim.map { ["start": JSONValue($0.start), "end": JSONValue($0.end)] } ?? .null,
                "cuts": .array(e.cuts.map { ["start": JSONValue($0.start), "end": JSONValue($0.end)] }),
                "zoom": ["mode": .string(e.zoom.mode.rawValue), "intensity": JSONValue(e.zoom.intensity), "regions": .int(e.zoom.regions.count)],
                "background": .string(e.background.kind.rawValue),
                "aspect": .string(e.canvas.aspect.rawValue),
                "captionsFile": JSONValue(e.captions.file),
                "annotations": .int(e.annotations.count),
            ],
            "chapters": .array(e.chapters.map { ["time": JSONValue($0.time), "title": .string($0.title)] }),
            "captions": .bool(hasCaptions),
            "transcript": .bool(hasTranscript),
            "share": m.share.map { ["url": .string($0.url), "polished": .bool($0.polished), "updatedAt": .string(Format.iso($0.updatedAt))] } ?? .null,
            "exports": .array(exports.map(JSONValue.string)),
        ]

        var lines: [String] = []
        lines.append(e.title ?? m.title)
        lines.append("  Path       \(Format.path(bundle.url))")
        lines.append("  Recorded   \(Format.date(m.createdAt))  (\(m.status.rawValue))")
        lines.append("  Source     \(describe(m.capture.source)), \(m.capture.pixelSize.width)×\(m.capture.pixelSize.height) @ \(m.capture.frameRate) fps")
        var len = "  Length     \(Format.duration(m.duration))"
        if abs(timeline.duration - m.duration) > 0.01 { len += " → \(Format.duration(timeline.duration)) after edits" }
        lines.append(len)
        lines.append("  Tracks     " + (m.tracks.isEmpty ? "none" : m.tracks.map(\.kind.rawValue).joined(separator: ", ")))
        var editBits: [String] = []
        if let t = e.trim { editBits.append("trim \(Format.seconds(t.start))–\(Format.seconds(t.end))s") }
        if !e.cuts.isEmpty { editBits.append("\(e.cuts.count) cut\(e.cuts.count == 1 ? "" : "s")") }
        editBits.append("zoom \(e.zoom.mode.rawValue) \(Format.seconds(e.zoom.intensity))")
        editBits.append("background \(e.background.kind.rawValue)")
        lines.append("  Edit       " + editBits.joined(separator: ", "))
        if !e.chapters.isEmpty {
            lines.append("  Chapters")
            for c in e.chapters { lines.append("    \(Format.duration(c.time).padding(toLength: 8, withPad: " ", startingAt: 0)) \(c.title)") }
        }
        if hasCaptions { lines.append("  Captions   captions.vtt") }
        if let s = m.share { lines.append("  Link       \(s.url)\(s.polished ? " (polished)" : "")") }
        if !exports.isEmpty { lines.append("  Exports    " + exports.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")) }
        return Report(json: json, text: lines.joined(separator: "\n"))
    }

    static func list(_ locator: ProjectLocator, limit: Int?) -> Report {
        var bundles = locator.library.list()
        if let limit, limit >= 0 { bundles = Array(bundles.prefix(limit)) }
        let items = bundles.map(brief)
        guard !items.isEmpty else {
            return Report(json: ["library": .string(locator.library.root.path), "projects": []],
                          text: "No projects in \(Format.path(locator.library.root)).")
        }
        var lines: [String] = []
        for item in items {
            let name = item["name"]?.stringValue ?? "?"
            let dur = item["duration"]?.doubleValue.map(Format.duration) ?? "?"
            var line = "\(dur.padding(toLength: 8, withPad: " ", startingAt: 0)) \(name)"
            if let title = item["title"]?.stringValue, title != name { line += "  — \(title)" }
            if let status = item["status"]?.stringValue, status == "recording" { line += "  [needs recovery]" }
            if let url = item["shareURL"]?.stringValue { line += "  \(url)" }
            lines.append(line)
        }
        return Report(json: ["library": .string(locator.library.root.path), "projects": .array(items)], text: lines.joined(separator: "\n"))
    }
}
