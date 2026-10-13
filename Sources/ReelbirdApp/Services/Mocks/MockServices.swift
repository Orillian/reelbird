import AppKit
import Foundation
import ReelbirdAI
import ReelbirdCapture
import ReelbirdCore
import ReelbirdRender

// Simulated engine for snapshots, `--selftest` and `--mock`. Behaviour is deliberately
// realistic (timing, progress, warnings) so the UI can be exercised without permissions.

struct MockCaptureSources: CaptureSourceService {
    func list() async throws -> [AvailableSource] {
        try await Task.sleep(for: .milliseconds(120))
        return Self.sources(withThumbnails: true)
    }

    static func sources(withThumbnails: Bool) -> [AvailableSource] {
        func thumb(_ w: Int, _ h: Int, _ v: MockArt.Variant, dark: Bool = false) -> CGImage? {
            withThumbnails ? MockArt.image(width: w, height: h, variant: v, dark: dark) : nil
        }
        return [
            AvailableSource(id: "display-1", kind: .display, title: "Built-in Retina Display", appName: nil,
                            pixelSize: PixelSize(width: 3456, height: 2234), frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                            source: .display(id: 1, name: "Built-in Retina Display"), thumbnail: thumb(480, 310, .docs)),
            AvailableSource(id: "display-2", kind: .display, title: "Studio Display", appName: nil,
                            pixelSize: PixelSize(width: 5120, height: 2880), frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                            source: .display(id: 2, name: "Studio Display"), thumbnail: thumb(480, 270, .code, dark: true)),
            AvailableSource(id: "win-101", kind: .window, title: "Pull request #482 — Checkout flow", appName: "Safari",
                            pixelSize: PixelSize(width: 2880, height: 1800), frame: CGRect(x: 80, y: 60, width: 1440, height: 900),
                            source: .window(id: 101, app: "Safari", title: "Pull request #482"), thumbnail: thumb(320, 200, .browser), bundleID: "com.apple.Safari"),
            AvailableSource(id: "win-102", kind: .window, title: "CheckoutView.swift", appName: "Xcode",
                            pixelSize: PixelSize(width: 3024, height: 1890), frame: CGRect(x: 80, y: 60, width: 1512, height: 945),
                            source: .window(id: 102, app: "Xcode", title: "CheckoutView.swift"), thumbnail: thumb(320, 200, .code, dark: true), bundleID: "com.apple.dt.Xcode"),
            AvailableSource(id: "win-103", kind: .window, title: "Onboarding v3", appName: "Figma",
                            pixelSize: PixelSize(width: 2560, height: 1600), frame: CGRect(x: 80, y: 60, width: 1280, height: 800),
                            source: .window(id: 103, app: "Figma", title: "Onboarding v3"), thumbnail: thumb(320, 200, .design), bundleID: "com.figma.Desktop"),
            AvailableSource(id: "win-104", kind: .window, title: "Q4 launch plan", appName: "Notion",
                            pixelSize: PixelSize(width: 2400, height: 1560), frame: CGRect(x: 80, y: 60, width: 1200, height: 780),
                            source: .window(id: 104, app: "Notion", title: "Q4 launch plan"), thumbnail: thumb(320, 208, .docs), bundleID: "notion.id"),
            AvailableSource(id: "win-105", kind: .window, title: "#design-review", appName: "Slack",
                            pixelSize: PixelSize(width: 2200, height: 1500), frame: CGRect(x: 80, y: 60, width: 1100, height: 750),
                            source: .window(id: 105, app: "Slack", title: "#design-review"), thumbnail: thumb(320, 218, .chat, dark: true), bundleID: "com.tinyspeck.slackmacgap"),
            AvailableSource(id: "win-106", kind: .window, title: "Terminal — zsh", appName: "Terminal",
                            pixelSize: PixelSize(width: 1800, height: 1100), frame: CGRect(x: 80, y: 60, width: 900, height: 550),
                            source: .window(id: 106, app: "Terminal", title: "zsh"), thumbnail: thumb(320, 196, .code, dark: true), bundleID: "com.apple.Terminal"),
        ] + offScreenWindows
    }

