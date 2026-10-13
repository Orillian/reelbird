import Foundation
import ReelbirdAI
import ReelbirdCore

/// Speed segments: adding, editing and removing them, and the "speed up typing" suggestions.
extension EditorModel {
    var selectedSpeed: SpeedSegment? {
        guard case .speed(let id) = selection else { return nil }
        return edit.speed.segments.first { $0.id == id }
    }

    /// Output seconds the speed segments save (negative when they slow the video down overall).
    var speedSavedSeconds: Double {
        let tl = timeline
        let plain = EditTimeline(duration: manifest.duration, trim: edit.trim, cuts: edit.cuts)
        return plain.duration - tl.duration
    }

    /// The R key and the Speed button: the next preset for a selected speed segment; otherwise 2× for the selected
    /// part (between split points) or for 3 seconds from the playhead.
    func speedKey() {
        if let s = selectedSpeed {
            let presets = SpeedSegment.presets
            let next = presets.first { $0 > s.rate + 1e-9 } ?? presets[0]
            setSpeedRate(next)
        } else {
            applySpeed(2)
        }
    }

    /// Sets `rate` on the selected speed segment, the selected part, or 3 seconds from the playhead (up to the next
    /// split point, cut or speed segment).
    func applySpeed(_ rate: Double) {
        if selectedSpeed != nil { setSpeedRate(rate); return }
        let range: TimeRange
        if case .segment(let r) = selection {
            range = r
        } else {
            let start = min(playhead, max(0, duration - 0.5))
            var end = min(duration, edit.trim?.end ?? duration, start + 3)
            if let split = splits.first(where: { $0 > start + 0.05 }) { end = min(end, split) }
            if let cut = edit.cuts.first(where: { $0.start > start + 0.05 }) { end = min(end, cut.start) }
            if let next = edit.speed.segments.first(where: { $0.range.start > start + 0.05 }) { end = min(end, next.range.start) }
            range = TimeRange(start: start, end: end)
        }
        guard range.duration >= SpeedSegment.minDuration else { return }
        let id = ShortID.make(length: 6)
        change("Set Speed") { $0.speed.set(range, rate: rate, source: .user, id: id) }
        if edit.speed.segments.contains(where: { $0.id == id }) { selection = .speed(id) }
    }

    /// Changes the selected speed segment's rate (it stays selected).
    func setSpeedRate(_ rate: Double) {
        guard let s = selectedSpeed else { return }
        updateSpeed(s.id, actionName: "Change Speed") { $0.rate = SpeedSegment.clampRate(rate) }
    }

    /// Edits one segment (drag, resize, rate). It never grows over its neighbours, and stays at least 0.3 s long.
    func updateSpeed(_ id: String, actionName: String = "Edit Speed", coalesce: String? = nil, _ body: (inout SpeedSegment) -> Void) {
        change(actionName, coalesce: coalesce.map { $0 + id }) { e in
            var all = e.speed.segments
            guard let i = all.firstIndex(where: { $0.id == id }) else { return }
            let lower = i > 0 ? all[i - 1].range.end : 0
            let upper = i + 1 < all.count ? all[i + 1].range.start : duration
            var s = all[i]
            body(&s)
            var r = s.range
            r.start = max(lower, r.start)
            r.end = min(upper, r.end)
            if r.duration < 0.3 { r = r.start + 0.3 <= upper ? TimeRange(start: r.start, end: r.start + 0.3) : TimeRange(start: max(lower, upper - 0.3), end: upper) }
            s.range = r
            s.rate = SpeedSegment.clampRate(s.rate)
            all[i] = s
            e.speed.segments = SpeedSettings.normalized(all)
        }
    }

    func deleteSpeed(_ id: String) {
        change("Remove Speed") { $0.speed.segments.removeAll { $0.id == id } }
        if selection == .speed(id) { selection = nil }
    }

    func setKeepFastAudio(_ keep: Bool) {
        change(keep ? "Keep Sound When Fast" : "Mute Sound When Fast") { $0.speed.keepFastAudio = keep }
    }

    // MARK: Suggestions

