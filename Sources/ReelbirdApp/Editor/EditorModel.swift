import AppKit
import Observation
import ReelbirdAI
import ReelbirdCore
import ReelbirdRender

enum InspectorSection: String, CaseIterable, Identifiable {
    case background, cursor, zoom, camera, canvas, audio, captions
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .background: "photo.on.rectangle"
        case .cursor: "cursorarrow.rays"
        case .zoom: "plus.magnifyingglass"
        case .camera: "person.crop.circle"
        case .canvas: "aspectratio"
        case .audio: "waveform"
        case .captions: "captions.bubble"
        }
    }
}

enum TimelineSelection: Equatable {
    case zoom(String)
    /// A segment between split points (source time).
    case segment(TimeRange)
    /// An existing cut, by its range.
    case cut(TimeRange)
}

enum ExportState: Equatable {
    case idle
    case running(Double)
    case done(URL)
    case failed(String)
}

enum ShareState: Equatable {
    case idle
    case working(String, Double)
    case failed(String)
}

enum CaptionState: Equatable {
    case idle, working, failed(String)
}

/// One open recording: the edit document, playback, timeline selection, undo and autosave.
@MainActor @Observable final class EditorModel {
    let bundle: ProjectBundle
    private(set) var manifest: ProjectManifest
    let events: [InputEvent]
    private(set) var edit: EditDocument

    /// Playhead on the recording (source) timeline.
    private(set) var playhead: Double = 0
    private(set) var isPlaying = false
    var selection: TimelineSelection?
    private(set) var splits: [Double] = []
    var section: InspectorSection = .background
    /// Timeline magnification: 1 = whole recording fits.
    var timelineZoom: Double = 1

    var exportState: ExportState = .idle
    var showExport = false
    var showShare = false
    var shareState: ShareState = .idle
    var captionState: CaptionState = .idle
    var storyState: CaptionState = .idle
    /// Filled in once the captions panel asks (the check is async on macOS 26).
    private(set) var captionsUnavailableReason: String?
    private(set) var transcript: Transcript?
    private(set) var waveform: [Float] = []
    private(set) var filmstrip: [CGImage] = []
    private(set) var saveError: String?
    /// Set when the preview can't load; the stage explains instead of spinning forever.
    private(set) var previewError: String?

    @ObservationIgnored let undoManager = UndoManager()
    /// Off in snapshots so scenes don't write into the shared demo bundle.
    @ObservationIgnored var autosaveEnabled = true
    @ObservationIgnored private(set) var player: (any PreviewPlayerHandle)?
    @ObservationIgnored private let services: Services
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var shareTask: Task<Void, Never>?
    @ObservationIgnored private var coalesceKey: String?
    @ObservationIgnored private var coalesceUntil = Date.distantPast

    /// `cursorDefaults` apply only to a recording opened for the first time (no edit.json yet).
    init(bundle: ProjectBundle, services: Services, cursorDefaults: CursorSettings? = nil) throws {
        self.bundle = bundle
        self.services = services
        let manifest = try bundle.readManifest()
        let events = (try? bundle.readEvents()) ?? []
        let fresh = !FileManager.default.fileExists(atPath: bundle.editURL.path)
        var edit = (try? bundle.readEdit()) ?? EditDocument.initial(for: manifest)
        if fresh, let cursorDefaults { edit.cursor = cursorDefaults }
        if edit.title == nil { edit.title = manifest.title }
        if edit.zoom.mode == .auto && !edit.zoom.regions.contains(where: { $0.source == .auto }) {
            edit.zoom.regions += services.render.autoZoomPlan(events: events, duration: manifest.duration, intensity: edit.zoom.intensity)
        }
        self.manifest = manifest
        self.events = events
        self.edit = edit
        transcript = Self.loadTranscript(bundle: bundle, edit: edit)
    }

    /// The word-timed `transcript.json` when present, else the cues of the edit's captions file.
    static func loadTranscript(bundle: ProjectBundle, edit: EditDocument) -> Transcript? {
        if let data = try? Data(contentsOf: bundle.transcriptURL),
           let t = try? JSONCoding.decoder.decode(Transcript.self, from: data) { return t }
        guard let file = edit.captions.file,
              let text = try? String(contentsOf: bundle.resolve(file), encoding: .utf8) else { return nil }
        let cues = WebVTT.parse(text)
        return Transcript(segments: cues.map { Transcript.Segment(range: $0.range, text: $0.text.replacingOccurrences(of: "\n", with: " ")) },
                          locale: "")
    }

