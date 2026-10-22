import AppKit
import Observation
import ReelbirdCore
import ReelbirdGuide

/// The Guide panel's state: the steps as the guide shows them, their thumbnails and the work in progress.
@MainActor @Observable final class GuidePanelState {
    enum Load: Equatable { case idle, working, failed(String) }

    var steps: [GuideStep] = []
    var load: Load = .idle
    /// True once steps were read for this recording (an empty list then means "no steps", not "not yet").
    var loaded = false
    /// By step id.
    var thumbnails: [String: NSImage] = [:]
    var isExporting = false
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored var thumbnailKey: Int?
}

extension EditorModel {
    /// Everything the guide's steps depend on in the edit: a change re-reads them (from steps.json, so it's quick).
    var guideKey: Int {
        var h = Hasher()
        h.combine(edit.guide); h.combine(edit.trim); h.combine(edit.cuts); h.combine(edit.crop)
        h.combine(edit.annotations); h.combine(edit.markers); h.combine(edit.speed)
        return h.finalize()
    }

    /// Steps hidden by hand, for "Show All".
    var hiddenStepCount: Int { edit.guide.edits.filter { $0.hidden == true }.count }

    /// Reads the steps for the current edit (`refresh` reads the screen again), then their thumbnails.
    func loadGuide(refresh: Bool = false) {
        let g = guidePanel
        g.task?.cancel()
        if refresh || !g.loaded { g.load = .working }
        let services = services, bundle = bundle, edit = edit
        g.task = Task {
            do {
                let steps = try await services.guide.steps(bundle: bundle, edit: edit, refresh: refresh, progress: { _ in })
                guard !Task.isCancelled else { return }
                g.steps = steps
                g.loaded = true
                g.load = .idle
                loadGuideThumbnails()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                g.loaded = true
                g.load = .failed((error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// Thumbnails for the steps shown, rendered again only when what they show changed (crop, blurs, moments).
    private func loadGuideThumbnails() {
        let g = guidePanel
        var h = Hasher()
        for s in g.steps { h.combine(s.id); h.combine(s.imageTime) }
        h.combine(edit.crop); h.combine(edit.annotations)
        let key = h.finalize()
        guard key != g.thumbnailKey else { return }
        g.thumbnailKey = key
        g.thumbnailTask?.cancel()
        let services = services, bundle = bundle, edit = edit, steps = g.steps
        g.thumbnailTask = Task {
            guard let images = try? await services.guide.images(bundle: bundle, edit: edit, steps: steps, maxWidth: 320),
                  !Task.isCancelled else { return }
            var thumbs: [String: NSImage] = [:]
            for (s, img) in zip(steps, images) { thumbs[s.id] = NSImage(cgImage: img, size: NSSize(width: img.width / 2, height: img.height / 2)) }
            g.thumbnails = thumbs
        }
    }

    /// Rewrites a step's instruction; an empty text goes back to the automatic one.
    func setStepText(_ id: String, _ text: String) {
        change("Edit Step", coalesce: "step-text-\(id)") { $0.guide.setEdit(id: id, text: .some(text)) }
    }

    func hideStep(_ id: String) {
        change("Hide Step") { $0.guide.setEdit(id: id, hidden: .some(true)) }
    }

    func showAllSteps() {
        change("Show All Steps") { e in
            for id in e.guide.edits.filter({ $0.hidden == true }).map(\.id) { e.guide.setEdit(id: id, hidden: .some(false)) }
        }
    }

    /// Asks for a folder, writes the guide into a new folder inside it and shows it in Finder.
    func exportGuide(_ format: GuideExport.Format) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose where to save the guide. Reelbird makes a folder for it there."
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let name = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let suffix = format == .markdown ? "Markdown" : format == .html ? "HTML" : "Skill"
        var folder = parent.appendingPathComponent("\(name) guide (\(suffix))", isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent("\(name) guide (\(suffix)) \(n)", isDirectory: true)
            n += 1
        }
        saveNow()
        let g = guidePanel, services = services, bundle = bundle, edit = edit
        g.isExporting = true
        Task {
            defer { g.isExporting = false }
            do {
                let main = try await services.guide.export(bundle: bundle, edit: edit, format: format, to: folder)
                Finder.reveal([main])
                Toast.show(title: "Guide exported", detail: folder.lastPathComponent, symbol: "list.number")
            } catch {
                Toast.show(title: "Couldn't export the guide", detail: (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription,
                           symbol: "exclamationmark.triangle.fill", duration: 6)
            }
        }
    }

    /// Snapshots: the mock steps and thumbnails, shown at once.
    func setGuideForSnapshot() {
        let g = guidePanel
        g.steps = MockGuide.sampleSteps(edit: edit)
        g.loaded = true
        var thumbs: [String: NSImage] = [:]
        for (s, img) in zip(g.steps, MockGuide.sampleImages(g.steps, maxWidth: 320)) {
            thumbs[s.id] = NSImage(cgImage: img, size: NSSize(width: img.width / 2, height: img.height / 2))
        }
        g.thumbnails = thumbs
    }
}
