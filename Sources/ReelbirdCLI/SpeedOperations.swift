import Foundation
import ReelbirdAI
import ReelbirdCore

/// Speed segments for the CLI and MCP: `edit --speed`, `speedup`, and what `info` shows.
extension Operations {
    /// Parses "START-END@RATE" (rate "2", "2x" or "2×"; 1 removes any speed there).
    static func speedChange(_ s: String, duration: Double?) throws -> (range: TimeRange, rate: Double) {
        guard let at = s.lastIndex(of: "@") else {
            throw CLIError.usage("Invalid speed '\(s)'. Use START-END@RATE, e.g. 0:12-0:20@2 or 30-end@1.5.")
        }
        let range = try TimeParsing.range(String(s[..<at]), duration: duration)
        let text = String(s[s.index(after: at)...])
        guard let rate = SpeedSegment.parseRate(text) else {
            throw CLIError.usage("Invalid speed '\(text)' in '\(s)'. Use a rate like 0.5, 1.5, 2 or 4.")
        }
        guard (SpeedSegment.minRate...SpeedSegment.maxRate).contains(rate) else {
            throw CLIError.usage("Speed must be between \(SpeedSegment.label(SpeedSegment.minRate)) and \(SpeedSegment.label(SpeedSegment.maxRate)) (got \(text)).")
        }
        guard range.duration >= SpeedSegment.minDuration else { throw CLIError.usage("'\(s)' is too short to change its speed.") }
        return (range, rate)
    }

    /// Finds typing and idle stretches to speed up (key presses from the event log, silences in the voice);
    /// with `apply`, adds each as a speed segment.
    func speedup(_ project: String, apply: Bool, typingRate: Double?, idleRate: Double?) async throws -> Report {
        let bundle = try locator.resolve(project)
        let manifest = try bundle.readManifest()
        var edit = try bundle.readEdit()
        let events = (try? bundle.readEvents()) ?? []
        var silences: [TimeRange]?
        if let mic = bundle.mediaURL(for: .microphone, in: manifest), FileManager.default.fileExists(atPath: mic.path) {
            let offset = manifest.track(.microphone)?.startTime ?? 0
            do {
                silences = try await SilenceDetector.silentRanges(audio: mic).map { TimeRange(start: $0.start + offset, end: $0.end + offset) }
            } catch { throw CLIError(error.localizedDescription) }
        }
        var options = SpeedSuggester.Options()
        if let typingRate { options.typingRate = typingRate }
        if let idleRate { options.idleRate = idleRate }
        let found = SpeedSuggester.suggest(events: events, silences: silences, duration: manifest.duration, edit: edit, options: options)
        let before = EditTimeline(manifest: manifest, edit: edit).duration
        if apply, !found.isEmpty {
            edit = try bundle.updateEdit { edit in
                for s in found { edit.speed.set(s.range, rate: s.rate, source: s.segment.source) }
                return edit
            }
        }
        let after = EditTimeline(manifest: manifest, edit: edit).duration
        let sum = SpeedSuggester.summary(found)
        let hasKeys = events.contains { $0.type == .key }
        var text: String
        if found.isEmpty {
            text = hasKeys ? "Nothing to speed up: no typing over 3 s or idle stretches over 4 s."
                : "Nothing to speed up. This recording has no key presses (record with --keystrokes) and no long idle stretches."
        } else {
            var parts: [String] = []
            if sum.typing > 0 { parts.append("\(sum.typing) typing stretch\(sum.typing == 1 ? "" : "es")") }
            if sum.idle > 0 { parts.append("\(sum.idle) idle stretch\(sum.idle == 1 ? "" : "es")") }
            text = "Speed up \(parts.joined(separator: " and ")), saves \(Format.duration(sum.saved))"
            text += apply ? " (added to edit.json; length \(Format.duration(after)))." : ". Add them with --apply."
            for s in found {
                text += "\n  \(Format.duration(s.range.start)) – \(Format.duration(s.range.end))  \(s.kind.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)) \(SpeedSegment.label(s.rate))"
            }
        }
        let json: JSONValue = [
            "suggestions": .array(found.map { s in
                ["kind": .string(s.kind.rawValue), "start": JSONValue(s.range.start), "end": JSONValue(s.range.end),
                 "rate": JSONValue(s.rate), "savedSeconds": JSONValue(s.savedSeconds)]
            }),
            "savedSeconds": JSONValue(sum.saved), "applied": .bool(apply && !found.isEmpty),
            "outputDurationBefore": JSONValue(before), "outputDuration": JSONValue(after),
            "speed": ProjectSummary.speedJSON(edit.speed),
        ]
        return Report(json: json, text: text)
    }
}

extension ProjectSummary {
    static func speedJSON(_ s: SpeedSettings) -> JSONValue {
        [
            "keepFastAudio": .bool(s.keepFastAudio),
            "segments": .array(s.segments.map { seg in
                ["id": .string(seg.id), "start": JSONValue(seg.range.start), "end": JSONValue(seg.range.end),
                 "rate": JSONValue(seg.rate), "source": .string(seg.source.rawValue), "audible": .bool(s.isAudible(rate: seg.rate))]
            }),
        ]
    }

    /// "3 parts: 2× 0:14–0:18, 4× typing 0:22–0:26 (muted), …".
    static func describeSpeed(_ s: SpeedSettings) -> String? {
        guard !s.segments.isEmpty else { return nil }
        let items = s.segments.map { seg -> String in
            var t = SpeedSegment.label(seg.rate)
            if seg.source != .user { t += " \(seg.source.rawValue)" }
            t += " \(Format.duration(seg.range.start))–\(Format.duration(seg.range.end))"
            if !s.isAudible(rate: seg.rate) { t += " (muted)" }
            return t
        }
        return "\(items.count) part\(items.count == 1 ? "" : "s"): " + items.joined(separator: ", ")
    }
}
