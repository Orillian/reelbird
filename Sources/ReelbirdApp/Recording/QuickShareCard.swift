import AppKit
import ReelbirdCore
import ReelbirdRender
import SwiftUI

// MARK: State

/// What the post-stop card shows and does next, as plain values (the self test drives it directly).
struct QuickShareState: Equatable {
    /// The take's link: `live` was uploaded while recording (and copied at stop); `share` means sharing is set
    /// up but this take wasn't uploaded; `setUp` means sharing isn't set up yet.
    enum Link: Equatable { case live(String), share, setUp }
    enum Take: Equatable { case saving, ready, failed }
    /// The quick MP4 behind Copy video and Save.
    enum Video: Equatable { case idle, rendering(Double), ready(URL), failed(String) }
    enum Save: Equatable { case idle, saving, saved(URL), failed(String) }
    /// What the card last put on the pasteboard.
    enum Clipboard: Equatable { case other, link, video }

    var link: Link
    var take: Take = .saving
    var video: Video = .idle
    var save: Save = .idle
    var clipboard: Clipboard
    /// Copy or save once the render finishes.
    var copyWhenRendered = false
    var saveWhenRendered = false

    init(shareURL: String?, shareConfigured: Bool) {
        if let shareURL { link = .live(shareURL); clipboard = .link } else { link = shareConfigured ? .share : .setUp; clipboard = .other }
    }

    // Presentation

    var linkTitle: String {
        guard case .live = link else { return "Share…" }
        return clipboard == .link ? "Link copied" : "Copy link"
    }
    var linkDone: Bool { if case .live = link { clipboard == .link } else { false } }
    var linkHelp: String {
        switch link {
        case .live: "Copy the link again"
        case .share: "Upload this recording and get a link"
        case .setUp: "Set up sharing to your own bucket"
        }
    }

    var videoProgress: Double? { if case .rendering(let p) = video { p } else { nil } }
    var videoTitle: String {
        if let p = videoProgress { return copyWhenRendered ? "\(Int((p * 100).rounded()))%" : "Copy video" }
        if case .failed = video { return "Try again" }
        return clipboard == .video ? "Video copied" : "Copy video"
    }
    var videoDone: Bool { clipboard == .video && !isRendering }

    var saveTitle: String {
        switch save {
        case .idle: "Save"
        case .saving: videoProgress.map { "\(Int(($0 * 100).rounded()))%" } ?? "Saving"
        case .saved: "Show"
        case .failed: "Try again"
        }
    }
    var saveHelp: String {
        if case .saved(let url) = save { return "Show \(url.lastPathComponent) in Finder" }
        return "Save an MP4 to your export folder"
    }

    /// The video actions work once the take is saved.
    var canAct: Bool { take == .ready }
    var isRendering: Bool { videoProgress != nil }
    /// Work is running that the card reports on: it stays up.
    var isBusy: Bool { isRendering || save == .saving }
    /// The countdown to closing runs only while nobody points at the card and nothing is running.
    func autoDismisses(hovered: Bool) -> Bool { !hovered && !isBusy && take != .saving }
    /// A one-line status under the title.
    var errorLine: String? {
        if case .failed(let m) = video { return m }
        if case .failed(let m) = save { return m }
        return take == .failed ? "The recording couldn't be saved." : nil
    }

    // Transitions. Each returns the work to start.

    enum Action: Equatable { case render, copyVideo(URL), saveCopy(URL) }

    mutating func takeFinished(ok: Bool) { take = ok ? .ready : .failed }

    /// The link went (back) on the pasteboard.
    mutating func linkCopied() { clipboard = .link }

    mutating func requestCopyVideo() -> Action? {
        guard canAct else { return nil }
        switch video {
        case .ready(let url): return .copyVideo(url)
        case .rendering: copyWhenRendered = true; return nil
        case .idle, .failed: copyWhenRendered = true; video = .rendering(0); return .render
        }
    }

    mutating func requestSave() -> Action? {
        guard canAct, save != .saving else { return nil }
        switch video {
        case .ready(let url): save = .saving; return .saveCopy(url)
        case .rendering: saveWhenRendered = true; save = .saving; return nil
        case .idle, .failed: saveWhenRendered = true; save = .saving; video = .rendering(0); return .render
        }
    }

    mutating func renderProgress(_ p: Double) {
        if isRendering { video = .rendering(min(1, max(0, p))) }
    }