    /// Looks for the voice's silences once (off the main thread), for idle-stretch suggestions.
    func loadSpeedSilences() {
        guard speedSilences == nil, speedSilenceTask == nil else { return }
        guard let mic = bundle.mediaURL(for: .microphone, in: manifest) else { speedSilences = .some(nil); return }
        let ai = services.ai
        let offset = manifest.track(.microphone)?.startTime ?? 0
        speedSilenceTask = Task {
            let silences = try? await ai.silentRanges(audio: mic)
            // Unreadable audio: no idle suggestions (an empty list means "never silent").
            speedSilences = .some(silences.map { $0.map { TimeRange(start: $0.start + offset, end: $0.end + offset) } } ?? [])
        }
    }

    /// Typing and idle stretches that could play faster, skipping parts that are cut or already have a speed.
    /// Empty until the voice's silences are known.
    var speedSuggestions: [SpeedSuggestion] {
        if let s = speedSuggestionsForSnapshot { return s.filter { x in !edit.speed.segments.contains { $0.range.overlaps(x.range) } } }
        guard let silences = speedSilences else { return [] }
        var h = Hasher()
        h.combine(edit.trim); h.combine(edit.cuts); h.combine(edit.speed); h.combine(silences)
        let key = h.finalize()
        if let c = speedSuggestionCache, c.key == key { return c.value }
        let value = SpeedSuggester.suggest(events: events, silences: silences, duration: duration, edit: edit)
        speedSuggestionCache = (key, value)
        return value
    }

    /// "Speed up 6 typing stretches, saves 0:24" (short enough for the edit tools row).
    static func speedSuggestionTitle(_ s: [SpeedSuggestion]) -> String {
        let sum = SpeedSuggester.summary(s)
        let n = sum.typing + sum.idle
        let what = sum.idle == 0 ? "typing " : sum.typing == 0 ? "idle " : ""
        return "Speed up \(n) \(what)stretch\(n == 1 ? "" : "es"), saves \(TimeFormat.clock(sum.saved))"
    }

    /// "2 typing stretches and 1 idle stretch."
    static func speedSuggestionDetail(_ s: [SpeedSuggestion]) -> String {
        let sum = SpeedSuggester.summary(s)
        func count(_ n: Int, _ what: String) -> String { "\(n) \(what) stretch\(n == 1 ? "" : "es")" }
        var parts: [String] = []
        if sum.typing > 0 { parts.append(count(sum.typing, "typing")) }
        if sum.idle > 0 { parts.append(count(sum.idle, "idle")) }
        return parts.joined(separator: " and ").prefix(1).uppercased() + parts.joined(separator: " and ").dropFirst() + "."
    }

    /// Adds every suggestion as its own speed segment (each can be removed or changed). One undo step.
    func applySpeedSuggestions() {
        if speedSilences == nil {
            loadSpeedSilences()
            let task = speedSilenceTask
            Task { await task?.value; if speedSilences != nil { applySpeedSuggestions() } }
            return
        }
        let s = speedSuggestions
        guard !s.isEmpty else {
            Toast.show(title: "Nothing to speed up", detail: "No long typing or idle stretches were found.", symbol: "keyboard")
            return
        }
        change("Speed Up Typing") { e in
            for x in s { e.speed.set(x.range, rate: x.rate, source: x.segment.source) }
        }
        let saved = SpeedSuggester.summary(s).saved
        Toast.show(title: "Sped up \(s.count) stretch\(s.count == 1 ? "" : "es")",
                   detail: "The video is \(TimeFormat.clock(saved)) shorter. Select one and press Delete to undo it.", symbol: "forward.fill")
    }

    /// Applies one suggestion (a click on its outline in the speed lane).
    func applySpeedSuggestion(_ s: SpeedSuggestion) {
        let seg = s.segment
        change("Speed Up") { $0.speed.set(seg.range, rate: seg.rate, source: seg.source, id: seg.id) }
        selection = .speed(seg.id)
    }

    func setSpeedSuggestionsForSnapshot(_ s: [SpeedSuggestion]) { speedSuggestionsForSnapshot = s; speedSilences = .some(nil) }
}
