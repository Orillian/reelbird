import Foundation
import ReelbirdAI
import ReelbirdCore
import ReelbirdGuide

// `reelbird steps`, `reelbird guide` and the MCP step tools (`get_steps`, `describe_take`, `export_guide`, `edit_step`).
extension Operations {
    /// Changes to steps from `reelbird steps` or MCP `edit_step`.
    struct StepChanges: Sendable {
        var texts: [(id: String, text: String)] = []
        var hide: [String] = []
        var show: [String] = []
        var showTypedText: Bool?
        var isEmpty: Bool { texts.isEmpty && hide.isEmpty && show.isEmpty && showTypedText == nil }
    }

    /// One step as JSON.
    static func stepJSON(_ s: GuideStep, number: Int, timeline: EditTimeline) -> JSONValue {
        var o: [String: JSONValue] = [
            "n": .int(number), "id": .string(s.id), "kind": .string(s.kind.rawValue), "t": JSONValue(s.t),
            "outputTime": JSONValue(timeline.outputTime(forSource: s.t)), "text": .string(s.text),
        ]
        if let p = s.point { o["point"] = ["x": JSONValue(p.x), "y": JSONValue(p.y)] }
        if let l = s.label { o["label"] = .string(l) }
        if let k = s.keys { o["keys"] = .string(k) }
        if s.count > 1 { o["count"] = .int(s.count) }
        if let n = s.narration { o["narration"] = .string(n) }
        if let sec = s.section { o["section"] = .string(sec) }
        return .object(o)
    }

