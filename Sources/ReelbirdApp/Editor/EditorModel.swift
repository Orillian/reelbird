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
    /// When the running export started, for the time-left estimate.
    private(set) var exportStartedAt: Date?
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
    /// The voice's measured loudness, for auto level. `nil` until measured (or with no microphone).
    private(set) var audioAnalysis: AudioAnalysis?
    private(set) var isMeasuringVoice = false
    /// Progress (0…1) of the voice stem render, `nil` when none is running.
    private(set) var voiceStemProgress: Double?
    private(set) var voiceStemError: String?
    /// True while "Hear original" is held.
    private(set) var isHearingOriginal = false
    /// The browser toolbar found in the screen video, once looked for (`nil` while looking or unreadable).
    private(set) var cropSuggestion: CropSuggestion?
    private(set) var isDetectingToolbar = false
    /// Crop mode: the crop being drawn on the preview (full-screen coordinates). `nil` when not cropping.
    private(set) var cropDraft: NormRect?

    @ObservationIgnored let undoManager = UndoManager()
    /// Off in snapshots so scenes don't write into the shared demo bundle.
    @ObservationIgnored var autosaveEnabled = true
    private(set) var player: (any PreviewPlayerHandle)?
    @ObservationIgnored private let services: Services
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var shareTask: Task<Void, Never>?
    @ObservationIgnored private var stemTask: Task<Void, Never>?
    /// The enhance settings the stem was last checked for (enhance, strength, mix).
    @ObservationIgnored private var stemKey: String?
    @ObservationIgnored private var coalesceKey: String?
    @ObservationIgnored private var coalesceUntil = Date.distantPast
    /// `edit.json` as this editor last read or wrote it: the base for merging someone else's changes.
    @ObservationIgnored private var savedEdit: EditDocument
    /// Its `revision` (0 = no file yet).
    @ObservationIgnored private var savedRevision: Int
    /// Changes made here that aren't in `edit.json` yet. Closing writes only when this is set, so an
    /// editor that changed nothing never overwrites a `reelbird edit` / `set_edit` made meanwhile.
    @ObservationIgnored private(set) var isDirty = false
    @ObservationIgnored private var saving = false
    @ObservationIgnored private var watcher: (any DispatchSourceFileSystemObject)?
    @ObservationIgnored private var watchDebounce: Task<Void, Never>?

    /// `cursorDefaults` apply only to a recording opened for the first time (no edit.json yet).
    init(bundle: ProjectBundle, services: Services, cursorDefaults: CursorSettings? = nil) throws {
        self.bundle = bundle
        self.services = services
        let manifest = try bundle.readManifest()
        let events = (try? bundle.readEvents()) ?? []
        let fresh = !FileManager.default.fileExists(atPath: bundle.editURL.path)
        let stamped = (try? bundle.readEditStamped()) ?? (edit: EditDocument.initial(for: manifest), revision: 0)
        savedEdit = stamped.edit
        savedRevision = fresh ? 0 : stamped.revision
        var edit = stamped.edit
        if fresh, let cursorDefaults { edit.cursor = cursorDefaults }
        if edit.title == nil { edit.title = manifest.title }
        if edit.zoom.mode == .auto && !edit.zoom.regions.contains(where: { $0.source == .auto }) {
            edit.zoom.regions += services.render.autoZoomPlan(events: events, duration: manifest.duration, intensity: edit.zoom.intensity,
                                                              crop: edit.crop)
        }
        self.manifest = manifest
        self.events = events
        self.edit = edit
        // Defaults filled in on open (first-time cursor, title, auto zooms) are saved like any change.
        isDirty = fresh || edit != stamped.edit
        transcript = Self.loadTranscript(bundle: bundle, edit: edit)
    }

    deinit { watcher?.cancel() }

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
        startWatchingEdits()
        do {
            let p = try services.render.makePreviewPlayer(bundle: bundle)
            p.onTimeChange = { [weak self] output in self?.playerTimeChanged(output) }
            p.onReady = { [weak self] error in
                if let error { self?.previewError = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription }
            }
            p.update(edit: previewEdit)
            player = p
        } catch {
            previewError = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        loadTimelineMedia()
    }

    func loadTimelineMedia() {
        detectToolbar()
        if hasMicrophone, audioAnalysis == nil, !isMeasuringVoice {
            isMeasuringVoice = true
            let settings = edit.audio
            Task {
                audioAnalysis = await services.render.audioAnalysis(bundle: bundle, settings: settings)
                isMeasuringVoice = false
            }
        }
        updateVoiceStem(debounce: false)
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
    func setAudioAnalysisForSnapshot(_ a: AudioAnalysis?) { audioAnalysis = a; isMeasuringVoice = false }

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
    /// Gain auto level applies to the voice right now, in dB (`nil` when off or not measured yet).
    var autoLevelGainDB: Double? { edit.audio.autoLevelGainDB(audioAnalysis) }
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
        // Undoing Remove Captions brings the captions file back; bring its transcript back with it.
        let captionsChanged = doc.captions.file != edit.captions.file
        edit = doc
        if captionsChanged { transcript = doc.captions.file == nil ? nil : Self.loadTranscript(bundle: bundle, edit: doc) }
        if case .zoom(let id) = selection, !doc.zoom.regions.contains(where: { $0.id == id }) { selection = nil }
        editDidChange()
    }

    private func editDidChange() {
        isDirty = true
        player?.update(edit: previewEdit)
        clampPlayhead()
        scheduleSave()
        updateVoiceStem(debounce: true)
    }

    // MARK: Voice stem

    private static func stemKey(_ a: AudioSettings) -> String {
        "\(a.enhance)|\(a.enhanceStrength.rawValue)|\(VoiceStemInfo.quantizedMix(a.enhanceMix))"
    }

    /// Renders the enhanced voice when it's missing or doesn't match the settings (the preview keeps playing the
    /// previous voice meanwhile and switches when it's ready). Slider drags settle for a moment first; a newer
    /// change cancels a running render.
    func updateVoiceStem(debounce: Bool) {
        guard hasMicrophone, player != nil else { return }
        let key = Self.stemKey(edit.audio)
        guard key != stemKey else { return }
        let enhanceChanged = stemKey.map { $0.hasPrefix("\(!edit.audio.enhance)|") } ?? false
        stemKey = key
        stemTask?.cancel()
        voiceStemError = nil
        let settings = edit.audio, services = services, bundle = bundle
        if enhanceChanged { refreshAudioAnalysis() }
        guard settings.enhance, services.render.voiceStemStatus(bundle: bundle, settings: settings) != .ready else {
            voiceStemProgress = nil
            if settings.enhance { player?.voiceStemDidChange(); refreshAudioAnalysis() }
            return
        }
        stemTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled, let self else { return }
            self.voiceStemProgress = 0
            do {
                try await services.render.renderVoiceStem(bundle: bundle, settings: settings) { [weak self] p in
                    Task { @MainActor [weak self] in
                        guard let self, self.voiceStemProgress != nil, !Task.isCancelled else { return }
                        self.voiceStemProgress = max(self.voiceStemProgress ?? 0, p)
                    }
                }
                guard !Task.isCancelled else { return }
                self.voiceStemProgress = nil
                self.player?.voiceStemDidChange()
                self.refreshAudioAnalysis()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.voiceStemProgress = nil
                self.voiceStemError = "Couldn't enhance the voice: \((error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)"
                // Let the next settings change try again.
                self.stemKey = nil
            }
        }
    }

    /// Re-measures the voice that now plays (auto level status).
    private func refreshAudioAnalysis() {
        let settings = edit.audio, services = services, bundle = bundle
        Task { [weak self] in
            let a = await services.render.audioAnalysis(bundle: bundle, settings: settings)
            self?.audioAnalysis = a
        }
    }

    /// Press-and-hold "Hear original": the raw microphone plays instead of the enhanced voice.
    func setHearOriginal(_ on: Bool) {
        guard on != isHearingOriginal else { return }
        isHearingOriginal = on
        player?.setHearOriginal(on)
    }

    func setVoiceStemProgressForSnapshot(_ p: Double?) { voiceStemProgress = p }

    func setTitle(_ t: String) {
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        change("Rename") { $0.title = trimmed.isEmpty ? nil : trimmed }
    }

    // Zoom

    func setZoomMode(_ mode: ZoomSettings.Mode) {
        change("Zoom Mode") { e in
            e.zoom.mode = mode
            if mode == .auto && !e.zoom.regions.contains(where: { $0.source == .auto }) {
                e.zoom.regions += services.render.autoZoomPlan(events: events, duration: duration, intensity: e.zoom.intensity, crop: e.crop)
            }
        }
    }

    func setZoomIntensity(_ v: Double) {
        change("Zoom Intensity", coalesce: "zoomIntensity") { e in
            e.zoom.intensity = v
            e.zoom.regions.removeAll { $0.source == .auto }
            e.zoom.regions += services.render.autoZoomPlan(events: events, duration: duration, intensity: v, crop: e.crop)
            e.zoom.regions.sort { $0.range.start < $1.range.start }
        }
    }

    func resetAutoZooms() {
        change("Reset Zooms") { e in
            e.zoom.regions.removeAll()
            e.zoom.regions = services.render.autoZoomPlan(events: events, duration: duration, intensity: e.zoom.intensity, crop: e.crop)
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

    // Crop

    /// The app name when this is a recording of a browser window.
    var browserName: String? { manifest.capture.source.browserAppName }
    /// Size of the screen video in pixels.
    var screenPixelSize: PixelSize { manifest.track(.screen)?.pixelSize ?? manifest.capture.pixelSize }
    /// The crop that hides the detected toolbar, when one was found with good confidence.
    var toolbarCrop: NormRect? { cropSuggestion?.isConfident == true ? cropSuggestion?.crop : nil }
    var isToolbarHidden: Bool { edit.crop != nil && edit.crop == toolbarCrop }
    var isCropping: Bool { cropDraft != nil }

    /// Looks for a browser toolbar in the screen video (once; the result is cached in the bundle).
    func detectToolbar() {
        guard cropSuggestion == nil, !isDetectingToolbar else { return }
        isDetectingToolbar = true
        let services = services, bundle = bundle
        Task { [weak self] in
            let s = await services.render.cropSuggestion(bundle: bundle)
            self?.cropSuggestion = s
            self?.isDetectingToolbar = false
        }
    }

    func setCropSuggestionForSnapshot(_ s: CropSuggestion?) { cropSuggestion = s; isDetectingToolbar = false }

    /// Sets the crop with undo. Automatic zooms are planned again inside it.
    func setCrop(_ crop: NormRect?, actionName: String) {
        change(actionName) { e in
            e.crop = crop?.sanitizedCrop
            if e.zoom.mode == .auto {
                e.zoom.regions.removeAll { $0.source == .auto }
                e.zoom.regions += services.render.autoZoomPlan(events: events, duration: duration, intensity: e.zoom.intensity, crop: e.crop)
                e.zoom.regions.sort { $0.range.start < $1.range.start }
            }
        }
    }

    func hideBrowserToolbar() {
        guard let crop = toolbarCrop else { return }
        if isCropping { cropDraft = crop; return }
        setCrop(crop, actionName: "Hide Browser Toolbar")
    }

    func resetCrop() {
        if isCropping { cropDraft = .full; return }
        setCrop(nil, actionName: "Reset Crop")
    }

    /// Enters crop mode: the preview shows the whole screen with handles to drag.
    func beginCrop() {
        guard !isCropping else { return }
        pause()
        cropDraft = edit.crop ?? .full
        player?.update(edit: previewEdit)
    }

    func updateCropDraft(_ r: NormRect) {
        guard isCropping else { return }
        cropDraft = r
    }

    /// Leaves crop mode keeping the drawn crop (one undo step).
    func commitCrop() {
        guard let draft = cropDraft else { return }
        cropDraft = nil
        let next = draft.sanitizedCrop
        if next != edit.crop { setCrop(next, actionName: "Crop") } else { player?.update(edit: previewEdit) }
    }

    /// Leaves crop mode without changing the crop.
    func cancelCrop() {
        guard isCropping else { return }
        cropDraft = nil
        player?.update(edit: previewEdit)
    }

    /// What the preview draws: the edit, or in crop mode the whole uncropped screen without background,
    /// zoom, cursor or overlays, so the crop handles sit on the full frame.
    var previewEdit: EditDocument {
        guard isCropping else { return edit }
        var e = edit
        e.crop = nil
        e.zoom.mode = .off
        e.background.kind = .none
        e.background.motionBlur = false
        e.camera.visible = false
        e.cursor.visible = false
        e.cursor.showKeystrokes = false
        e.captions.burnIn = false
        e.annotations = []
        e.canvas.aspect = .source
        return e
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

    /// Finds long pauses in the microphone track (decoding it off the main thread) and cuts them.
    func removeSilences() {
        guard let mic = bundle.mediaURL(for: .microphone, in: manifest) else {
            Toast.show(title: "No microphone track", detail: "This recording has no voice to find silences in.", symbol: "waveform")
            return
        }
        let ai = services.ai
        let offset = manifest.track(.microphone)?.startTime ?? 0
        let duration = duration
        Task {
            let silences = await Task.detached(priority: .userInitiated) { try? ai.silentRanges(audio: mic) }.value
            guard let silences else {
                Toast.show(title: "Couldn't read the microphone track", symbol: "exclamationmark.triangle.fill")
                return
            }
            let shifted = silences.map { TimeRange(start: $0.start + offset, end: $0.end + offset) }
            // Keep a little air next to speech, like `reelbird silences --apply`.
            let cuts = SilenceDetector.trimCuts(silences: shifted, duration: duration)
            guard !cuts.isEmpty else {
                Toast.show(title: "No long silences", detail: "There was nothing to cut.", symbol: "waveform")
                return
            }
            change("Remove Silences") { e in e.cuts = Self.merged(e.cuts + cuts) }
        }
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
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.saveInBackground()
        }
    }

    /// Autosave: merges in any change made outside the editor, then writes off the main thread (a full
    /// flush takes a few milliseconds) only if `edit.json` is still at the revision it merged with.
    private func saveInBackground() async {
        guard isDirty, !saving else { return }
        mergeExternalEdits()
        guard isDirty else { return }
        let doc = edit, expected = savedRevision, bundle = bundle
        saving = true
        let result = await Task.detached { () -> Result<Int, any Error> in
            Result { try bundle.writeEdit(doc, ifRevision: expected) }
        }.value
        saving = false
        switch result {
        case .success(let revision):
            didSave(doc, revision: revision)
            if edit != doc { scheduleSave() }   // changed again while writing
        case .failure(is EditConflict):
            scheduleSave()                      // someone wrote in between: merge and try again
        case .failure(let error):
            saveError = "Edits couldn't be saved: \(error.localizedDescription)"
        }
    }

    /// Saves now (closing the window, quitting, before sharing). Writes nothing when nothing changed here,
    /// so edits made meanwhile with `reelbird edit` or MCP `set_edit` survive; merges them in otherwise.
    func saveNow() {
        saveTask?.cancel()
        for _ in 0..<3 {
            mergeExternalEdits()
            guard isDirty else { return }
            do {
                didSave(edit, revision: try bundle.writeEdit(edit, ifRevision: savedRevision))
                return
            } catch is EditConflict {
                continue
            } catch {
                saveError = "Edits couldn't be saved: \(error.localizedDescription)"
                return
            }
        }
    }

    private func didSave(_ doc: EditDocument, revision: Int) {
        savedEdit = doc
        savedRevision = revision
        saveError = nil
        if edit == doc { isDirty = false }
    }

    // MARK: Outside edits

    func stopWatchingEdits() {
        watchDebounce?.cancel()
        watcher?.cancel()
        watcher = nil
    }

    /// Watches the bundle folder (edit.json is replaced by a rename, which changes the folder) and picks
    /// up edits made by the CLI or an agent while the editor is open.
    private func startWatchingEdits() {
        guard watcher == nil else { return }
        let fd = open(bundle.url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.watchDebounce?.cancel()
                self.watchDebounce = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    self?.checkForExternalEdits()
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    /// Picks up a change someone else made to `edit.json`: applied directly when nothing here is
    /// unsaved, merged with the unsaved changes otherwise. Undo goes back to the version before it.
    func checkForExternalEdits() {
        guard !saving, bundle.readEditRevision() != savedRevision else { return }
        let wasDirty = isDirty
        mergeExternalEdits()
        if !wasDirty {
            Toast.show(title: "Edits updated", detail: "This recording was changed outside the editor.", symbol: "arrow.triangle.2.circlepath")
        }
    }

    /// Brings `edit.json` changes made since `savedRevision` into the editor (3-way merge against
    /// `savedEdit`). Where both sides changed the same setting, the editor's choice stays and the other
    /// version is kept next to edit.json (`edit.outside-<time>.json`) with a toast saying so.
    private func mergeExternalEdits() {
        guard let (theirs, revision) = try? bundle.readEditStamped(), revision != savedRevision else { return }
        let merged = EditMerge.merge(base: savedEdit, ours: edit, theirs: theirs)
        if !merged.conflicts.isEmpty, let kept = keepOutsideVersion(theirs) {
            Toast.show(title: "Edits made outside the editor clashed with yours",
                       detail: "Yours were kept (\(merged.conflicts.prefix(3).joined(separator: ", "))). The other version is saved as \(kept).",
                       symbol: "exclamationmark.triangle.fill", duration: 8)
        }
        let unsaved = merged.edit != theirs
        savedEdit = theirs
        savedRevision = revision
        if merged.edit != edit {
            registerUndo(previous: edit, actionName: "Outside Edit")
            coalesceKey = nil
            let captionsChanged = merged.edit.captions.file != edit.captions.file
            edit = merged.edit
            if captionsChanged { transcript = Self.loadTranscript(bundle: bundle, edit: merged.edit) }
            player?.update(edit: previewEdit)
            clampPlayhead()
            updateVoiceStem(debounce: true)
        }
        isDirty = unsaved
        if unsaved { scheduleSave() }
    }

    private func keepOutsideVersion(_ doc: EditDocument) -> String? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let name = "edit.outside-\(f.string(from: Date())).json"
        do {
            try JSONCoding.writeAtomically(doc, to: bundle.url.appendingPathComponent(name), sync: .full)
            return name
        } catch {
            return nil
        }
    }

    // MARK: Export

    /// True while an export or a link upload is running (closing or quitting asks first).
    var isBusy: Bool {
        if case .running = exportState { return true }
        return shareState.isWorking
    }

    /// Stops a running export or upload. The recording and its edits are untouched.
    /// "About 20 s left", once there's enough progress to estimate from.
    func exportTimeLeft(progress p: Double, now: Date = Date()) -> String? {
        guard let start = exportStartedAt, p > 0.04, p < 1 else { return nil }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed > 1.5 else { return nil }
        let left = elapsed * (1 - p) / p
        if left < 5 { return "Almost done" }
        if left < 60 { return "About \(Int((left / 5).rounded(.up)) * 5) s left" }
        return "About \(Int((left / 60).rounded(.up))) min left"
    }

    func cancelWork() {
        exportTask?.cancel(); exportTask = nil
        shareTask?.cancel(); shareTask = nil
        if case .running = exportState { exportState = .idle }
        if shareState.isWorking { shareState = .idle }
    }

    func export(_ options: ExportOptions) {
        exportState = .running(0)
        exportStartedAt = Date()
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