    /// Creates the preview player and loads the timeline media. Call once the window exists.
    func attachPlayer() {
        guard player == nil else { return }
        do {
            let p = try services.render.makePreviewPlayer(bundle: bundle)
            p.onTimeChange = { [weak self] output in self?.playerTimeChanged(output) }
            p.onReady = { [weak self] error in
                if let error { self?.previewError = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription }
            }
            p.update(edit: edit)
            player = p
        } catch {
            previewError = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        loadTimelineMedia()
    }

    func loadTimelineMedia() {
        let audioURL = bundle.mediaURL(for: .microphone, in: manifest) ?? bundle.mediaURL(for: .systemAudio, in: manifest)
        let duration = manifest.duration
        Task {
            if let audioURL, let w = await WaveformLoader.load(url: audioURL, buckets: 600) {
                waveform = w
            }
            var frames: [CGImage] = []
            for i in 0..<12 {
                if let img = try? await services.render.poster(bundle: bundle, at: duration * Double(i) / 12, maxWidth: 160) {
                    frames.append(img)
                }
            }
            filmstrip = frames
        }
    }

    /// Injects timeline media directly (snapshots).
    func setTimelineMediaForSnapshot(waveform: [Float], filmstrip: [CGImage]) {
        self.waveform = waveform
        self.filmstrip = filmstrip
    }

    var duration: Double { manifest.duration }
    var timeline: EditTimeline { EditTimeline(manifest: manifest, edit: edit) }
    var outputDuration: Double { timeline.duration }
    var outputTime: Double { timeline.outputTime(forSource: playhead) ?? 0 }
    var hasCamera: Bool { manifest.track(.camera) != nil }
    var hasMicrophone: Bool { manifest.track(.microphone) != nil }
    var hasSystemAudio: Bool { manifest.track(.systemAudio) != nil }
    var shareInfo: ShareInfo? { manifest.share }
    var title: String { edit.title ?? manifest.title }

    // MARK: Editing

    /// Applies a change with undo. Changes with the same `coalesce` key inside one second
    /// (slider drags, nudges) collapse into one undo step.
    func change(_ actionName: String, coalesce: String? = nil, _ body: (inout EditDocument) -> Void) {
        var next = edit
        body(&next)
        guard next != edit else { return }
        let now = Date()
        let merge = coalesce != nil && coalesce == coalesceKey && now < coalesceUntil
        if !merge { registerUndo(previous: edit, actionName: actionName) }
        coalesceKey = coalesce
        coalesceUntil = now.addingTimeInterval(1)
        edit = next
        editDidChange()
    }

    private func registerUndo(previous: EditDocument, actionName: String) {
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restore(previous, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
    }

    private func restore(_ doc: EditDocument, actionName: String) {
        registerUndo(previous: edit, actionName: actionName)
        coalesceKey = nil
        edit = doc
        if case .zoom(let id) = selection, !doc.zoom.regions.contains(where: { $0.id == id }) { selection = nil }
        editDidChange()
    }

    private func editDidChange() {
        player?.update(edit: edit)
        clampPlayhead()
        scheduleSave()
    }

    func setTitle(_ t: String) {
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        change("Rename") { $0.title = trimmed.isEmpty ? nil : trimmed }
    }

    // Zoom

    func setZoomMode(_ mode: ZoomSettings.Mode) {
        change("Zoom Mode") { e in
            e.zoom.mode = mode
            if mode == .auto && !e.zoom.regions.contains(where: { $0.source == .auto }) {
                e.zoom.regions += services.render.autoZoomPlan(events: events, duration: duration, intensity: e.zoom.intensity)
            }
        }
    }

    func setZoomIntensity(_ v: Double) {
        change("Zoom Intensity", coalesce: "zoomIntensity") { e in
            e.zoom.intensity = v
            e.zoom.regions.removeAll { $0.source == .auto }
            e.zoom.regions += services.render.autoZoomPlan(events: events, duration: duration, intensity: v)
            e.zoom.regions.sort { $0.range.start < $1.range.start }
        }
    }

    func resetAutoZooms() {
        change("Reset Zooms") { e in
            e.zoom.regions.removeAll()
            e.zoom.regions = services.render.autoZoomPlan(events: events, duration: duration, intensity: e.zoom.intensity)
        }
        selection = nil
    }

    func addZoomAtPlayhead() {
        let start = min(playhead, max(0, duration - 1))
        let region = ZoomRegion(range: TimeRange(start: start, end: min(duration, start + 3)), scale: 1.8, source: .user)
        change("Add Zoom") { e in
            if e.zoom.mode == .off { e.zoom.mode = .manual }
            // A zoom you add replaces automatic zooms it overlaps.
            e.zoom.regions.removeAll { $0.source == .auto && $0.range.overlaps(region.range) }
            e.zoom.regions.append(region)
            e.zoom.regions.sort { $0.range.start < $1.range.start }
        }
        selection = .zoom(region.id)
        section = .zoom
    }

    func updateZoom(_ id: String, coalesce: String, _ body: (inout ZoomRegion) -> Void) {
        change("Edit Zoom", coalesce: coalesce + id) { e in
            guard let i = e.zoom.regions.firstIndex(where: { $0.id == id }) else { return }
            body(&e.zoom.regions[i])
            e.zoom.regions[i].source = .user // touched by hand: keep it when auto zooms regenerate
            let r = e.zoom.regions[i].range
            e.zoom.regions[i].range = TimeRange(start: max(0, r.start), end: min(duration, max(r.start + 0.3, r.end)))
        }
    }

    var selectedZoom: ZoomRegion? {
        guard case .zoom(let id) = selection else { return nil }
        return edit.zoom.regions.first { $0.id == id }
    }

    // Cuts, splits, trim

    func splitAtPlayhead() {
        let t = playhead
        guard t > 0.05, t < duration - 0.05, !splits.contains(where: { abs($0 - t) < 0.05 }) else { return }
        splits.append(t)
        splits.sort()
        selection = .segment(segment(containing: t + 0.001))
    }

    /// The segment between split points / trim bounds that contains `t`.
    func segment(containing t: Double) -> TimeRange {
        let lower = ([edit.trim?.start ?? 0] + splits).filter { $0 <= t }.max() ?? 0
        let upper = ([edit.trim?.end ?? duration] + splits).filter { $0 > t }.min() ?? duration
        return TimeRange(start: lower, end: upper)
    }

    func cut(_ range: TimeRange) {
        change("Cut") { e in
            e.cuts.append(range)
            e.cuts = Self.merged(e.cuts)
        }
        selection = .cut(range)
    }

    func restoreCut(_ range: TimeRange) {
        change("Restore Cut") { e in e.cuts.removeAll { $0.overlaps(range) && abs($0.start - range.start) < 0.01 } }
        selection = nil
    }

    func setTrim(start: Double? = nil, end: Double? = nil) {
        change("Trim", coalesce: "trim") { e in
            var t = e.trim ?? TimeRange(start: 0, end: duration)
            if let start { t.start = min(max(0, start), t.end - 0.5) }
            if let end { t.end = max(min(duration, end), t.start + 0.5) }
            e.trim = (t.start <= 0.001 && t.end >= duration - 0.001) ? nil : t
        }
    }

    func deleteSelection() {
        switch selection {
        case .zoom(let id):
            change("Delete Zoom") { $0.zoom.regions.removeAll { $0.id == id } }
            selection = nil
        case .segment(let r):
            cut(r)
        case .cut(let r):
            restoreCut(r)
        case nil:
            break
        }
    }

    func removeSilences() {
        guard let mic = bundle.mediaURL(for: .microphone, in: manifest),
              let silences = try? services.ai.silentRanges(audio: mic) else { return }
        let offset = manifest.track(.microphone)?.startTime ?? 0
        let shifted = silences.map { TimeRange(start: $0.start + offset, end: $0.end + offset) }
        // Keep a little air next to speech, like `reelbird silences --apply`.
        let cuts = SilenceDetector.trimCuts(silences: shifted, duration: duration)
        guard !cuts.isEmpty else { return }
        change("Remove Silences") { e in e.cuts = Self.merged(e.cuts + cuts) }
    }

    static func merged(_ ranges: [TimeRange]) -> [TimeRange] {
        var out: [TimeRange] = []
        for r in ranges.sorted(by: { $0.start < $1.start }) where r.duration > 0.01 {
            if let last = out.last, r.start <= last.end { out[out.count - 1].end = max(last.end, r.end) } else { out.append(r) }
        }
        return out
    }

    // MARK: Playback

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { return }
        player.seek(to: outputTime)
        player.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    /// Seeks to a source time; times inside cuts jump to the next kept moment.
    func seek(source t: Double) {
        let clamped = min(max(0, t), duration)
        let tl = timeline
        if let out = tl.outputTime(forSource: clamped) {
            playhead = clamped
            player?.seek(to: out)
        } else if let next = tl.kept.first(where: { $0.start >= clamped }) {
            playhead = next.start
            player?.seek(to: tl.outputTime(forSource: next.start) ?? 0)
        } else {
            playhead = clamped
        }
    }

    func step(_ seconds: Double) { seek(source: playhead + seconds) }

    /// J/K/L: reverse-step, pause, play.
    func shuttle(_ key: Character) {
        switch key {
        case "k": pause()
        case "l": play()
        case "j": pause(); step(-2)
        default: break
        }
    }

    private func playerTimeChanged(_ output: Double) {
        playhead = timeline.sourceTime(forOutput: output)
        if let p = player, output >= p.duration - 0.001, isPlaying { isPlaying = false }
    }

    private func clampPlayhead() {
        if timeline.outputTime(forSource: playhead) == nil { seek(source: playhead) }
    }

    /// First moment at or after `t` that isn't inside a zoom (snapshots show the full frame).
    func unzoomedTime(after t: Double) -> Double {
        var x = t
        while let r = edit.zoom.regions.first(where: { x >= $0.range.start - 0.5 && x <= $0.range.end + 0.5 }) { x = r.range.end + 0.6 }
        return min(x, duration)
    }

    func setPlayheadForSnapshot(_ t: Double) {
        playhead = t
        player?.seek(to: timeline.outputTime(forSource: t) ?? 0)
    }

    // MARK: Saving

    private func scheduleSave() {
        guard autosaveEnabled else { return }
        saveTask?.cancel()
        let doc = edit
        let bundle = bundle
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            let result = await Task.detached { () -> String? in
                do { try bundle.writeEdit(doc); return nil } catch { return error.localizedDescription }
            }.value
            self?.saveError = result.map { "Edits couldn't be saved: \($0)" }
        }
    }

    func saveNow() {
        saveTask?.cancel()
        try? bundle.writeEdit(edit)
    }

    // MARK: Export

    /// True while an export or a link upload is running (closing or quitting asks first).
    var isBusy: Bool {
        if case .running = exportState { return true }
        return shareState.isWorking
    }

    /// Stops a running export or upload. The recording and its edits are untouched.
    func cancelWork() {
        exportTask?.cancel(); exportTask = nil
        shareTask?.cancel(); shareTask = nil
        if case .running = exportState { exportState = .idle }
        if shareState.isWorking { shareState = .idle }
    }

    func export(_ options: ExportOptions) {
        exportState = .running(0)
        let services = services, bundle = bundle, edit = edit
        exportTask = Task {
            do {
                let url = try await services.render.export(bundle: bundle, edit: edit, options: options) { p in
                    Task { @MainActor in
                        if case .running = self.exportState { self.exportState = .running(p) }
                    }
                }
                guard !Task.isCancelled else { exportState = .idle; return }
                exportState = .done(url)
            } catch is CancellationError {
                exportState = .idle
            } catch {
                exportState = Task.isCancelled ? .idle : .failed((error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    // MARK: Share

    var shareConfigured: Bool { services.share.loadDestination() != nil && services.share.secret() != nil }

    /// Renders the polished video and publishes (or updates) the link, then copies it.
    func publish() {
        guard let dest = services.share.loadDestination(), let secret = services.share.secret() else { return }
        shareState = .working("Rendering", 0)
        saveNow() // the share service reads title and chapters from edit.json
        let services = services, bundle = bundle, edit = edit
        // Viewers see the edited video, so captions go on the output timeline.
        let captionsVTT = edit.captions.file == nil ? nil : transcript.map { services.ai.webVTT($0.remapped(to: timeline)) }
        shareTask = Task {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("reelbird-share-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            do {
                try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                let video = try await services.render.export(bundle: bundle, edit: edit,
                                                             options: ExportOptions(format: .mp4H264, height: 1080,
                                                                                    destination: tmp.appendingPathComponent("video.mp4"))) { p in
                    Task { @MainActor in self.shareState = .working("Rendering", p * 0.6) }
                }
                let poster = try? await services.render.poster(bundle: bundle, at: 0, maxWidth: 1280)
                var captions: URL?
                if let captionsVTT {
                    let url = tmp.appendingPathComponent("captions.vtt")
                    try captionsVTT.write(to: url, atomically: true, encoding: .utf8)
                    captions = url
                }
                let info = try await services.share.publish(bundle: bundle, video: video, poster: poster, captions: captions,
                                                            destination: dest, secret: secret) { p in
                    Task { @MainActor in self.shareState = .working("Uploading", 0.6 + p * 0.4) }
                }
                var m = manifest
                m.share = info
                try? bundle.writeManifest(m)
                manifest = m
                shareState = .idle
                copyLink()
                Toast.show(title: "Link copied", detail: info.polished ? "Your link now plays the edited video" : nil, symbol: "link")
            } catch {
                shareState = Task.isCancelled ? .idle : .failed((error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// Deletes the uploaded share; the link stops working.
    func unpublish() {
        guard let info = shareInfo, let dest = services.share.loadDestination(), let secret = services.share.secret() else { return }
        shareState = .working("Removing", 0.5)
        let services = services
        Task {
            do {
                try await services.share.unpublish(info, destination: dest, secret: secret)
                var m = manifest
                m.share = nil
                try? bundle.writeManifest(m)
                manifest = m
                shareState = .idle
            } catch {
                shareState = .failed((error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func copyLink() {
        guard let url = shareInfo?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    func openLink() {
        if let s = shareInfo?.url, let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    // MARK: Captions

    var transcriberAvailable: Bool { services.ai.transcriberAvailable }

    func generateCaptions() {
        guard let kind = [TrackKind.microphone, .systemAudio].first(where: { bundle.mediaURL(for: $0, in: manifest) != nil }),
              let audio = bundle.mediaURL(for: kind, in: manifest) else {
            captionState = .failed("This recording has no audio to caption.")
            return
        }
        captionState = .working
        let services = services, bundle = bundle
        let offset = manifest.track(kind)?.startTime ?? 0
        Task {
            do {
                // Transcript times are relative to the audio file; the editor works on the recording's timeline.
                let t = try await services.ai.transcribe(audio: audio, locale: nil).shifted(by: offset)
                let vtt = services.ai.webVTT(t)
                try vtt.write(to: bundle.captionsURL, atomically: true, encoding: .utf8)
                try JSONCoding.writeAtomically(t, to: bundle.transcriptURL)
                transcript = t
                captionState = .idle
                change("Generate Captions") { $0.captions.file = "captions.vtt" }
            } catch {
                captionState = .failed((error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func checkCaptionsAvailability() {
        let ai = services.ai
        Task { captionsUnavailableReason = await ai.captionsUnavailableReason() }
    }

    var storySupported: Bool { services.ai.storySupported }
    var storyUnavailableReason: String? { services.ai.storyUnavailableReason }

    /// Suggests a title and chapters from the transcript with on-device Apple Intelligence.
    /// Chapter times are on the recording's timeline, like the transcript (same as `reelbird suggest`).
    func suggestStory() {
        guard let t = transcript else { return }
        storyState = .working
        let ai = services.ai
        Task {
            do {
                let story = try await ai.suggestStory(transcript: t)
                storyState = .idle
                change("Suggest Title and Chapters") { e in
                    if !story.title.isEmpty { e.title = story.title }
                    e.chapters = story.chapters
                }
            } catch {
                storyState = .failed((error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func clearChapters() { change("Clear Chapters") { $0.chapters = [] } }

    func removeCaptions() {
        change("Remove Captions") { $0.captions.file = nil; $0.captions.burnIn = false }
        transcript = nil
    }

    func setTranscriptForSnapshot(_ t: Transcript) { transcript = t }
}
