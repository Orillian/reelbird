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
            .filter { !$0.lastPathComponent.hasPrefix(".") && ["mp4", "mov", "m4v", "gif"].contains($0.pathExtension.lowercased()) }
            .map(\.path).sorted()

        let analysis = bundle.readAnalysis()
        let voice: JSONValue = analysis?.microphone.map { mic in
            [
                "integratedLUFS": JSONValue(mic.integratedLUFS), "peakDBFS": JSONValue(mic.peakDBFS),
                "autoLevelGainDB": JSONValue(e.audio.autoLevelGainDB(analysis)), "file": .string(mic.file),
            ]
        } ?? .null
        let stemStatus = bundle.voiceStemStatus(manifest: m, settings: e.audio)
        let stem = bundle.usableVoiceStem(manifest: m)
        let stemJSON: JSONValue = [
            "status": .string(stemStatus.rawValue), "file": JSONValue(stem?.file), "engine": JSONValue(stem?.engine),
            "strength": JSONValue(stem?.strength.rawValue), "mix": JSONValue(stem?.mix), "renderSeconds": JSONValue(stem?.renderSeconds),
        ]
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
                "camera": [
                    "visible": .bool(e.camera.visible), "shape": .string(e.camera.shape.rawValue), "size": JSONValue(e.camera.size),
                    "x": JSONValue(e.camera.position.x), "y": JSONValue(e.camera.position.y),
                    "corner": JSONValue(cameraCorner(e.camera)?.rawValue),
                    "moves": .array(e.camera.moves.map { ["t": JSONValue($0.t), "x": JSONValue($0.x), "y": JSONValue($0.y)] }),
                ],
                "crop": e.crop.map { ["x": JSONValue($0.x), "y": JSONValue($0.y), "width": JSONValue($0.width), "height": JSONValue($0.height)] } ?? .null,
                "captionsFile": JSONValue(e.captions.file),
                "annotations": .int(e.annotations.count),
                "audio": [
                    "autoLevel": .bool(e.audio.autoLevel), "microphoneGainDB": JSONValue(e.audio.microphoneGainDB),
                    "microphoneMuted": .bool(e.audio.microphoneMuted), "systemGainDB": JSONValue(e.audio.systemGainDB),
                    "systemMuted": .bool(e.audio.systemMuted), "enhance": .bool(e.audio.enhance),
                    "enhanceStrength": .string(e.audio.enhanceStrength.rawValue), "enhanceMix": JSONValue(e.audio.enhanceMix),
                    "duckSystemAudio": .bool(e.audio.duckSystemAudio),
                ],
            ],
            "voiceLoudness": voice,
            "voiceStem": stemJSON,
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
        if m.track(.camera) != nil { lines.append("  Camera     \(describeCamera(e.camera))") }
        if let mic = analysis?.microphone {
            var v = mic.integratedLUFS.map { String(format: "%.1f LUFS", $0) } ?? "silent"
            if let p = mic.peakDBFS { v += String(format: ", peak %.1f dBFS", p) }
            if let g = e.audio.autoLevelGainDB(analysis) { v += String(format: ", auto level %+.1f dB", g) } else if !e.audio.autoLevel { v += ", auto level off" }
            if e.audio.microphoneGainDB != 0 { v += String(format: ", boost %+.1f dB", e.audio.microphoneGainDB) }
            lines.append("  Voice      \(v)")
        }
        if m.track(.microphone) != nil {
            let detail: String
            switch stemStatus {
            case .off: detail = "off"
            case .missing: detail = "\(e.audio.enhanceStrength.rawValue), not rendered yet (run `reelbird enhance`)"
            case .stale: detail = "\(e.audio.enhanceStrength.rawValue), out of date (rendered \(stem?.strength.rawValue ?? "?"), mix \(stem.map { String(format: "%.2f", $0.mix) } ?? "?"))"
            case .ready: detail = "\(e.audio.enhanceStrength.rawValue), mix \(Int(((stem?.mix ?? 1) * 100).rounded()))%, ready (\(stem?.engine ?? "?"))"
            }
            lines.append("  Enhance    \(detail)")
        }
        if !e.chapters.isEmpty {
            lines.append("  Chapters")
            for c in e.chapters { lines.append("    \(Format.duration(c.time).padding(toLength: 8, withPad: " ", startingAt: 0)) \(c.title)") }
        }
        if hasCaptions { lines.append("  Captions   captions.vtt") }
        if let s = m.share { lines.append("  Link       \(s.url)\(s.polished ? " (polished)" : "")") }
        if !exports.isEmpty { lines.append("  Exports    " + exports.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")) }
        return Report(json: json, text: lines.joined(separator: "\n"))
    }

    /// The preset corner the bubble sits in for the whole video, if any.
    static func cameraCorner(_ c: CameraLayout) -> CameraLayout.Corner? {
        guard c.moves.isEmpty else { return nil }
        return CameraLayout.Corner.allCases.first { $0.position == c.position }
    }

    /// "circle, bottom right" or "portrait, x 0.42 y 1, 2 moves (0:12, 0:30)".
    static func describeCamera(_ c: CameraLayout) -> String {
        guard c.visible else { return "hidden" }
        func place(_ p: NormPoint) -> String {
            if let corner = CameraLayout.Corner.allCases.first(where: { $0.position == p }) {
                return corner.rawValue.replacingOccurrences(of: "([A-Z])", with: " $1", options: .regularExpression).lowercased()
            }
            return "x \(Format.seconds(p.x)) y \(Format.seconds(p.y))"
        }
        var s = "\(c.shape.rawValue) \(Int((c.size * 100).rounded()))%, \(place(c.position))"
        if !c.moves.isEmpty {
            s += ", \(c.moves.count) move\(c.moves.count == 1 ? "" : "s") (" + c.moves.map { Format.duration($0.t) }.joined(separator: ", ") + ")"
        }
        return s
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
