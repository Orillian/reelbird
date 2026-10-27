import Foundation
import ReelbirdAI
import ReelbirdCore

/// The caption look and language used last, so the next recording starts the same way.
enum CaptionDefaults {
    private nonisolated(unsafe) static let d = UserDefaults.standard

    /// BCP 47 language of the last captions made.
    static var language: String? {
        get { d.string(forKey: "captionLanguage") }
        set { d.set(newValue, forKey: "captionLanguage") }
    }

    /// Style, colours, size, position and capitals of the last captions shown (Classic the first time).
    static var look: CaptionSettings {
        get {
            var s = CaptionSettings()
            s.style = CaptionSettings.Style(rawValue: d.string(forKey: "captionStyle") ?? "") ?? .classic
            if s.style == .none { s.style = .classic }
            s.palette = CaptionSettings.Palette(rawValue: d.string(forKey: "captionPalette") ?? "") ?? .night
            s.size = CaptionSettings.Size(rawValue: d.string(forKey: "captionSize") ?? "") ?? .medium
            s.position = CaptionSettings.Position(rawValue: d.string(forKey: "captionPosition") ?? "") ?? .auto
            s.uppercase = d.object(forKey: "captionUppercase") as? Bool ?? true
            return s
        }
        set {
            if newValue.style != .none { d.set(newValue.style.rawValue, forKey: "captionStyle") }
            d.set(newValue.palette.rawValue, forKey: "captionPalette")
            d.set(newValue.size.rawValue, forKey: "captionSize")
            d.set(newValue.position.rawValue, forKey: "captionPosition")
            d.set(newValue.uppercase, forKey: "captionUppercase")
        }
    }
}

extension EditorModel {
    /// Fills in the languages offered for captions and settles the default (last used, else this Mac's language).
    func loadCaptionLanguages() {
        guard captionLanguages.isEmpty else { return }
        let ai = services.ai
        Task {
            let (all, installed) = await ai.captionLanguages()
            // Downloaded languages first, then the rest by name.
            func name(_ id: String) -> String { Locale.current.localizedString(forIdentifier: id) ?? id }
            captionLanguages = all.sorted { a, b in
                let ia = installed.contains(a), ib = installed.contains(b)
                return ia != ib ? ia : name(a).localizedStandardCompare(name(b)) == .orderedAscending
            }
            installedCaptionLanguages = installed
            captionLanguage = Transcriber.defaultLanguage(preferred: CaptionDefaults.language, among: all)
        }
    }

    /// A language's name for menus, e.g. "English (United States)".
    func captionLanguageName(_ id: String) -> String {
        Locale.current.localizedString(forIdentifier: id) ?? id
    }

    /// Changes the caption look and remembers it for the next recording.
    func setCaptionLook(_ name: String, _ body: (inout CaptionSettings) -> Void) {
        change(name) { body(&$0.captions) }
        CaptionDefaults.look = edit.captions
    }

    // MARK: Transcript corrections

    /// Replaces a line's text, keeping its timing. Returns the one word that changed, when exactly one did, so the
    /// panel can offer to fix it everywhere.
    @discardableResult
    func editTranscriptLine(_ index: Int, text: String) -> (old: String, new: String, others: Int)? {
        guard let t = transcript, t.segments.indices.contains(index) else { return nil }
        let before = t.segments[index].timedWords.map(\.text)
        let next = t.replacingText(ofSegment: index, with: text)
        guard next != t else { return nil }
        saveTranscript(next, actionName: "Edit Caption")
        let after = next.segments[index].timedWords.map(\.text)
        guard before.count == after.count else { return nil }
        let changed = zip(before, after).filter { $0 != $1 }
        guard changed.count == 1, let (old, new) = changed.first else { return nil }
        func core(_ w: String) -> String { w.trimmingCharacters(in: .punctuationCharacters).lowercased() }
        let others = next.segments.flatMap(\.timedWords).filter { core($0.text) == core(old) }.count
        return others > 0 ? (old, new, others) : nil
    }

    /// Every other `old` word becomes `new`.
    func fixEverywhere(_ old: String, with new: String) {
        guard let t = transcript else { return }
        let (next, n) = t.replacingWord(old, with: new)
        guard n > 0 else { return }
        saveTranscript(next, actionName: "Fix \(n) Captions")
    }

    /// Hides a line from captions (its audio stays), or shows it again.
    func toggleTranscriptLineHidden(_ index: Int) {
        guard var t = transcript, t.segments.indices.contains(index) else { return }
        t.segments[index].hidden = t.segments[index].hidden == true ? nil : true
        saveTranscript(t, actionName: t.segments[index].hidden == true ? "Hide from Captions" : "Show in Captions")
    }

    /// Writes the transcript and its captions file, redraws, and makes it undoable.
    func saveTranscript(_ t: Transcript, actionName: String) {
        guard let previous = transcript else { return }
        writeTranscript(t)
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.saveTranscript(previous, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
    }

    private func writeTranscript(_ t: Transcript) {
        do {
            try services.ai.webVTT(t.captioned).write(to: bundle.captionsURL, atomically: true, encoding: .utf8)
            try JSONCoding.writeAtomically(t, to: bundle.transcriptURL)
        } catch {
            Toast.show(title: "Couldn't save the captions", detail: error.localizedDescription, symbol: "exclamationmark.triangle.fill")
            return
        }
        transcript = t
        player?.reloadCaptions()
    }
}
