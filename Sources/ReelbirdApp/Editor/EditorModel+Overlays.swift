import AppKit
import Observation
import ReelbirdAI
import ReelbirdCore
import ReelbirdRender

/// One Find Sensitive Info suggestion waiting for Keep or Dismiss.
struct SensitiveSuggestion: Identifiable {
    let detection: SensitiveDetection
    /// Where it was first seen (stays on this Mac, in memory).
    let thumbnail: CGImage?
    var id: String { detection.id }
}

/// Overlay tools, defaults for new overlays, and Find Sensitive Info for one editor.
@MainActor @Observable final class OverlayState {
    /// The tool being drawn with on the preview (`nil` = none).
    var tool: Annotation.Kind?
    /// Defaults for the next overlay: the last style, strength and colour used.
    var blurStyle: Annotation.BlurStyle = .blur
    var blurStrength = Annotation.defaultStrength
    var blurShape: Annotation.BlurShape = .rounded
    var blurSoftness = Annotation.defaultSoftness
    var color: RGBA = Annotation.defaultColor

    /// Find Sensitive Info: suggestions waiting for a decision, progress while scanning (`nil` = idle).
    private(set) var suggestions: [SensitiveSuggestion] = []
    private(set) var scanProgress: Double?
    private(set) var scanError: String?
    /// A scan finished (an empty list then means nothing was found).
    private(set) var scanned = false
    /// How long the last scan took and how much it looked at, for the result line.
    private(set) var lastScan: (seconds: Double, found: Int)?
    /// Extra words to look for, comma separated. Remembered for every recording.
    var customWords: String {
        didSet { UserDefaults.standard.set(customWords, forKey: Self.wordsKey) }
    }
    var kinds: Set<SensitiveKind> = Set(SensitiveKind.allCases).subtracting([.custom])
    /// A newly added text overlay whose text field should take focus.
    var focusTextID: String?

    @ObservationIgnored let ai: any AIService
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    static let wordsKey = "privacyCustomWords"

    init(ai: any AIService) {
        self.ai = ai
        customWords = UserDefaults.standard.string(forKey: Self.wordsKey) ?? ""
    }

    var isScanning: Bool { scanProgress != nil }

    var words: [String] {
        customWords.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 2 }
    }

    fileprivate func startScan(bundle: ProjectBundle, existing: Set<String>) {
        scanTask?.cancel()
        scanError = nil
        scanProgress = 0
        var options = SensitiveInfoScanner.Options()
        options.kinds = kinds.union(words.isEmpty ? [] : [.custom])
        options.customWords = words
        let ai = ai
        let report: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor in
                guard let self, let cur = self.scanProgress else { return }
                self.scanProgress = max(cur, p)
            }
        }
        scanTask = Task { [weak self] in
            do {
                let result = try await ai.findSensitiveInfo(bundle: bundle, options: options, progress: report)
                guard let self, !Task.isCancelled else { return }
                self.suggestions = result.detections.filter { !existing.contains($0.id) }
                    .map { SensitiveSuggestion(detection: $0, thumbnail: result.thumbnails[$0.id]) }
                self.lastScan = (result.seconds, result.detections.count)
                self.scanned = true
                self.scanProgress = nil
            } catch is CancellationError {
                self?.scanProgress = nil
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.scanProgress = nil
                self.scanError = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanProgress = nil
    }

    fileprivate func remove(_ ids: Set<String>) { suggestions.removeAll { ids.contains($0.id) } }

    /// Puts suggestions in place directly (snapshots, self test).
    func setSuggestionsForSnapshot(_ s: [SensitiveSuggestion], scanning: Double? = nil) {
        suggestions = s
        scanned = scanning == nil
        scanProgress = scanning
        lastScan = scanning == nil ? (4.2, s.count) : nil
    }
}

extension EditorModel {
    // MARK: Overlays

    var selectedAnnotation: Annotation? {
        guard case .annotation(let id) = selection else { return nil }
        return edit.annotations.first { $0.id == id }
    }

    /// Whether the preview shows overlay handles (the Overlays panel is open, a tool is active, or one is selected).
    var showsOverlayCanvas: Bool {
        guard !isCropping, player != nil else { return false }
        if overlays.tool != nil || section == .overlays { return true }
        if case .annotation = selection { return true }
        return false
    }