    /// Windows on other desktops or minimized (no thumbnails: they can't be captured), grouped by app
    /// as `CaptureSources.arrange` orders them. Apps every Mac has, so snapshots show real icons.
    static let offScreenWindows: [AvailableSource] = [
        ("win-201", "Mail", "com.apple.mail", "Inbox — 3 unread", CGSize(width: 1280, height: 820)),
        ("win-202", "Notes", "com.apple.Notes", "Demo script", CGSize(width: 900, height: 640)),
        ("win-203", "Preview", "com.apple.Preview", "Invoice-0193.pdf", CGSize(width: 820, height: 1060)),
        ("win-204", "Safari", "com.apple.Safari", "Release notes 2.4", CGSize(width: 1440, height: 900)),
    ].enumerated().map { i, w in
        AvailableSource(id: w.0, kind: .window, title: w.3, appName: w.1,
                        pixelSize: PixelSize(width: Int(w.4.width) * 2, height: Int(w.4.height) * 2),
                        frame: CGRect(origin: CGPoint(x: 120, y: 90), size: w.4),
                        source: .window(id: CGWindowID(201 + i), app: w.1, title: w.3),
                        isOnScreen: false, bundleID: w.2)
    }

    /// Off-screen windows `bringOnScreen` fails for in mocks (a minimized window that stays put).
    static let stuckOffScreen: Set<String> = ["win-203"]

    func thumbnail(for source: AvailableSource, maxPixelWidth: Int) async -> CGImage? { source.isOnScreen ? source.thumbnail : nil }

    func bringOnScreen(_ source: AvailableSource) async -> Bool {
        guard !source.isOnScreen else { return true }
        try? await Task.sleep(for: .milliseconds(150))
        return !Self.stuckOffScreen.contains(source.id)
    }

    func microphones() -> [MediaDevice] {
        [MediaDevice(id: "builtin-mic", name: "MacBook Pro Microphone", isDefault: true, transport: .builtIn, sampleRate: 48_000),
         MediaDevice(id: "airpods", name: "AirPods Pro", isDefault: false, transport: .bluetooth, sampleRate: 24_000),
         MediaDevice(id: "iphone-mic", name: "iPhone Microphone", isDefault: false, transport: .continuity, sampleRate: 48_000),
         MediaDevice(id: "zoom", name: "ZoomAudioDevice", isDefault: false, transport: .virtual, sampleRate: 48_000)]
    }

    func cameras() -> [MediaDevice] {
        [MediaDevice(id: "facetime", name: "FaceTime HD Camera", isDefault: true),
         MediaDevice(id: "continuity", name: "iPhone Camera", isDefault: false)]
    }

    func inputVolume(deviceID: String) -> Float? { deviceID == "shure-mv7" ? nil : 0.7 }
    func setInputVolume(_ volume: Float, deviceID: String) {}
}

struct MockRecorder: RecorderService {
    func makeSession(options: RecordingOptions, bundleURL: URL, shareSink: (any ShareSegmentSink)?) throws -> any RecordingSessionHandle {
        MockRecordingSession(options: options, bundleURL: bundleURL, shareSink: shareSink)
    }
    func needsRecovery(_ bundle: ProjectBundle) -> Bool { (try? bundle.readManifest())?.status == .recording }
    func recoverIfNeeded(_ bundle: ProjectBundle, waitForLock: Bool) throws -> Bool {
        guard var m = try? bundle.readManifest(), m.status == .recording else { return false }
        m.status = .recovered
        try bundle.writeManifest(m)
        return true
    }
}

/// Simulates a recording: ticks the clock, wobbles the mic level, raises a silent-mic warning
/// for a few seconds, writes a real bundle (manifest, events, edit) on stop.
final class MockRecordingSession: RecordingSessionHandle, @unchecked Sendable {
    private let options: RecordingOptions
    private let bundleURL: URL
    private let shareSink: (any ShareSegmentSink)?
    private let lock = NSLock()
    private var current = RecorderStatus()
    private var continuations: [UUID: AsyncStream<RecorderStatus>.Continuation] = [:]
    private var ticker: Task<Void, Never>?
    private var startDate = Date()
    private var pausedTotal = 0.0
    private var pauseStart: Date?
    private var pauses: [TimeRange] = []
    private var shareInfo: ShareInfo?
    private var levels = MicLevelReading()
    private var summary: MicTakeSummary?
    /// Seconds of the simulated silent stretch (9–15 s) that were recorded.
    private var silentSeconds = 0.0