    mutating func renderFinished(_ url: URL) -> [Action] {
        video = .ready(url)
        var next: [Action] = []
        if saveWhenRendered { next.append(.saveCopy(url)) }
        if copyWhenRendered { next.append(.copyVideo(url)) }
        copyWhenRendered = false
        saveWhenRendered = false
        return next
    }

    mutating func renderFailed(_ message: String) {
        video = .failed(message)
        if saveWhenRendered { save = .failed(message) }
        copyWhenRendered = false
        saveWhenRendered = false
    }

    mutating func renderCancelled() {
        video = .idle
        copyWhenRendered = false
        saveWhenRendered = false
        if save == .saving { save = .idle }
    }

    /// The video went on the pasteboard.
    mutating func videoCopied() { clipboard = .video }
    mutating func saved(_ url: URL) { save = .saved(url) }
    mutating func saveFailed(_ message: String) { save = .failed(message) }
}

// MARK: Model

/// One card's work: renders the quick MP4 (the take as it opens in the editor, H.264, at most 1080p) once
/// for Copy video and Save, and routes Copy link, Share and Edit.
@MainActor @Observable final class QuickShareModel {
    private(set) var state: QuickShareState
    private(set) var bundle: ProjectBundle?
    private(set) var title = "Recording"
    private(set) var duration: Double?
    private(set) var thumbnail: CGImage?

    @ObservationIgnored private let services: Services
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private let saveFolder: () -> URL
    @ObservationIgnored private let cursorDefaults: CursorSettings
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    /// Edit (and double-click), Share… and set-up. The panel closes the card around them.
    @ObservationIgnored var onEdit: ((ProjectBundle) -> Void)?
    @ObservationIgnored var onShare: ((ProjectBundle) -> Void)?
    @ObservationIgnored var onSetUpSharing: (() -> Void)?
    /// Work finished after the card closed: say so in a toast instead.
    @ObservationIgnored var isClosed = false

    init(services: Services, shareURL: String?, shareConfigured: Bool, cursorDefaults: CursorSettings = CursorSettings(),
         pasteboard: NSPasteboard = .general, saveFolder: @escaping () -> URL = QuickShareModel.exportFolder) {
        self.services = services
        self.pasteboard = pasteboard
        self.saveFolder = saveFolder
        self.cursorDefaults = cursorDefaults
        state = QuickShareState(shareURL: shareURL, shareConfigured: shareConfigured)
    }

