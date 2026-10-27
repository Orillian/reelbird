import Foundation
import ReelbirdCore

/// Clean Up: one deliberate pass over the whole take (long pauses, ums, retakes, dead start and end, slow typing
/// and waiting). Every change is an ordinary cut or speed segment recorded in `edit.cleanUp`, so each one can be
/// put back, and the whole pass is a single undo step.
enum CleanUpState: Equatable {
    case idle
    /// What's happening, for the button's label ("Transcribing…", "Cleaning up…").
    case working(String)
}

extension EditorModel {
    var canCleanUp: Bool { hasMicrophone || manifest.track(.systemAudio) != nil }

    /// Runs Clean Up. Without a transcript it first makes one (in the last language used) without turning
    /// captions on, so ums and retakes can be found.
    func cleanUp() {
        guard canCleanUp, cleanUpState == .idle else { return }
        if transcript == nil {
            cleanUpState = .working("Transcribing…")
            // If the words can't be had (no speech model, a failure), carry on with what the audio alone says.
            generateCaptions(showCaptions: false, then: { [weak self] in self?.runCleanUp() },
                             otherwise: { [weak self] in self?.runCleanUp() })
            return
        }
        runCleanUp()
    }

    private func runCleanUp() {
        cleanUpState = .working("Cleaning up…")
        let ai = services.ai, bundle = bundle, manifest = manifest, transcript = transcript
        Task {
            defer { cleanUpState = .idle }
            let inputs: CleanUpInputs
            do {
                inputs = try await ai.cleanUpInputs(bundle: bundle, manifest: manifest, transcript: transcript)
            } catch {
                Toast.show(title: "Couldn't clean up", detail: (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription,
                           symbol: "exclamationmark.triangle.fill")
                return
            }
            let report = CleanUp.plan(inputs, edit: edit)
            guard !report.isEmpty else {
                Toast.show(title: "Nothing to clean up", detail: "No long pauses, ums or slow stretches were found.", symbol: "wand.and.stars")
                return
            }
            change("Clean Up") { CleanUp.apply(report, to: &$0) }
            showCleanUpBar = true
        }
    }

    /// "1:12 shorter · 9 pauses · 6 ums · 2 suggestions"
    var cleanUpSummary: String {
        CleanUp.summary(applied: edit.cleanUp.applied, suggestions: edit.cleanUp.suggestions.count)
    }

    /// Puts one Clean Up change back.
    func restoreCleanUp(_ item: CleanUpItem) {
        change("Restore \(item.kind.label)") { _ = CleanUp.restore(item.id, in: &$0) }
    }

    /// Applies a suggestion.
    func acceptCleanUp(_ item: CleanUpItem) {
        change("Apply \(item.kind.label)") { _ = CleanUp.accept(item.id, in: &$0) }
    }

    /// Forgets a suggestion.
    func dismissCleanUp(_ item: CleanUpItem) {
        change("Dismiss Suggestion") { _ = CleanUp.dismiss(item.id, in: &$0) }
    }

    /// Puts every Clean Up change back.
    func undoCleanUp() {
        change("Undo Clean Up") { CleanUp.undoAll(&$0) }
        showCleanUpBar = false
    }

    /// Plays the moment around a change: from a second before it.
    func previewCleanUp(_ item: CleanUpItem) {
        seek(source: max(0, item.editRange.start - 1))
        play()
    }
}