    init(options: RecordingOptions, bundleURL: URL, shareSink: (any ShareSegmentSink)?) {
        self.options = options; self.bundleURL = bundleURL; self.shareSink = shareSink
    }

    var status: AsyncStream<RecorderStatus> {
        AsyncStream { c in
            let id = UUID()
            lock.withLock { continuations[id] = c; c.yield(current) }
            c.onTermination = { [weak self] _ in self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) } }
        }
    }

    private func publish(_ change: (inout RecorderStatus) -> Void) {
        let (s, cs) = lock.withLock { () -> (RecorderStatus, [AsyncStream<RecorderStatus>.Continuation]) in
            change(&current); return (current, Array(continuations.values))
        }
        for c in cs { c.yield(s) }
    }

    private var elapsed: Double {
        lock.withLock {
            let paused = pausedTotal + (pauseStart.map { Date().timeIntervalSince($0) } ?? 0)
            return Date().timeIntervalSince(startDate) - paused
        }
    }

    func start() async throws {
        _ = try ProjectBundle.create(at: bundleURL)
        if let sink = shareSink {
            let info = try await sink.begin(recordingID: ShortID.make(), title: "Recording")
            lock.withLock { shareInfo = info }
            publish { $0.shareURL = info.url }
        }
        lock.withLock { startDate = Date() }
        publish { $0.phase = .recording }
        ticker = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                tick += 1
                let paused = self.lock.withLock { self.pauseStart != nil }
                let e = self.elapsed
                let hasMic = self.options.microphoneID != nil
                let silent = hasMic && e > 9 && e < 15
                let speech = 0.5 + 0.5 * sin(Double(tick) * 0.37) * sin(Double(tick) * 0.11)
                let level = paused || !hasMic || silent ? 0 : max(0.05, min(1, speech * 0.85 + Double.random(in: 0...0.15)))
                // Speech peaks sit ~12 dB above the RMS meter value, mostly inside the target zone.
                let peakDB = level > 0 ? min(-1, -60 + level * 60 + 4) : MicLevelReading.floorDB
                self.lock.withLock {
                    self.levels = MicLevelReading(peakDB: peakDB, rmsDB: level > 0 ? -60 + level * 60 - 8 : MicLevelReading.floorDB)
                    if silent && !paused { self.silentSeconds += 0.05 }
                }
                let backlog = self.shareSink == nil ? 0 : (tick % 40 < 6 ? 2 : 0)
                self.publish { s in
                    s.elapsed = e
                    s.microphoneLevel = level
                    s.uploadBacklog = backlog
                    var w: [HealthWarning] = []
                    if silent { w.append(HealthWarning(kind: .microphoneSilent, message: "Your mic is silent. Is it muted?", since: 9)) }
                    s.warnings = w
                }
            }
        }
    }

    func pause() async {
        lock.withLock { if pauseStart == nil { pauseStart = Date() } }
        publish { $0.phase = .paused; $0.microphoneLevel = 0 }
    }

    func resume() async {
        let e = elapsed
        lock.withLock {
            if let p = pauseStart {
                let d = Date().timeIntervalSince(p)
                let startOnTimeline = Date().timeIntervalSince(startDate) - d
                pauses.append(TimeRange(start: startOnTimeline, end: startOnTimeline + d))
                pausedTotal += d
                pauseStart = nil
            }
        }
        publish { $0.phase = .recording; $0.elapsed = e }
    }

    func stop() async throws -> ProjectBundle {
        if lock.withLock({ pauseStart != nil }) { await resume() }
        ticker?.cancel()
        publish { $0.phase = .finishing }
        let duration = max(4, Date().timeIntervalSince(lock.withLock { startDate }))
        if options.microphoneID != nil {
            let active = elapsed
            lock.withLock { summary = MicTakeSummary(activeSeconds: active, soundSeconds: max(0, active - silentSeconds)) }
        }
        let bundle = ProjectBundle(url: bundleURL)
        let pixel: PixelSize
        switch options.source {
        case .area(_, _, _, let w, let h): pixel = PixelSize(width: Int(w * 2), height: Int(h * 2))
        default: pixel = PixelSize(width: 3456, height: 2234)
        }
        var tracks = [TrackInfo(kind: .screen, directory: "screen", file: "screen/screen.mp4", codec: "hvc1",
                                pixelSize: pixel, duration: duration)]
        if options.microphoneID != nil {
            tracks.append(TrackInfo(kind: .microphone, directory: "microphone", file: "microphone/microphone.m4a",
                                    codec: "aac", sampleRate: 48000, channels: 1, duration: duration))
        }
        if options.cameraID != nil {
            tracks.append(TrackInfo(kind: .camera, directory: "camera", file: "camera/camera.mp4", codec: "hvc1",
                                    pixelSize: PixelSize(width: 1920, height: 1080), duration: duration))
        }
        if options.captureSystemAudio {
            tracks.append(TrackInfo(kind: .systemAudio, directory: "systemAudio", file: "systemAudio/systemAudio.m4a",
                                    codec: "aac", sampleRate: 48000, channels: 2, duration: duration))
        }
        let f = DateFormatter(); f.dateFormat = "MMM d 'at' h.mm a"
        let manifest = ProjectManifest(title: "Recording \(f.string(from: Date()))", appVersion: ReelbirdInfo.version,
                                       status: .complete,
                                       capture: CaptureInfo(source: options.source, pixelSize: pixel, scale: 2, frameRate: options.frameRate),
                                       clock: ClockInfo(originHostTime: 0), tracks: tracks,
                                       pauses: lock.withLock { pauses }, duration: duration,
                                       share: lock.withLock { shareInfo })
        try bundle.writeManifest(manifest)
        let writer = try EventLogWriter(url: bundle.eventsURL)
        for e in MockData.events(duration: duration) { writer.append(e) }
        writer.close()
        if let sink = shareSink { await sink.finish(totalDuration: duration, timeout: 1) }
        publish { $0.phase = .finished }
        finishStreams()
        return bundle
    }

    var microphoneLevels: MicLevelReading { lock.withLock { pauseStart == nil ? levels : MicLevelReading() } }
    var microphoneTakeSummary: MicTakeSummary? { lock.withLock { summary } }
    var trackIssues: [TrackKind: String] { get async { [:] } }

    func discard() async {
        ticker?.cancel()
        if let sink = shareSink { await sink.cancel() }
        try? FileManager.default.removeItem(at: bundleURL)
        publish { $0.phase = .idle }
        finishStreams()
    }

    private func finishStreams() {
        let cs = lock.withLock { () -> [AsyncStream<RecorderStatus>.Continuation] in
            defer { continuations.removeAll() }; return Array(continuations.values)
        }
        cs.forEach { $0.finish() }
    }
}

