import Foundation

/// One step of a take's guide: a click, a run of typing or a shortcut, with what was clicked (read from the
/// screen), what was said around it and the instruction shown. Times are on the recording timeline and
/// positions full-screen normalized, like events.
public struct GuideStep: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case click, doubleClick, rightClick, drag, type, shortcut, key
    }

    /// Stable across re-scans: `c<ms>` for pointer steps, `t<ms>` for typing, `k<ms>` for keys, from the time of
    /// the event that makes the step.
    public var id: String
    public var kind: Kind
    /// When the action happens (mouse down, first key).
    public var t: Double
    /// The frame shown for the step: just before the action.
    public var imageTime: Double
    /// Where the pointer acted (typing: the field clicked before it). Absent for keys.
    public var point: NormPoint?
    /// Text under or next to the click, read from the screen.
    public var label: String?
    /// Bounds of `label`.
    public var labelRect: NormRect?
    /// What was typed (typing steps). Shown only when `GuideSettings.showTypedText` allows it.
    public var typed: String?
    /// The key or shortcut: "⌘S", "Return". For typing, the key that ended it ("Return", "Tab").
    public var keys: String?
    /// Repeats merged into this step (clicks on the same spot, the same shortcut in a row).
    public var count: Int
    /// Words spoken around the step.
    public var narration: String?
    /// The instruction written by the on-device model, when it ran.
    public var modelText: String?
    /// The instruction shown: an edit, else `modelText`, else the template (see `GuideSteps.resolve`).
    public var text: String
    /// The marker that opens a section at this step.
    public var section: String?

    public init(id: String, kind: Kind, t: Double, imageTime: Double? = nil, point: NormPoint? = nil, label: String? = nil,
                labelRect: NormRect? = nil, typed: String? = nil, keys: String? = nil, count: Int = 1,
                narration: String? = nil, modelText: String? = nil, text: String = "", section: String? = nil) {
        self.id = id; self.kind = kind; self.t = t; self.imageTime = imageTime ?? t; self.point = point; self.label = label
        self.labelRect = labelRect; self.typed = typed; self.keys = keys; self.count = count; self.narration = narration
        self.modelText = modelText; self.text = text; self.section = section
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .click
        t = try c.decode(Double.self, forKey: .t)
        imageTime = try c.decodeIfPresent(Double.self, forKey: .imageTime) ?? t
        point = try c.decodeIfPresent(NormPoint.self, forKey: .point)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        labelRect = try c.decodeIfPresent(NormRect.self, forKey: .labelRect)
        typed = try c.decodeIfPresent(String.self, forKey: .typed)
        keys = try c.decodeIfPresent(String.self, forKey: .keys)
        count = max(1, try c.decodeIfPresent(Int.self, forKey: .count) ?? 1)
        narration = try c.decodeIfPresent(String.self, forKey: .narration)
        modelText = try c.decodeIfPresent(String.self, forKey: .modelText)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        section = try c.decodeIfPresent(String.self, forKey: .section)
    }

    /// Pointer steps: click, double-click, right-click, drag.
    public var isPointer: Bool { kind == .click || kind == .doubleClick || kind == .rightClick || kind == .drag }
}

/// `edit.json → guide`: what the share page gets, how typing reads, and the steps changed by hand.
public struct GuideSettings: Codable, Hashable, Sendable {
    /// Publish Guide and Click-through with the link.
    public var share = true
    /// Publish the text layer, so viewers can select text in the paused video.
    public var copyText = true
    /// Typing steps quote what was typed (never sensitive-looking text, nor text typed under a blur).
    public var showTypedText = false
    /// Steps changed by hand, by id.
    public var edits: [StepEdit] = []

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GuideSettings()
        share = (try? c.decodeIfPresent(Bool.self, forKey: .share)) ?? d.share
        copyText = (try? c.decodeIfPresent(Bool.self, forKey: .copyText)) ?? d.copyText
        showTypedText = (try? c.decodeIfPresent(Bool.self, forKey: .showTypedText)) ?? d.showTypedText
        // An edit this version can't read is skipped, not the whole list.
        edits = ((try? c.decodeIfPresent([Lenient<StepEdit>].self, forKey: .edits)) ?? nil)?.compactMap(\.value) ?? d.edits
    }

    public func edit(for id: String) -> StepEdit? { edits.first { $0.id == id } }

    /// Sets or clears the hand-written text and the hidden flag of a step. An edit with neither is removed.
    public mutating func setEdit(id: String, text: String?? = nil, hidden: Bool?? = nil) {
        var e = edit(for: id) ?? StepEdit(id: id)
        if let text { e.text = text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : String($0.prefix(500)) } }
        if let hidden { e.hidden = hidden == true ? true : nil }
        edits.removeAll { $0.id == id }
        if e.text != nil || e.hidden != nil { edits.append(e) }
    }
}