    /// The export sheet's folder (Downloads unless changed there).
    nonisolated static func exportFolder() -> URL {
        let path = UserDefaults.standard.string(forKey: "exportFolderPath") ?? ""
        return path.isEmpty ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            : URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Snapshots: a card in any state, without a take behind it.
    static func preview(state: QuickShareState, title: String, duration: Double, thumbnail: CGImage?, services: Services) -> QuickShareModel {
        let m = QuickShareModel(services: services, shareURL: nil, shareConfigured: false)
        m.state = state
        m.title = title
        m.duration = duration
        m.thumbnail = thumbnail
        return m
    }

    func takeFinished(_ bundle: ProjectBundle) async {
        self.bundle = bundle
        let manifest = try? bundle.readManifest()
        title = (try? bundle.readEditStamped())?.edit.title ?? manifest?.title ?? title
        duration = manifest.map { EditTimeline(manifest: $0, edit: EditDocument.initial(for: $0)).duration }
        state.takeFinished(ok: manifest != nil)
        let at = min(1.5, (manifest?.duration ?? 0) / 3)
        thumbnail = try? await services.render.poster(bundle: bundle, at: at, maxWidth: 560)
    }

    func takeFailed() { state.takeFinished(ok: false) }

    // MARK: Actions

    func copyLink() {
        switch state.link {
        case .live(let url):
            pasteboard.clearContents()
            pasteboard.setString(url, forType: .string)
            state.linkCopied()
        case .share:
            if let bundle { onShare?(bundle) }
        case .setUp:
            onSetUpSharing?()
        }
    }

    func copyVideo() { run(state.requestCopyVideo()) }

    func save() {
        if case .saved(let url) = state.save {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        run(state.requestSave())
    }

    func edit() { if let bundle { onEdit?(bundle) } }

    /// Stops a render nobody is waiting for any more.
    func cancelIdleWork() {
        if state.isRendering, !state.copyWhenRendered, !state.saveWhenRendered { renderTask?.cancel() }
    }

    private func run(_ action: QuickShareState.Action?) {
        switch action {
        case .render?: startRender()
        case .copyVideo(let url)?: putVideo(url)
        case .saveCopy(let url)?: saveCopy(url)
        case nil: break
        }
    }

    private func startRender() {
        guard let bundle else { return }
        let services = services, cursor = cursorDefaults
        renderTask = Task {
            do {
                let edit = try Self.quickEdit(bundle: bundle, services: services, cursorDefaults: cursor)
                let source = (try? bundle.readManifest())?.capture.pixelSize.height ?? 1080
                let options = ExportOptions(format: .mp4H264, height: source > 1080 ? 1080 : nil)
                let url = try await services.render.export(bundle: bundle, edit: edit, options: options) { p in
                    Task { @MainActor in self.state.renderProgress(p) }
                }
                for next in state.renderFinished(url) { run(next) }
            } catch is CancellationError {
                state.renderCancelled()
            } catch {
                state.renderFailed("Couldn't make the video: \((error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)")
            }
        }
    }

    /// The take as it first opens in the editor: pauses cut, automatic zooms, your cursor defaults.
    static func quickEdit(bundle: ProjectBundle, services: Services, cursorDefaults: CursorSettings) throws -> EditDocument {
        try EditorModel(bundle: bundle, services: services, cursorDefaults: cursorDefaults).edit
    }

    private func putVideo(_ url: URL) {
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        state.videoCopied()
        if isClosed { Toast.show(title: "Video copied", detail: "Paste it into a message or a folder.", symbol: "doc.on.clipboard") }
    }

    private func saveCopy(_ url: URL) {
        do {
            let folder = saveFolder()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = Self.uniqueURL(folder.appendingPathComponent(url.lastPathComponent))
            try FileManager.default.copyItem(at: url, to: dest)
            state.saved(dest)
            if isClosed { Toast.show(title: "Saved to \(FileManager.default.displayName(atPath: folder.path))", detail: dest.lastPathComponent, symbol: "arrow.down.circle") }
        } catch {
            state.saveFailed("Couldn't save: \(error.localizedDescription)")
        }
    }

    /// `name.mp4`, else `name 2.mp4`, `name 3.mp4`, …
    nonisolated static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension, dir = url.deletingLastPathComponent()
        var n = 2
        while true {
            let next = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: next.path) { return next }
            n += 1
        }
    }
}

// MARK: Panel

/// The card in the bottom-left corner after a recording stops. It never takes keyboard focus (you are
/// probably about to paste the link somewhere) and never holds a global shortcut, so other apps keep every key.
/// × closes it; so does Esc while the pointer is on it and Reelbird gets the key (a local monitor: macOS only
/// delivers keys to the app in front). It closes by itself after `lifetime` seconds unless the pointer is on it
/// or a render is running.
@MainActor final class QuickSharePanel {
    static let lifetime: Double = 12
    /// After the pointer leaves, the card stays at least this long.
    static let afterHover: Double = 5
    static let width: CGFloat = 316
    /// The card plus room for its shadow and a status line (transparent, click-through, where empty).
    static let size = NSSize(width: width + 40, height: 400)

    let model: QuickShareModel
    private let panel: FloatingPanel
    private var hovered = false
    private var deadline = Date.distantFuture
    private var timer: Timer?
    private var escMonitor: Any?
    var onClosed: (() -> Void)?

    init(model: QuickShareModel) {
        self.model = model
        panel = FloatingPanel(size: Self.size, level: .statusBar, allowsKey: false)
        let view = QuickShareCardView(model: model,
                                      onHover: { [weak self] h in self?.setHovered(h) },
                                      onClose: { [weak self] in self?.close() })
            .padding(20) // room for the shadow
            .frame(width: Self.size.width, height: Self.size.height, alignment: .bottomLeading)
            .environment(\.isSnapshot, false)
        panel.contentView = FirstMouseHostingView(rootView: view)
        panel.setContentSize(Self.size)
    }