struct MockRender: RenderService {
    @MainActor func makePreviewPlayer(bundle: ProjectBundle) throws -> any PreviewPlayerHandle {
        let manifest = try? bundle.readManifest()
        return MockPreviewPlayer(duration: manifest?.duration ?? 42, events: (try? bundle.readEvents()) ?? [],
                                 sourceSize: manifest?.capture.pixelSize ?? PixelSize(width: 3456, height: 2234),
                                 hasCamera: manifest?.track(.camera) != nil,
                                 art: manifest?.capture.source.browserAppName == nil ? .docs : .browser)
    }

    func export(bundle: ProjectBundle, edit: EditDocument, options: ExportOptions,
                progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let ext: String = switch options.format {
        case .mp4H264, .mp4HEVC: "mp4"
        case .proRes: "mov"
        case .gif: "gif"
        }
        let name = (edit.title ?? bundle.url.deletingPathExtension().lastPathComponent)
        let dir = options.destination ?? bundle.exportsURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).\(ext)")
        for i in 1...40 {
            try await Task.sleep(for: .milliseconds(60))
            try Task.checkCancellation()
            progress(Double(i) / 40)
        }
        try Data("Reelbird mock export".utf8).write(to: url)
        return url
    }

    func voiceStemStatus(bundle: ProjectBundle, settings: AudioSettings) -> VoiceStemStatus { settings.enhance ? .ready : .off }
    func renderVoiceStem(bundle: ProjectBundle, settings: AudioSettings, progress: @escaping @Sendable (Double) -> Void) async throws {
        for i in 1...10 {
            try await Task.sleep(for: .milliseconds(40))
            progress(Double(i) / 10)
        }
    }

    func audioAnalysis(bundle: ProjectBundle, settings: AudioSettings) async -> AudioAnalysis? {
        let file = (try? bundle.readManifest())?.track(.microphone)?.file ?? "microphone/microphone.m4a"
        return AudioAnalysis(microphone: TrackLoudness(file: file, fileSize: 0, integratedLUFS: -25.2, peakDBFS: -9, duration: 42))
    }

    func poster(bundle: ProjectBundle, at t: Double, maxWidth: Int) async throws -> CGImage {
        let seed = abs(bundle.url.lastPathComponent.hashValue) % MockArt.Variant.allCases.count
        guard let img = MockArt.image(width: maxWidth, height: maxWidth * 10 / 16,
                                      variant: MockArt.Variant(rawValue: seed) ?? .docs, dark: seed % 2 == 1)
        else { throw CocoaError(.fileReadCorruptFile) }
        return img
    }

    func autoZoomPlan(events: [InputEvent], duration: Double, intensity: Double, crop: NormRect?) -> [ZoomRegion] {
        AutoZoomPlanner.plan(events: events, duration: duration, intensity: intensity, crop: crop)
    }

    /// Browser windows have the mock browser's toolbar (`MockArt.browserToolbarHeight`); other recordings none.
    func cropSuggestion(bundle: ProjectBundle) async -> CropSuggestion? {
        guard let m = try? bundle.readManifest() else { return nil }
        let size = m.capture.pixelSize
        let top = m.capture.source.browserAppName == nil ? 0 : Int((MockArt.browserToolbarHeight(width: Double(size.width))).rounded())
        return CropSuggestion(file: m.track(.screen)?.file ?? "screen/screen.mp4", fileSize: 1, height: size.height, topPixels: top,
                              confidence: top > 0 ? 0.94 : 0)
    }
}

