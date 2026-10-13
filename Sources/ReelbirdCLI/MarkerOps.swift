import Foundation
import ReelbirdCore

// `reelbird markers` and the MCP marker tools (`list_markers`, `add_marker`).
extension Operations {
    /// One marker as JSON: its ID, recording time, time in the edited video (`null` when cut) and title.
    static func markerJSON(_ m: Marker, timeline: EditTimeline) -> JSONValue {
        ["id": .string(m.id), "t": JSONValue(m.t), "outputTime": JSONValue(timeline.outputTime(forSource: m.t)), "title": .string(m.title)]
    }

    /// Lists the project's markers; `asChapters` also replaces the chapters with them (saved to edit.json).
    func markers(_ project: String, asChapters: Bool) throws -> Report {
        let bundle = try locator.resolve(project)
        let manifest: ProjectManifest
        do { manifest = try bundle.readManifest() } catch {
            throw CLIError("Can't read project.json: \(error.localizedDescription)", code: .dataError)
        }
        var edit: EditDocument
        do { edit = try bundle.readEdit() } catch {
            throw CLIError("Can't read edit.json: \(error.localizedDescription)", code: .dataError)
        }
        let markers = Markers.resolve(edit: edit, events: (try? bundle.readEvents()) ?? [])
        let timeline = EditTimeline(manifest: manifest, edit: edit)
        var json: [String: JSONValue] = ["markers": .array(markers.map { Self.markerJSON($0, timeline: timeline) })]
        var lines: [String] = []
        if markers.isEmpty {
            lines.append("No markers. Press the marker shortcut (default ⌥⇧M) while recording, or use MCP add_marker.")
        }
        for m in markers {
            let out = timeline.outputTime(forSource: m.t).map { Format.duration($0) } ?? "cut"
            lines.append("\(Format.duration(m.t).padding(toLength: 8, withPad: " ", startingAt: 0)) \(m.title)  (\(out) in the video)")
        }
        if asChapters {
            guard !markers.isEmpty else { throw CLIError("This project has no markers to turn into chapters.", code: .dataError) }
            edit.chapters = Markers.chapters(from: markers, timeline: timeline)
            do { try bundle.writeEdit(edit) } catch {
                throw CLIError("Couldn't save edit.json: \(error.localizedDescription)", code: .failure)
            }
            json["chapters"] = .array(edit.chapters.map { ["time": JSONValue($0.time), "title": .string($0.title)] })
            lines.append("Saved \(edit.chapters.count) chapter\(edit.chapters.count == 1 ? "" : "s") to \(Format.path(bundle.editURL)).")
        }
        return Report(json: .object(json), text: lines.joined(separator: "\n"))
    }

    /// The result of MCP `add_marker`.
    static func markerAdded(_ m: RecordedMarker, session: String) -> Report {
        Report(json: ["session_id": .string(session), "number": .int(m.number), "t": JSONValue(m.t), "title": .string(m.label)],
               text: "\(m.label) at \(Format.duration(m.t)) (recording \(session)).")
    }
}
