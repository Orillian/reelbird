import Foundation
import ReelbirdAI
import ReelbirdCore

/// Clean Up for the CLI and MCP: `reelbird cleanup`, MCP `clean_up`.
extension Operations {
    /// Runs the Clean Up pass and applies what it is confident about (`dryRun`: only reports). `undo` takes
    /// everything Clean Up added back out. Uses `transcript.json` when there is one; without it, pauses come from
    /// the audio level and there are no ums or retakes.
    func cleanUp(_ project: String, dryRun: Bool, undo: Bool) async throws -> Report {
        let bundle = try locator.resolve(project)
        let manifest = try bundle.readManifest()
        if undo {
            let (count, edit) = try bundle.updateEdit { e -> (Int, EditDocument) in
                let n = e.cleanUp.applied.count
                CleanUp.undoAll(&e)
                return (n, e)
            }
            let length = EditTimeline(manifest: manifest, edit: edit).duration
            return Report(json: ["undone": .int(count), "outputDuration": JSONValue(length)],
                          text: count == 0 ? "Nothing to undo: Clean Up hasn't changed this project."
                              : "Took out Clean Up's \(count) edit\(count == 1 ? "" : "s"); length \(Format.duration(length)).")
        }
        let transcript = (try? Data(contentsOf: Self.transcriptURL(bundle))).flatMap { try? JSONCoding.decoder.decode(Transcript.self, from: $0) }
        let inputs: CleanUpInputs
        do { inputs = try await CleanUpAnalyzer.analyze(bundle: bundle, manifest: manifest, transcript: transcript) } catch {
            throw CLIError(error.localizedDescription)
        }
        let before = EditTimeline(manifest: manifest, edit: try bundle.readEdit()).duration
        let report: CleanUpReport
        let edit: EditDocument
        if dryRun {
            edit = try bundle.readEdit()
            report = CleanUp.plan(inputs, edit: edit)
        } else {
            (report, edit) = try bundle.updateEdit { e -> (CleanUpReport, EditDocument) in
                let r = CleanUp.plan(inputs, edit: e)
                CleanUp.apply(r, to: &e)
                return (r, e)
            }
        }
        let after = dryRun ? before - report.savedSeconds : EditTimeline(manifest: manifest, edit: edit).duration
        var text = "Clean Up: " + CleanUp.summary(applied: report.applied, suggestions: report.suggestions.count)
        if report.isEmpty {
            text = "Nothing to clean up."
        } else {
            text += dryRun ? " (dry run; nothing saved)." : " (saved to edit.json; length \(Format.duration(after)))."
            for item in report.applied { text += "\n  \(Self.cleanUpLine(item))" }
            if !report.suggestions.isEmpty {
                text += "\nSuggestions (not applied):"
                for item in report.suggestions { text += "\n  \(Self.cleanUpLine(item))" }
            }
        }
        if transcript == nil {
            text += "\nNo transcript, so no ums or retakes: run `reelbird captions` first."
        }
        let json: JSONValue = [
            "applied": .array(report.applied.map { Self.cleanUpJSON($0, applied: true) }),
            "suggestions": .array(report.suggestions.map { Self.cleanUpJSON($0, applied: false) }),
            "summary": .string(CleanUp.summary(applied: report.applied, suggestions: report.suggestions.count)),
            "savedSeconds": JSONValue(report.savedSeconds), "saved": .bool(!dryRun && !report.isEmpty),
            "transcript": .bool(transcript != nil),
            "outputDurationBefore": JSONValue(before), "outputDuration": JSONValue(after),
        ]
        return Report(json: json, text: text)
    }

    static func cleanUpLine(_ item: CleanUpItem) -> String {
        let r = item.editRange
        return "\(Format.duration(r.start)) – \(Format.duration(r.end))  \(item.kind.label.padding(toLength: 10, withPad: " ", startingAt: 0)) \(item.reason)"
    }

    static func cleanUpJSON(_ item: CleanUpItem, applied: Bool) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(item.id), "kind": .string(item.kind.rawValue), "applied": .bool(applied),
            "start": JSONValue(item.range.start), "end": JSONValue(item.range.end),
            "reason": .string(item.reason), "confidence": JSONValue(item.confidence), "savedSeconds": JSONValue(item.savedSeconds),
        ]
        if let cut = item.cut { o["cut"] = ["start": JSONValue(cut.start), "end": JSONValue(cut.end)] }
        if let rate = item.rate { o["rate"] = JSONValue(rate) }
        return .object(o)
    }
}