final class MockShare: ShareServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var storedSecret: String?
    private static let key = "mock.shareDestination"

    func loadDestination() -> ShareDestination? {
        guard let d = UserDefaults.standard.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(ShareDestination.self, from: d)
    }
    func saveDestination(_ d: ShareDestination, secret: String) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(d), forKey: Self.key)
        lock.withLock { storedSecret = secret }
    }
    func secret() -> String? { lock.withLock { storedSecret } ?? (loadDestination() != nil ? "mock-secret" : nil) }
    func clearDestination() {
        UserDefaults.standard.removeObject(forKey: Self.key)
        lock.withLock { storedSecret = nil }
    }
    func makeLiveUploader(destination: ShareDestination, secret: String) -> any ShareSegmentSink {
        MockLiveUploader(destination: destination)
    }
    func resumeIfNeeded(bundle: ProjectBundle) async throws -> ShareInfo? { nil }
    func testConnection(_ d: ShareDestination, secret: String) async throws {
        try await Task.sleep(for: .milliseconds(700))
        guard d.endpoint.hasPrefix("https://"), !d.bucket.isEmpty, !d.accessKeyID.isEmpty, !secret.isEmpty else {
            throw ShareTestError("The endpoint must start with https:// and every field needs a value.")
        }
        guard d.publicBaseURL.hasPrefix("https://") else {
            throw ShareTestError("Uploads work, but the public URL must start with https:// so viewers can open links.")
        }
    }
    func publish(bundle: ProjectBundle, video: URL?, poster: CGImage?, captions: URL?, destination: ShareDestination,
                 secret: String, progress: @escaping @Sendable (Double) -> Void) async throws -> ShareInfo {
        for i in 1...25 { try await Task.sleep(for: .milliseconds(50)); progress(Double(i) / 25) }
        let existing = (try? bundle.readManifest())?.share
        let id = existing?.key ?? "\(destination.prefix)/\(ShortID.make())"
        var base = destination.publicBaseURL
        if base.hasSuffix("/") { base.removeLast() }
        return ShareInfo(key: id, url: "\(base)/\(id)/", polished: true)
    }
    func unpublish(_ info: ShareInfo, destination: ShareDestination, secret: String) async throws {
        try await Task.sleep(for: .milliseconds(300))
    }
}