    /// Lists the project's guide steps, after applying `changes` to `edit.json → guide`.
    func steps(_ project: String, changes: StepChanges = StepChanges(), refresh: Bool = false, useModel: Bool = true,
               progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Report {
        let bundle = try locator.resolve(project)
        let manifest: ProjectManifest
        do { manifest = try bundle.readManifest() } catch {
            throw CLIError("Can't read project.json: \(error.localizedDescription)", code: .dataError)
        }
        var edit: EditDocument
        do { edit = try bundle.readEdit() } catch {
            throw CLIError("Can't read edit.json: \(error.localizedDescription)", code: .dataError)
        }
        if !changes.isEmpty {
            do {
                edit = try bundle.updateEdit { e in
                    for (id, text) in changes.texts { e.guide.setEdit(id: id, text: .some(text)) }
                    for id in changes.hide { e.guide.setEdit(id: id, hidden: .some(true)) }
                    for id in changes.show { e.guide.setEdit(id: id, hidden: .some(false)) }
                    if let typed = changes.showTypedText { e.guide.showTypedText = typed }
                    return e
                }
            } catch {
                throw CLIError("Couldn't save edit.json: \(error.localizedDescription)", code: .failure)
            }
        }
        let steps: [GuideStep]
        do {
            steps = try await StepScanner.steps(bundle: bundle, edit: edit, options: StepScanner.Options(useModel: useModel, refresh: refresh),
                                                progress: progress)
        } catch {
            throw CLIError("Couldn't read the steps: \(error.localizedDescription)", code: .dataError)
        }
        let timeline = EditTimeline(manifest: manifest, edit: edit)
        let hidden = edit.guide.edits.filter { $0.hidden == true }.map(\.id)
        var lines: [String] = []
        if steps.isEmpty {
            lines.append("No steps: there are no clicks, typing or shortcuts in the kept part of this recording. Typing and shortcuts need keystroke recording (record with --keystrokes).")
        }
        for (i, s) in steps.enumerated() {
            if let section = s.section { lines.append("\n\(section)") }
            let out = timeline.outputTime(forSource: s.t).map { Format.duration($0) } ?? "cut"
            lines.append("\(String(i + 1).padding(toLength: 4, withPad: " ", startingAt: 0))\(out.padding(toLength: 8, withPad: " ", startingAt: 0))\(s.text)  [\(s.id)]")
        }
        if !hidden.isEmpty { lines.append("Hidden: \(hidden.joined(separator: ", ")) (show again with --show ID)") }
        let json: JSONValue = [
            "steps": .array(steps.enumerated().map { Self.stepJSON($1, number: $0 + 1, timeline: timeline) }),
            "hidden": .array(hidden.map(JSONValue.string)),
            "share": .bool(edit.guide.share), "copyText": .bool(edit.guide.copyText), "showTypedText": .bool(edit.guide.showTypedText),
        ]
        return Report(json: json, text: lines.joined(separator: "\n"))
    }

    /// Writes the guide as Markdown, an HTML page (Guide and Click-through) or a Claude skill.
    func guide(_ project: String, format: GuideExport.Format, out: URL?, overwrite: Bool, refresh: Bool = false, useModel: Bool = true,
               progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Report {
        let bundle = try locator.resolve(project)
        let manifest: ProjectManifest
        let edit: EditDocument
        do { manifest = try bundle.readManifest(); edit = try bundle.readEdit() } catch {
            throw CLIError("Can't read the project: \(error.localizedDescription)", code: .dataError)
        }
        let built: BuiltGuide
        do {
            built = try await GuideBuilder.build(bundle: bundle, edit: edit, options: StepScanner.Options(useModel: useModel, refresh: refresh),
                                                 progress: { progress($0 * 0.95) })
        } catch {
            throw CLIError("Couldn't make the guide: \(error.localizedDescription)", code: .dataError)
        }
        let suffix = format == .markdown ? "Markdown" : format == .html ? "HTML" : "Skill"
        let folder = out ?? bundle.exportsURL.appendingPathComponent("Guide (\(suffix))", isDirectory: true)
        let title = (edit.title?.isEmpty == false ? edit.title : nil) ?? manifest.title
        let main: URL
        do {
            main = try GuideExport.write(built, title: title, createdAt: manifest.createdAt, format: format, to: folder, overwrite: overwrite)
        } catch let e as GuideExport.ExportError {
            throw CLIError(e.errorDescription ?? "Couldn't write the guide.", code: e == .noSteps ? .dataError : .usage,
                           hint: e == .noSteps ? nil : "Pass --force to replace it.")
        } catch {
            throw CLIError("Couldn't write the guide: \(error.localizedDescription)", code: .failure)
        }
        progress(1)
        let n = built.steps.count
        return Report(json: ["path": .string(main.path), "folder": .string(folder.path), "format": .string(format.rawValue), "steps": .int(n)],
                      text: "Wrote \(n) step\(n == 1 ? "" : "s") to \(Format.path(main)).")
    }

    /// What an agent needs to understand a take: its steps, what was said, markers and length.
    func describeTake(_ project: String) async throws -> Report {
        let bundle = try locator.resolve(project)
        let manifest: ProjectManifest
        let edit: EditDocument
        do { manifest = try bundle.readManifest(); edit = try bundle.readEdit() } catch {
            throw CLIError("Can't read the project: \(error.localizedDescription)", code: .dataError)
        }
        let timeline = EditTimeline(manifest: manifest, edit: edit)
        let steps = (try? await StepScanner.steps(bundle: bundle, edit: edit)) ?? []
        let words = StepScanner.transcriptWords(bundle)
        let transcript = words.map(\.text).joined(separator: " ")
        let markers = Markers.resolve(edit: edit, events: (try? bundle.readEvents()) ?? [])
        let title = (edit.title?.isEmpty == false ? edit.title : nil) ?? manifest.title
        var json: [String: JSONValue] = [
            "title": .string(title), "path": .string(bundle.url.path),
            "duration": JSONValue(manifest.duration), "editedDuration": JSONValue(timeline.duration),
            "steps": .array(steps.enumerated().map { Self.stepJSON($1, number: $0 + 1, timeline: timeline) }),
            "markers": .array(markers.map { Self.markerJSON($0, timeline: timeline) }),
            "transcript": .string(String(transcript.prefix(20_000))),
        ]
        if let share = manifest.share { json["link"] = .string(share.url) }
        var lines = ["\(title) (\(Format.duration(timeline.duration)))"]
        for (i, s) in steps.enumerated() { lines.append("\(i + 1). \(s.text)" + (s.narration.map { " (said: \"\($0)\")" } ?? "")) }
        if steps.isEmpty { lines.append("No steps found.") }
        if !transcript.isEmpty { lines.append("\nTranscript: \(transcript.prefix(2_000))") }
        return Report(json: .object(json), text: lines.joined(separator: "\n"))
    }
}