    func present() {
        let screen = NSScreen.withMouse.visibleFrame
        let size = Self.size
        let origin = NSPoint(x: screen.minX + 16 - 20, y: screen.minY + 16 - 20)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrameOrigin(reduceMotion ? origin : NSPoint(x: origin.x - 24, y: origin.y))
        panel.fadeIn()
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.32
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                panel.animator().setFrame(NSRect(origin: origin, size: size), display: true)
            }
        }
        deadline = Date().addingTimeInterval(Self.lifetime)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        let link = model.state.linkDone ? "Link copied. " : ""
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Recording saved. \(link)Quick actions in the bottom-left corner.",
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private func setHovered(_ h: Bool) {
        hovered = h
        if !h { deadline = max(deadline, Date().addingTimeInterval(Self.afterHover)) }
        if h, escMonitor == nil {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event }
                let closed = MainActor.assumeIsolated { () -> Bool in
                    guard let self, self.hovered else { return false }
                    self.close()
                    return true
                }
                return closed ? nil : event
            }
        } else if !h {
            removeEscMonitor()
        }
    }

    private func removeEscMonitor() {
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
    }

    private func tick() {
        guard model.state.autoDismisses(hovered: hovered) else {
            deadline = max(deadline, Date().addingTimeInterval(Self.afterHover))
            return
        }
        if Date() >= deadline { close() }
    }

    func close() {
        guard !model.isClosed else { return }
        model.isClosed = true
        model.cancelIdleWork()
        timer?.invalidate()
        timer = nil
        removeEscMonitor()
        panel.fadeOut()
        onClosed?()
    }
}

// MARK: View

struct QuickShareCardView: View {
    let model: QuickShareModel
    var onHover: (Bool) -> Void = { _ in }
    var onClose: () -> Void = {}
    @Environment(\.isSnapshot) private var snapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: QuickShareState { model.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            preview
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let d = model.duration {
                    Text(TimeFormat.clock(d)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 2)
            if let line = state.errorLine {
                StatusLine(tone: .warning, text: line)
            }
            HStack(spacing: 6) {
                QuickTile(symbol: state.linkDone ? "checkmark" : "link", title: state.linkTitle, done: state.linkDone,
                          help: state.linkHelp, action: model.copyLink)
                    .disabled(state.link == .share && !state.canAct)
                QuickTile(symbol: state.videoDone ? "checkmark" : "doc.on.clipboard", title: state.videoTitle, done: state.videoDone,
                          progress: state.copyWhenRendered ? state.videoProgress : nil,
                          help: "Copy an MP4 to paste into Slack, Messages or Finder", action: model.copyVideo)
                    .disabled(!state.canAct)
                QuickTile(symbol: saveSymbol, title: state.saveTitle, done: false,
                          progress: state.save == .saving ? (state.videoProgress ?? 1) : nil,
                          help: state.saveHelp, action: model.save)
                    .disabled(!state.canAct)
                QuickTile(symbol: "slider.horizontal.3", title: "Edit", done: false, help: "Open in the editor", action: model.edit)
                    .disabled(!state.canAct)
            }
        }
        .padding(10)
        .frame(width: QuickSharePanel.width)
        .floatingSurface(cornerRadius: 16, snapshot: snapshot)
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(CloseChipStyle())
                .padding(16)
                .help("Close")
                .accessibilityLabel("Close quick actions")
        }
        .onHover(perform: onHover)
        .animation(reduceMotion ? nil : Theme.snappy, value: state)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick actions for \(model.title)")
    }

    private var saveSymbol: String {
        if case .saved = state.save { return "folder" }
        return "arrow.down.to.line"
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06))
            if let img = model.thumbnail {
                Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else if state.take == .saving {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Saving your recording…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "film").font(.system(size: 22)).foregroundStyle(.tertiary)
            }
        }
        .frame(height: (QuickSharePanel.width - 20) * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.edit() }
        .help(state.canAct ? "Double-click to edit" : "")
        .accessibilityHidden(true)
    }
}

/// One action: an icon over a short label. `done` shows a check in the accent colour; `progress` a ring.
private struct QuickTile: View {
    let symbol: String
    let title: String
    var done = false
    var progress: Double?
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    if let progress {
                        Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2)
                        Circle().trim(from: 0, to: max(0.03, progress))
                            .stroke(Color.primary.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(done ? Theme.accentText : Color.primary.opacity(0.85))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 18, height: 18)
                Text(title)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(done ? Theme.accentText : Color.primary.opacity(0.85))
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(hovering && isEnabled ? 0.1 : 0.055)))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(title)
        .accessibilityValue(progress.map { "\(Int(($0 * 100).rounded())) percent" } ?? "")
    }
}

/// The small round close button over the card's corner.
private struct CloseChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color.black.opacity(configuration.isPressed ? 0.7 : 0.5)))
            .contentShape(Circle())
    }
}