struct ShareTestError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

final class MockLiveUploader: ShareSegmentSink, @unchecked Sendable {
    private let destination: ShareDestination
    init(destination: ShareDestination) { self.destination = destination }
    func begin(recordingID: String, title: String) async throws -> ShareInfo {
        var base = destination.publicBaseURL
        if base.hasSuffix("/") { base.removeLast() }
        let key = "\(destination.prefix)/\(recordingID)"
        return ShareInfo(key: key, url: "\(base)/\(key)/")
    }
    func initSegment(_ data: Data) async {}
    func mediaSegment(index: Int, data: Data, duration: Double) async {}
    func finish(totalDuration: Double, timeout: Double) async {}
    func cancel() async {}
    var backlog: Int { get async { 2 } }
}

struct MockAI: AIService {
    var transcriberAvailable: Bool { true }
    func captionsUnavailableReason() async -> String? { nil }
    var storySupported: Bool { true }
    var storyUnavailableReason: String? { nil }
    func suggestStory(transcript: Transcript) async throws -> (title: String, chapters: [Chapter]) {
        try await Task.sleep(for: .milliseconds(900))
        return ("Checkout flow walkthrough", [Chapter(time: 0, title: "The cart"), Chapter(time: 14, title: "Shipping details"),
                                               Chapter(time: 31, title: "Paying and the receipt")])
    }
    func transcribe(audio: URL, locale: Locale?) async throws -> Transcript {
        try await Task.sleep(for: .milliseconds(1400))
        return MockData.transcript
    }
    func webVTT(_ t: Transcript) -> String { Captions.webVTT(t) }
    func silentRanges(audio: URL) throws -> [TimeRange] { [TimeRange(start: 9, end: 15)] }
}

/// Mock live inputs: a speech-like meter and a placeholder camera view.
@MainActor final class MockInputPreview: InputPreviewService {
    private var timer: Timer?
    func startMicrophoneMeter(deviceID: String, onLevel: @escaping @MainActor (Double) -> Void) {
        timer?.invalidate()
        var tick = 0.0
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 20, repeats: true) { _ in
            MainActor.assumeIsolated {
                tick += 1
                let v = 0.5 + 0.5 * sin(tick * 0.41) * sin(tick * 0.13)
                onLevel(max(0.04, min(1, v * 0.8 + Double.random(in: 0...0.12))))
            }
        }
    }
    func stopMicrophoneMeter() { timer?.invalidate(); timer = nil }
    func makeCameraView(deviceID: String) -> NSView { MockCameraView() }
}

/// Placeholder "camera": a soft warm backdrop with a head-and-shoulders silhouette.
final class MockCameraView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        let colors = [NSColor(hex: 0x6B5B53).cgColor, NSColor(hex: 0x3A3330).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: b.midX, y: b.minY), end: CGPoint(x: b.midX, y: b.maxY), options: [])
        }
        let s = min(b.width, b.height)
        ctx.setFillColor(NSColor(hex: 0xD9A88A).cgColor)
        ctx.fillEllipse(in: CGRect(x: b.midX - s * 0.17, y: b.midY - s * 0.30, width: s * 0.34, height: s * 0.40))
        ctx.setFillColor(NSColor(hex: 0x2F4A6B).cgColor)
        ctx.fillEllipse(in: CGRect(x: b.midX - s * 0.42, y: b.midY + s * 0.14, width: s * 0.84, height: s * 0.7))
        ctx.setFillColor(NSColor(hex: 0x3B2A22).cgColor)
        ctx.addPath(CGPath(ellipseIn: CGRect(x: b.midX - s * 0.19, y: b.midY - s * 0.36, width: s * 0.38, height: s * 0.2), transform: nil))
        ctx.fillPath()
    }
}