/// A step changed by hand: new text, or hidden from the guide.
public struct StepEdit: Codable, Hashable, Sendable {
    public var id: String
    public var text: String?
    public var hidden: Bool?
    public init(id: String, text: String? = nil, hidden: Bool? = nil) { self.id = id; self.text = text; self.hidden = hidden }
}

/// A word with its time on the recording timeline (from the transcript).
public struct TimedWord: Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

// MARK: - Extraction

/// Turns the event log into steps. Pure and deterministic; reads every event of the recording (cuts, trim and
/// crop apply later, in `GuideSteps.resolve`, so a cached scan survives edits).
public enum StepExtractor {
    /// Two downs closer than this (seconds and distance) are a double-click.
    static let doubleClickTime = 0.4
    /// A down this close to the previous click (and within `sameSpot`) repeats it.
    static let repeatTime = 1.0
    static let sameSpot = 0.015
    /// Pointer travel between down and up that makes a drag.
    static let dragDistance = 0.03
    /// Keys further apart end a run of typing.
    static let typingGap = 1.5
    /// Typing this soon after a click goes into that click's field.
    static let fieldWindow = 10.0
    /// The frame shown sits this far before the action.
    static let imageLead = 0.08
    public static let maxSteps = 300

    public static func extract(events: [InputEvent]) -> [GuideStep] {
        let sorted = events.enumerated().sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }.map(\.element)
        var steps: [GuideStep] = []
        var lastDown: (t: Double, point: NormPoint, button: Int)?
        var typing: Int?            // index of the step collecting the current run of typing
        var typingText = ""
        var lastKey = -Double.infinity
        var ids = Set<String>()

        func uniqueID(_ prefix: String, _ t: Double) -> String {
            var id = "\(prefix)\(Int((max(0, t) * 1000).rounded()))"
            while ids.contains(id) { id += "b" }
            ids.insert(id)
            return id
        }
        func closeTyping() {
            guard let i = typing else { return }
            let text = typingText
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && steps[i].keys == nil {
                // Nothing typed after all: a field clicked and left (or only deletions).
                if steps[i].point != nil { steps[i].kind = .click; steps[i].typed = nil } else { steps.remove(at: i) }
            } else {
                steps[i].typed = text
            }
            typing = nil
            typingText = ""
        }

