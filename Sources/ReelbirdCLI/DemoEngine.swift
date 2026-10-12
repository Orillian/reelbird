import Foundation
import ReelbirdCore

/// A capture engine that records nothing: it writes a valid empty project and reports status ticks.
/// Selected with `REELBIRD_DEMO_ENGINE=1`, to exercise the CLI and MCP recording flow (Ctrl-C, sessions,
/// --duration) without Screen Recording permission. Render and share calls stay unavailable.
struct DemoEngine: Engine {
    private let fallback = UnavailableEngine()

    func sources() async throws -> [SourceInfo] {
        [
            SourceInfo(kind: .display, id: "1", name: "Demo Display", isDefault: true, width: 3024, height: 1964),
            SourceInfo(kind: .window, id: "4242", name: "Demo Window", detail: "Demo App", width: 1280, height: 800),
            SourceInfo(kind: .microphone, id: "demo-mic", name: "Demo Microphone", isDefault: true),
            SourceInfo(kind: .camera, id: "demo-cam", name: "Demo Camera", isDefault: true),
        ]
    }

    func resolve(_ selector: SourceSelector) async throws -> CaptureSource { .synthetic(name: "demo") }

    func startRecording(options: RecordingOptions, bundleURL: URL) async throws -> any RecordingControl {
        try DemoRecording(options: options, bundleURL: bundleURL)
    }

    func recover(bundle: ProjectBundle) throws -> Bool {
        var m = try bundle.readManifest()
        guard m.status == .recording else { return false }
        m.status = .recovered
        try bundle.writeManifest(m)
        return true
    }

    func export(bundle: ProjectBundle, edit: EditDocument, request: ExportRequest,
                progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await fallback.export(bundle: bundle, edit: edit, request: request, progress: progress)
    }
    func share(bundle: ProjectBundle, edit: EditDocument, polished: Bool,
               progress: @escaping @Sendable (Double) -> Void) async throws -> ShareInfo {
        try await fallback.share(bundle: bundle, edit: edit, polished: polished, progress: progress)
    }
    func unshare(bundle: ProjectBundle, info: ShareInfo) async throws { try await fallback.unshare(bundle: bundle, info: info) }
    func shareDestination() -> ShareDestination? { nil }
    func hasShareSecret() -> Bool { false }
    func saveShareDestination(_ destination: ShareDestination, secret: String) throws {
        try fallback.saveShareDestination(destination, secret: secret)
    }
    func testShareConnection(_ destination: ShareDestination, secret: String) async throws {
        try await fallback.testShareConnection(destination, secret: secret)
    }
}

private final class DemoRecording: RecordingControl, @unchecked Sendable {
    let status: AsyncStream<RecorderStatus>
    private let continuation: AsyncStream<RecorderStatus>.Continuation
    private let bundle: ProjectBundle
    private let started = Date()
    private let lock = NSLock()
    private var result: ProjectBundle?
    private var ticker: Task<Void, Never>?

    init(options: RecordingOptions, bundleURL: URL) throws {
        bundle = try ProjectBundle.create(at: bundleURL)
        let manifest = ProjectManifest(title: bundleURL.deletingPathExtension().lastPathComponent, appVersion: ReelbirdInfo.version,
                                       capture: CaptureInfo(source: options.source, pixelSize: PixelSize(width: 1920, height: 1080),
                                                            scale: 2, frameRate: options.frameRate),
                                       clock: ClockInfo(originHostTime: 0))
        try bundle.writeManifest(manifest)
        (status, continuation) = AsyncStream<RecorderStatus>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let continuation = self.continuation, started = self.started, maxDuration = options.maxDuration
        ticker = Task {
            while !Task.isCancelled {
                var s = RecorderStatus()
                s.phase = .recording
                s.elapsed = Date().timeIntervalSince(started)
                s.microphoneLevel = 0.4
                if let maxDuration, s.elapsed >= maxDuration { s.phase = .finished }
                continuation.yield(s)
                if s.phase == .finished { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func stop() async throws -> ProjectBundle {
        let finished: ProjectBundle = try lock.withLock {
            if let result { return result }
            ticker?.cancel()
            var m = try bundle.readManifest()
            m.status = .complete
            m.duration = (Date().timeIntervalSince(started) * 1000).rounded() / 1000
            try bundle.writeManifest(m)
            try bundle.writeEdit(EditDocument.initial(for: m))
            result = bundle
            return bundle
        }
        continuation.finish()
        return finished
    }

    func discard() async {
        ticker?.cancel()
        continuation.finish()
        try? FileManager.default.removeItem(at: bundle.url)
    }
}