    /// Arms a tool: the next drag on the preview draws it (playback pauses).
    func beginOverlayTool(_ kind: Annotation.Kind) {
        if isPlaying { pause() }
        guard !isCropping else { return }
        overlays.tool = kind
        section = .overlays
        if case .annotation = selection { selection = nil }
    }

    func cancelOverlayTool() { overlays.tool = nil }

    /// Esc: drops the armed tool first, then the selection.
    func escape() {
        if overlays.tool != nil { overlays.tool = nil } else { selection = nil }
    }

    /// How long a new overlay lasts.
    static func defaultOverlayDuration(_ kind: Annotation.Kind) -> Double { kind == .blur ? 5 : 3 }

    /// Adds an overlay drawn on the preview at the playhead and selects it. Arrows go from `tail` to `head`.
    @discardableResult
    func addAnnotation(_ kind: Annotation.Kind, rect: NormRect, tail: NormPoint? = nil, head: NormPoint? = nil) -> String {
        let length = Self.defaultOverlayDuration(kind)
        let start = max(0, min(playhead, duration - min(length, duration)))
        var a = Annotation(kind: kind, range: TimeRange(start: start, end: min(duration, start + length)), rect: rect.clampedToUnit())
        switch kind {
        case .blur:
            a.style = overlays.blurStyle
            a.strength = overlays.blurStrength
            a.shape = overlays.blurShape
            a.softness = overlays.blurSoftness
            if overlays.blurStyle == .solid { a.color = Annotation.solidColor }
        case .arrow:
            a.color = overlays.color
            a.setArrow(tail: tail ?? NormPoint(x: rect.x, y: rect.y), head: head ?? NormPoint(x: rect.x + rect.width, y: rect.y + rect.height))
        case .box:
            a.color = overlays.color
        case .text:
            a.color = overlays.color
            a.text = "Text"
            // Letters a little over half the drawn height (a plain click gets 2.4% of the screen's height).
            a.fontSize = min(0.08, max(0.012, rect.height > 0.01 ? rect.height * 0.55 : 0.024))
            fitTextRect(&a)
            overlays.focusTextID = a.id
        case .highlight:
            break
        }
        change("Add \(kind.title)") { $0.annotations.append(a) }
        overlays.tool = nil
        selection = .annotation(a.id)
        section = .overlays
        return a.id
    }

    /// Changes one overlay with undo (changes with the same `coalesce` key inside a second are one step).
    func updateAnnotation(_ id: String, _ actionName: String = "Edit Overlay", coalesce: String, _ body: (inout Annotation) -> Void) {
        change(actionName, coalesce: coalesce + id) { e in
            guard let i = e.annotations.firstIndex(where: { $0.id == id }) else { return }
            var a = e.annotations[i]
            body(&a)
            let d = duration
            let minLen = Annotation.minimumDuration
            let s = min(max(0, a.range.start), max(0, d - minLen))
            a.range = TimeRange(start: s, end: min(d, max(s + minLen, a.range.end)))
            if a.kind == .text { fitTextRect(&a) }
            e.annotations[i] = a
        }
    }

    func deleteAnnotation(_ id: String) {
        change("Delete Overlay") { $0.annotations.removeAll { $0.id == id } }
        if selection == .annotation(id) { selection = nil }
    }

    /// Selects an overlay and, when the playhead is outside it, goes to its start.
    func selectAnnotation(_ id: String) {
        guard let a = edit.annotations.first(where: { $0.id == id }) else { return }
        selection = .annotation(id)
        section = .overlays
        overlays.tool = nil
        if !a.range.contains(playhead) { seek(source: min(a.range.end - 0.01, a.range.start + 0.01)) }
    }

    /// Sizes a text overlay's `rect` to its label, as the renderer draws it.
    func fitTextRect(_ a: inout Annotation) {
        let size = screenPixelSize
        let h = Double(max(1, size.height)), w = Double(max(1, size.width))
        let px = a.textSize * h
        let label = AnnotationLabel.labelSize(text: a.text ?? "", fontPixels: px)
        if a.fontSize == nil { a.fontSize = a.textSize }
        a.rect = NormRect(x: a.rect.x, y: a.rect.y, width: min(1, Double(label.width) / w), height: min(1, Double(label.height) / h))
    }