        for (index, e) in sorted.enumerated() {
            switch e.type {
            case .down:
                guard let p = e.point, (0...1).contains(p.x), (0...1).contains(p.y) else { continue }
                closeTyping()
                let button = e.button ?? 0
                if let last = lastDown, let li = steps.indices.last, steps[li].isPointer, last.button == button,
                   distance(last.point, p) < sameSpot {
                    if e.t - last.t < doubleClickTime, steps[li].kind == .click, steps[li].count == 1 {
                        steps[li].kind = .doubleClick
                        lastDown = (e.t, p, button)
                        continue
                    }
                    if e.t - last.t < repeatTime {
                        steps[li].count += 1
                        lastDown = (e.t, p, button)
                        continue
                    }
                }
                var kind: GuideStep.Kind = button == 1 ? .rightClick : .click
                if button == 0, let up = sorted[(index + 1)...].first(where: { $0.type == .up && ($0.button ?? 0) == 0 && $0.t - e.t < 5 }),
                   let q = up.point, distance(p, q) > dragDistance {
                    kind = .drag
                }
                steps.append(GuideStep(id: uniqueID("c", e.t), kind: kind, t: e.t, imageTime: max(0, e.t - imageLead), point: p))
                lastDown = (e.t, p, button)
            case .key:
                let chars = e.chars ?? ""
                guard !chars.isEmpty else { continue }
                let mods = e.mods ?? []
                if mods.contains(where: { $0 == "⌘" || $0 == "⌃" || $0 == "⌥" }) {
                    closeTyping()
                    let combo = mods.joined() + displayKey(chars)
                    if let li = steps.indices.last, steps[li].kind == .shortcut, steps[li].keys == combo, e.t - lastKey < 2 {
                        steps[li].count += 1
                    } else {
                        steps.append(GuideStep(id: uniqueID("k", e.t), kind: .shortcut, t: e.t, imageTime: max(0, e.t - imageLead), keys: combo))
                    }
                    lastKey = e.t
                    continue
                }
                switch chars {
                case "⏎", "⌤", "⇥", "⎋":
                    let name = chars == "⇥" ? "Tab" : chars == "⎋" ? "Esc" : "Return"
                    if let i = typing, e.t - lastKey <= typingGap, name != "Esc" {
                        steps[i].keys = name
                        closeTyping()
                    } else {
                        closeTyping()
                        if let li = steps.indices.last, steps[li].kind == .key, steps[li].keys == name, e.t - lastKey < 2 {
                            steps[li].count += 1
                        } else {
                            steps.append(GuideStep(id: uniqueID("k", e.t), kind: .key, t: e.t, imageTime: max(0, e.t - imageLead), keys: name))
                        }
                    }
                    lastKey = e.t
                case "←", "→", "↑", "↓", "↖", "↘", "⇞", "⇟", "⌦":
                    // Moving around or editing inside a field: not a step, and it doesn't end the typing.
                    if typing != nil { lastKey = e.t }
                default:
                    if typing == nil || e.t - lastKey > typingGap {
                        closeTyping()
                        if let li = steps.indices.last, steps[li].kind == .click, steps[li].count == 1, e.t - steps[li].t < fieldWindow {
                            // Typing right after a click goes into what was clicked.
                            steps[li].kind = .type
                            typing = li
                        } else {
                            steps.append(GuideStep(id: uniqueID("t", e.t), kind: .type, t: e.t, imageTime: max(0, e.t - imageLead)))
                            typing = steps.count - 1
                        }
                    }
                    if chars == "⌫" {
                        if !typingText.isEmpty { typingText.removeLast() }
                    } else {
                        typingText += typedCharacter(chars, shift: mods.contains("⇧"))
                    }
                    lastKey = e.t
                }
            default:
                continue
            }
            if steps.count > maxSteps + 50 { break }
        }
        closeTyping()
        return Array(steps.prefix(maxSteps))
    }

    /// What one key event types: "␣" is a space; with ⇧, letters go upper case and US-layout symbols shift.
    static func typedCharacter(_ chars: String, shift: Bool) -> String {
        if chars == "␣" { return " " }
        guard shift else { return chars }
        let shifted: [Character: Character] = ["1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*",
                                               "9": "(", "0": ")", "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|",
                                               ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?", "`": "~"]
        return String(chars.map { shifted[$0] ?? Character($0.uppercased()) })
    }

    /// A key as shortcuts print it: "⏎" stays, letters upper case.
    static func displayKey(_ chars: String) -> String {
        chars == "␣" ? "Space" : chars.uppercased()
    }

    static func distance(_ a: NormPoint, _ b: NormPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

    /// Narration for each step: what was said from 1.5 s after the previous step until 1.5 s after this one (by
    /// the middle of each word or sentence in `words`), at most the last 40 of them.
    public static func narration(for steps: [GuideStep], words: [TimedWord]) -> [String?] {
        let sorted = words.sorted { $0.start < $1.start }
        var out: [String?] = []
        var from = -Double.infinity
        for s in steps {
            let to = s.t + 1.5
            let picked = sorted.filter { w in let mid = (w.start + w.end) / 2; return mid > from && mid <= to }
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let text = picked.suffix(40).joined(separator: " ")
            out.append(text.isEmpty ? nil : text)
            from = max(from, to)
        }
        return out
    }
}

// MARK: - Wording

/// The plain instruction for a step, used when the on-device model isn't available or wrote something unusable.
public enum StepText {
    /// - Parameter typed: what to quote for a typing step (`nil` = say which field instead).
    public static func template(_ s: GuideStep, typed: String?) -> String {
        let label = s.label.map(quoted)
        var text: String
        switch s.kind {
        case .click: text = label.map { (isBeside(s) ? "Click next to " : "Click ") + $0 } ?? "Click here"
        case .doubleClick: text = label.map { "Double-click \($0)" } ?? "Double-click here"
        case .rightClick: text = label.map { "Right-click \($0)" } ?? "Right-click here"
        case .drag: text = label.map { "Drag \($0)" } ?? "Drag from here"
        case .type:
            if let typed, !typed.isEmpty {
                text = "Type \(quoted(typed))" + (label.map { " in \($0)" } ?? "")
            } else {
                text = label.map { "Type in \($0)" } ?? "Type your text"
            }
            if let k = s.keys { text += ", then press \(k)" }
            return text
        case .shortcut, .key: text = "Press \(s.keys ?? "the key")"
        }
        if s.count > 1 { text += " (\(s.count) times)" }
        return text
    }

    /// Whether the click landed beside its label rather than on it (a checkbox or an icon next to its text).
    static func isBeside(_ s: GuideStep) -> Bool {
        guard let p = s.point, let r = s.labelRect else { return false }
        let slack = max(0.004, r.height * 0.5)
        return p.x < r.x - slack || p.x > r.x + r.width + slack || p.y < r.y - slack || p.y > r.y + r.height + slack
    }

    /// "Inbox" in curly-free straight quotes, at most 80 characters.
    static func quoted(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\"" + (t.count > 80 ? String(t.prefix(79)) + "…" : t) + "\""
    }
}

// MARK: - Resolving for an edit

public enum GuideSteps {
    /// The steps as the guide shows them for this edit:
    /// - only steps in the kept part of the recording (trim, cuts and pauses removed) and inside the crop;
    /// - hidden steps left out, hand-written text applied;
    /// - labels under a blur dropped; typed text shown only when allowed and nothing sensitive is in it;
    /// - sections from markers (`Markers.resolve`), narration from `words`.
    public static func resolve(_ scanned: [GuideStep], edit: EditDocument, duration: Double, markers: [Marker],
                               words: [TimedWord] = []) -> [GuideStep] {
        let timeline = EditTimeline(duration: duration, trim: edit.trim, cuts: edit.cuts, speed: edit.speed)
        let crop = CropSpace(edit.crop)
        let blurs = edit.annotations.filter { $0.kind == .blur }
        var kept: [GuideStep] = []
        for var s in scanned.sorted(by: { $0.t < $1.t }) {
            guard let range = timeline.kept.first(where: { $0.contains(s.t) }) else { continue }
            if let p = s.point, !crop.contains(p) { continue }
            if edit.guide.edit(for: s.id)?.hidden == true { continue }
            if !range.contains(s.imageTime) { s.imageTime = s.t }
            // What a blur hides never reaches the guide: not as the label, nor inside the model's sentence.
            if let r = s.labelRect, underBlur(r, at: s.t, blurs) || underBlur(r, at: s.imageTime, blurs) {
                s.label = nil; s.labelRect = nil; s.modelText = nil
            } else if s.labelRect == nil, let p = s.point, underBlur(NormRect(x: p.x, y: p.y, width: 0, height: 0), at: s.t, blurs) {
                s.label = nil; s.modelText = nil
            }
            kept.append(s)
        }
        let narration = StepExtractor.narration(for: kept, words: words)
        var out: [GuideStep] = []
        var markerIndex = 0
        let sortedMarkers = markers.sorted { $0.t < $1.t }
        for (i, var s) in kept.enumerated() {
            s.narration = narration[i]
            // The last marker since the previous step opens a section here.
            var section: String?
            while markerIndex < sortedMarkers.count, sortedMarkers[markerIndex].t <= s.t {
                section = sortedMarkers[markerIndex].title
                markerIndex += 1
            }
            s.section = section
            let typed = s.kind == .type ? shownTyping(s, settings: edit.guide, blurs: blurs) : nil
            if s.kind == .type, typed == nil { s.typed = nil }
            if let text = edit.guide.edit(for: s.id)?.text {
                s.text = text
            } else if let m = s.modelText, s.kind != .type, modelTextKeepsLabel(m, label: s.label) {
                s.text = m
            } else {
                s.text = StepText.template(s, typed: typed)
            }
            out.append(s)
        }
        return out
    }

    /// The typed text a step may show, or `nil`: only with `showTypedText`, never while a blur covers the field
    /// or the screen at that moment, and with anything that looks like an email, key, card or phone number masked.
    static func shownTyping(_ s: GuideStep, settings: GuideSettings, blurs: [Annotation]) -> String? {
        guard settings.showTypedText, let typed = s.typed?.trimmingCharacters(in: .whitespacesAndNewlines), !typed.isEmpty else { return nil }
        if blurs.contains(where: { $0.range.contains(s.t) }) { return nil }
        var out = typed
        for m in SensitivePatterns.matches(in: typed).reversed() where out.indices.contains(m.range.lowerBound) {
            out.replaceSubrange(m.range, with: "•••")
        }
        return out
    }

    /// A model sentence is used only when it still names what was clicked (so it can't invent a different button).
    static func modelTextKeepsLabel(_ text: String, label: String?) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 240 else { return false }
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return true }
        return t.range(of: label, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// A step's click point and label box on its image (0…1 of the step image, top-left origin): the step image
    /// shows the cropped screen, so full-screen positions go through the crop. Rounded to 4 decimals.
    public static func placement(_ s: GuideStep, crop: NormRect?) -> (point: NormPoint?, box: NormRect?) {
        let space = CropSpace(crop)
        func clamp(_ v: Double) -> Double { (min(1, max(0, v)) * 10_000).rounded() / 10_000 }
        let point = s.point.map { space.toView($0) }.map { NormPoint(x: clamp($0.x), y: clamp($0.y)) }
        let box = s.labelRect.map { space.toView($0) }.flatMap { r -> NormRect? in
            let x0 = clamp(r.x), y0 = clamp(r.y), x1 = clamp(r.x + r.width), y1 = clamp(r.y + r.height)
            return x1 > x0 && y1 > y0 ? NormRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) : nil
        }
        return (point, box)
    }

    /// Whether a blur covers `rect` (or the point it degenerates to) at recording time `t`.
    static func underBlur(_ rect: NormRect, at t: Double, _ blurs: [Annotation]) -> Bool {
        blurs.contains { b in
            guard b.range.contains(t) else { return false }
            let areas = (b.keys?.map(\.rect) ?? []) + [b.rect]
            return areas.contains { a in
                rect.x <= a.x + a.width && a.x <= rect.x + rect.width && rect.y <= a.y + a.height && a.y <= rect.y + rect.height
            }
        }
    }
}

// MARK: - Cache

/// `steps.json`: the scanned steps (labels read from the screen, model wording) so a guide opens without
/// reading the video again. Ignored when `version` or `inputs` don't match; deleting it is always safe.
public struct StepDocument: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    /// What the scan read; any change means scan again.
    public struct Inputs: Codable, Hashable, Sendable {
        public var events: Int64
        public var screen: String
        public var screenSize: Int64
        public var transcript: Int64?
        public init(events: Int64, screen: String, screenSize: Int64, transcript: Int64?) {
            self.events = events; self.screen = screen; self.screenSize = screenSize; self.transcript = transcript
        }
    }

    public var version: Int
    public var inputs: Inputs
    /// `template` or `model` (wording by the on-device model).
    public var writer: String
    public var steps: [GuideStep]

    public init(version: Int = StepDocument.currentVersion, inputs: Inputs, writer: String, steps: [GuideStep]) {
        self.version = version; self.inputs = inputs; self.writer = writer; self.steps = steps
    }
}

extension ProjectBundle {
    public var stepsURL: URL { url.appendingPathComponent("steps.json") }

    /// What a step scan of this project would read now, or `nil` without a screen track.
    public func stepInputs(manifest: ProjectManifest) -> StepDocument.Inputs? {
        guard let file = manifest.track(.screen)?.file else { return nil }
        func size(_ u: URL) -> Int64? { (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.int64Value }
        guard let screenSize = size(resolve(file)) else { return nil }
        return StepDocument.Inputs(events: size(eventsURL) ?? 0, screen: file, screenSize: screenSize, transcript: size(transcriptURL))
    }

    /// The cached scan, when it was made from the same inputs.
    public func readSteps(inputs: StepDocument.Inputs) -> StepDocument? {
        guard let data = try? Data(contentsOf: stepsURL),
              let doc = try? JSONCoding.decoder.decode(StepDocument.self, from: data),
              doc.version == StepDocument.currentVersion, doc.inputs == inputs else { return nil }
        return doc
    }

    public func writeSteps(_ doc: StepDocument) throws {
        try JSONCoding.writeAtomically(doc, to: stepsURL)
    }
}

// MARK: - Text layer

/// The text on screen in a published video, for selecting and copying it on the share page (`text.<rev>.json`).
/// Times are output seconds; boxes are normalized to the video frame (top-left origin).
public struct TextLayer: Codable, Hashable, Sendable {
    public struct Line: Codable, Hashable, Sendable {
        public var text: String
        public var x: Double
        public var y: Double
        public var w: Double
        public var h: Double
        public init(text: String, x: Double, y: Double, w: Double, h: Double) {
            self.text = text; self.x = x; self.y = y; self.w = w; self.h = h
        }
    }
    public struct Frame: Codable, Hashable, Sendable {
        public var start: Double
        public var end: Double
        public var lines: [Line]
        public init(start: Double, end: Double, lines: [Line]) { self.start = start; self.end = end; self.lines = lines }
    }

    public var version = 1
    public var width: Int
    public var height: Int
    public var frames: [Frame]

    public init(width: Int, height: Int, frames: [Frame]) { self.width = width; self.height = height; self.frames = frames }

    public var isEmpty: Bool { frames.allSatisfy(\.lines.isEmpty) }
}