    // MARK: Find Sensitive Info

    func findSensitiveInfo() {
        overlays.startScan(bundle: bundle, existing: Set(edit.annotations.map(\.id)))
    }

    /// Suggestions on screen at the playhead (outlined on the preview).
    var suggestionsAtPlayhead: [SensitiveSuggestion] {
        overlays.suggestions.filter { $0.detection.range.contains(playhead) }
    }

    func keepSuggestion(_ id: String) {
        guard let s = overlays.suggestions.first(where: { $0.id == id }) else { return }
        var a = s.detection.annotation(style: overlays.blurStyle, strength: overlays.blurStrength)
        a.shape = overlays.blurShape
        a.softness = overlays.blurSoftness
        if a.blurStyle == .solid { a.color = Annotation.solidColor }
        change("Blur \(s.detection.kind.title)") { e in
            if !e.annotations.contains(where: { $0.id == a.id }) { e.annotations.append(a) }
        }
        overlays.remove([id])
    }

    /// Keeps every waiting suggestion as a blur (one undo step).
    func keepAllSuggestions() {
        let all = overlays.suggestions
        guard !all.isEmpty else { return }
        let style = overlays.blurStyle, strength = overlays.blurStrength, shape = overlays.blurShape, softness = overlays.blurSoftness
        change("Blur Sensitive Info") { e in
            for s in all where !e.annotations.contains(where: { $0.id == s.id }) {
                var a = s.detection.annotation(style: style, strength: strength)
                a.shape = shape
                a.softness = softness
                if style == .solid { a.color = Annotation.solidColor }
                e.annotations.append(a)
            }
        }
        overlays.remove(Set(all.map(\.id)))
    }

    func dismissSuggestion(_ id: String) { overlays.remove([id]) }
    func dismissAllSuggestions() { overlays.remove(Set(overlays.suggestions.map(\.id))) }

    /// Blurs exist but the share link still plays the take uploaded while recording.
    var linkNeedsUpdateForBlurs: Bool {
        guard let share = shareInfo, !share.polished else { return false }
        return edit.annotations.contains { $0.kind == .blur }
    }
}

// The scanner behind the app's AI service.
extension LiveAI {
    func findSensitiveInfo(bundle: ProjectBundle, options: SensitiveInfoScanner.Options,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> SensitiveInfoScanner.Result {
        try await SensitiveInfoScanner.scan(bundle: bundle, options: options, progress: progress)
    }
}

extension MockAI {
    /// Three made-up findings on the mock recording (no media is read).
    func findSensitiveInfo(bundle: ProjectBundle, options: SensitiveInfoScanner.Options,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> SensitiveInfoScanner.Result {
        for i in 1...4 { progress(Double(i) / 4); try await Task.sleep(for: .milliseconds(30)) }
        return SensitiveInfoScanner.Result(detections: MockData.sensitiveDetections.filter { options.kinds.contains($0.kind) },
                                           samples: 93, recognized: 21, seconds: 0.12, thumbnails: [:])
    }
}

extension MockData {
    /// Findings for the mock recording's settings screen.
    static let sensitiveDetections: [SensitiveDetection] = {
        func d(_ id: String, _ kind: SensitiveKind, _ preview: String, _ range: TimeRange, _ r: NormRect) -> SensitiveDetection {
            SensitiveDetection(id: id, kind: kind, preview: preview, range: range, rect: r,
                               keys: [Annotation.Key(t: range.start, rect: r), Annotation.Key(t: range.end, rect: r)],
                               firstSeen: range.start + 0.5, sightings: 12)
        }
        return [
            d("s1a2b3c4d", .email, "j…@acme.io", TimeRange(start: 2.5, end: 19), NormRect(x: 0.34, y: 0.3, width: 0.2, height: 0.035)),
            d("s2b3c4d5e", .apiKey, "sk-p…9F", TimeRange(start: 2.5, end: 19), NormRect(x: 0.34, y: 0.38, width: 0.3, height: 0.035)),
            d("s3c4d5e6f", .card, "•••• 4242", TimeRange(start: 21, end: 34.5), NormRect(x: 0.4, y: 0.55, width: 0.22, height: 0.035)),
        ]
    }()
}
