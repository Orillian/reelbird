import AppKit
@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ReelbirdAI
import ReelbirdCapture
import ReelbirdCore
import ReelbirdRender
import ReelbirdShare
import Synchronization

/// The real engine: ReelbirdCapture for sources and recording, ReelbirdRender for export,
/// ReelbirdShare for links (settings from `REELBIRD_S3_*` or share.json + Keychain).
struct LiveEngine: Engine {
    /// Speech (or any audio file) to play as the synthetic microphone (`record --synthetic --synthetic-mic FILE`).
    var syntheticMicrophone: URL?

    // MARK: Capture

    func sources() async throws -> [SourceInfo] {
        let main = String(CGMainDisplayID())
        var out: [SourceInfo]
        if Permissions.status(.screen) == .granted {
            let screens = try await screenSources()
            // Main display first, so `--display 1` is the main display.
            let ordered = screens.filter { Self.numericID($0.source) == main } + screens.filter { Self.numericID($0.source) != main }
            out = ordered.map { s in
                SourceInfo(kind: s.kind == .display ? .display : .window, id: Self.numericID(s.source), name: s.title,
                           detail: s.appName, isDefault: s.kind == .display && Self.numericID(s.source) == main,
                           width: s.pixelSize.width, height: s.pixelSize.height)
            }
        } else {
            // Without Screen Recording, windows can't be listed, but displays and devices still can.
            out = try await displays().map { d in
                SourceInfo(kind: .display, id: String(d.id), name: d.name,
                           detail: "Allow Screen Recording to list windows", isDefault: String(d.id) == main,
                           width: CGDisplayPixelsWide(d.id) * Int(Self.backingScale(d.id)),
                           height: CGDisplayPixelsHigh(d.id) * Int(Self.backingScale(d.id)))
            }
        }
        out += Devices.microphones().map { SourceInfo(kind: .microphone, id: $0.id, name: $0.name, isDefault: $0.isDefault) }
        out += Devices.cameras().map { SourceInfo(kind: .camera, id: $0.id, name: $0.name, isDefault: $0.isDefault) }
        return out
    }

    func resolve(_ selector: SourceSelector) async throws -> CaptureSource {
        switch selector {
        case .synthetic:
            return .synthetic(name: "synthetic")
        case .mainDisplay:
            let id = CGMainDisplayID()
            return .display(id: id, name: (try? await displays().first { $0.id == id }?.name) ?? "Main display")
        case .display(let key):
            let list = try await displays()
            // A small number is a 1-based index into `reelbird sources`; anything else is a display ID.
            if let n = Int(key), (1...list.count).contains(n), !list.contains(where: { String($0.id) == key }) {
                return .display(id: list[n - 1].id, name: list[n - 1].name)
            }
            guard let d = list.first(where: { String($0.id) == key }) else {
                throw CLIError("No display '\(key)'.", code: .noInput, hint: "Run `reelbird sources` for display numbers and IDs.")
            }
            return .display(id: d.id, name: d.name)
        case .window(let key):
            let screens = try await screenSources()
            guard let w = screens.first(where: { $0.kind == .window && Self.numericID($0.source) == key }) else {
                throw CLIError("No on-screen window with ID \(key).", code: .noInput, hint: "Run `reelbird sources` for window IDs.")
            }
            return w.source
        case .area(let x, let y, let width, let height, let display):
            let id: CGDirectDisplayID
            if let display {
                guard case .display(let d, _) = try await resolve(.display(display)) else { throw CLIError("No display '\(display)'.") }
                id = d
            } else {
                var found: CGDirectDisplayID = 0
                var count: UInt32 = 0
                let center = CGPoint(x: x + width / 2, y: y + height / 2)
                guard CGGetDisplaysWithPoint(center, 1, &found, &count) == .success, count > 0 else {
                    throw CLIError.usage("The area \(Int(x)),\(Int(y)),\(Int(width)),\(Int(height)) isn't on any display.")
                }
                id = found
            }
            return .area(displayID: id, x: x, y: y, width: width, height: height)
        }
    }

    func startRecording(options: RecordingOptions, bundleURL: URL) async throws -> any RecordingControl {
        var frameSource: (any FrameSource)?
        if case .synthetic = options.source {
            frameSource = try syntheticSource(for: options)
        } else if Permissions.status(.screen) != .granted {
            throw CLIError("Screen Recording permission is off for this terminal.", code: .unavailable,
                           hint: "Turn it on in System Settings › Privacy & Security › Screen & System Audio Recording, then restart the terminal.")
        }
        var sink: LiveShareUploader?
        if options.shareWhileRecording {
            let (destination, secret) = try configuredShare()
            sink = LiveShareUploader(destination: destination, secret: secret)
        }
        let session = RecordingSession(options: options, bundleURL: bundleURL, shareSink: sink, frameSource: frameSource)
        do { try await session.start() } catch {
            await session.discard()
            throw Self.cliError(error)
        }
        return LiveRecording(session: session)
    }

    func recover(bundle: ProjectBundle) async throws -> Bool {
        let recovered: Bool
        do { recovered = try ProjectRecovery.recoverIfNeeded(bundle) } catch {
            throw CLIError("Couldn't recover \(Format.path(bundle.url)): \(error.localizedDescription)")
        }
        // Finish a live share upload the crash cut short, so the link plays to the end.
        var resumed = false
        if let m = try? bundle.readManifest(), m.share != nil, m.track(.share) != nil,
           let d = ShareSettings.load(), let secret = ShareSettings.secret() {
            do { resumed = try await LiveShareUploader(destination: d, secret: secret).resumeIfNeeded(bundle: bundle) != nil } catch {
                throw CLIError("Recovered the project, but finishing its share upload failed: \(Self.shareMessage(error))")
            }
        }
        return recovered || resumed
    }

    // MARK: Render

    func renderVoiceStem(bundle: ProjectBundle, settings: AudioSettings,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> VoiceStemInfo {
        do {
            return try await VoiceStem.render(bundle: bundle, settings: settings, progress: progress)
        } catch let e as CancellationError {
            throw e
        } catch {
            throw CLIError("Couldn't enhance the voice: \((error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
    }

    func export(bundle: ProjectBundle, edit: EditDocument, request: ExportRequest,
                progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let format: ExportOptions.Format = switch request.format {
        case .mp4: .mp4H264
        case .hevc: .mp4HEVC
        case .prores: .proRes
        case .gif: .gif
        }
        if let d = request.destination {
            try FileManager.default.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let options = ExportOptions(format: format, height: request.height, frameRate: request.frameRate, destination: request.destination)
        do {
            return try await Exporter.export(bundle: bundle, edit: edit, options: options, progress: progress)
        } catch let e as CancellationError {
            throw e
        } catch {
            throw CLIError("Export failed: \(error.localizedDescription)")
        }
    }

    // MARK: Share

    /// Renders the current edit (1080p H.264), then publishes it with a poster and output-timeline
    /// captions. Updates the existing link in place when the project already has one.
    func share(bundle: ProjectBundle, edit: EditDocument, polished: Bool,
               progress: @escaping @Sendable (Double) -> Void) async throws -> ShareInfo {
        let (destination, secret) = try configuredShare()
        let manifest = try bundle.readManifest()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("reelbird-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let video = try await export(bundle: bundle, edit: edit,
                                     request: ExportRequest(format: .mp4, height: 1080, destination: tmp.appendingPathComponent("video.mp4")),
                                     progress: { progress($0 * 0.6) })
        let poster = try? await Thumbnailer.poster(bundle: bundle, at: 0, maxWidth: 1280)
        var captions: URL?
        if edit.captions.file != nil, let transcript = Self.transcript(bundle: bundle) {
            let url = tmp.appendingPathComponent("captions.vtt")
            try Data(Captions.webVTT(transcript.remapped(to: EditTimeline(manifest: manifest, edit: edit))).utf8).write(to: url)
            captions = url
        }
        do {
            return try await ShareService.publish(bundle: bundle, video: video, poster: poster, captions: captions,
                                                  destination: destination, secret: secret) { progress(0.6 + $0 * 0.4) }
        } catch { throw CLIError("Sharing failed: \(Self.shareMessage(error))") }
    }

    func unshare(bundle: ProjectBundle, info: ShareInfo) async throws {
        let (destination, secret) = try configuredShare()
        do { try await ShareService.unpublish(info, destination: destination, secret: secret) } catch {
            throw CLIError("Couldn't remove the share: \(Self.shareMessage(error))")
        }
    }

    func shareDestination() -> ShareDestination? { ShareSettings.load() }
    func hasShareSecret() -> Bool { ShareSettings.secret() != nil }

    func saveShareDestination(_ destination: ShareDestination, secret: String) throws {
        do { try ShareSettings.save(destination, secret: secret) } catch {
            throw CLIError(Self.shareMessage(error), code: .usage)
        }
    }

    func testShareConnection(_ destination: ShareDestination, secret: String) async throws {
        do { try await ShareService.testConnection(ShareSettings.normalized(destination), secret: secret) } catch {
            throw CLIError("Connection test failed: \(Self.shareMessage(error))")
        }
    }

    private func configuredShare() throws -> (ShareDestination, String) {
        guard let d = ShareSettings.load() else {
            throw CLIError("Sharing isn't set up.", code: .unavailable,
                           hint: "Run `reelbird config share --endpoint URL --bucket NAME --access-key ID --public-base URL --secret-stdin`, or set REELBIRD_S3_* variables.")
        }
        guard let secret = ShareSettings.secret() else {
            throw CLIError("The share secret access key is missing from the Keychain.", code: .unavailable,
                           hint: "Run `reelbird config share … --secret-stdin` again, or set REELBIRD_S3_SECRET_ACCESS_KEY.")
        }
        return (d, secret)
    }

    private static func transcript(bundle: ProjectBundle) -> Transcript? {
        guard let data = try? Data(contentsOf: bundle.transcriptURL) else { return nil }
        return try? JSONCoding.decoder.decode(Transcript.self, from: data)
    }

    static func shareMessage(_ error: any Error) -> String {
        (error as? ShareError)?.message ?? error.localizedDescription
    }

    // MARK: Helpers

    private static func backingScale(_ id: CGDirectDisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 else { return 1 }
        return Double(mode.pixelWidth) / Double(mode.width)
    }

    /// Displays and on-screen windows (the CLI can't bring a window from another Space or the Dock
    /// the way the picker does). Checks the permission first: asking ScreenCaptureKit without it can
    /// put up a system prompt and wait for it, which would hang a script or an MCP client.
    private func screenSources() async throws -> [AvailableSource] {
        guard Permissions.status(.screen) == .granted else { throw Self.cliError(CaptureError.permissionDenied(.screen)) }
        do { return try await CaptureSources.list().filter(\.isOnScreen) } catch { throw Self.cliError(error) }
    }

    private func displays() async throws -> [(id: CGDirectDisplayID, name: String)] {
        let main = CGMainDisplayID()
        if Permissions.status(.screen) == .granted, let list = try? await CaptureSources.list() {
            let all: [(id: CGDirectDisplayID, name: String)] = list.compactMap { s in
                if case .display(let id, let name) = s.source { return (id, name) }
                return nil
            }
            return all.filter { $0.id == main } + all.filter { $0.id != main }
        }
        // Without Screen Recording permission, fall back to CoreGraphics (recording will then explain the permission).
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
        let names: [CGDirectDisplayID: String] = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { ($0.uint32Value, screen.localizedName) }
        })
        let all = ids.prefix(Int(count)).map { (id: $0, name: names[$0] ?? "Display \($0)") }
        return all.filter { $0.id == main } + all.filter { $0.id != main }
    }

    private func syntheticSource(for options: RecordingOptions) throws -> SyntheticFrameSource {
        var c = SyntheticFrameSource.Configuration()
        c.frameRate = min(60, options.frameRate)
        if options.microphoneID != nil {
            if let url = syntheticMicrophone {
                c.microphone = .samples(try Self.monoSamples(url))
            } else {
                c.microphone = .sine(frequency: 440, amplitude: 0.25)
            }
        } else {
            c.microphone = nil
        }
        c.systemAudio = options.captureSystemAudio ? .sine(frequency: 660, amplitude: 0.1) : nil
        c.camera = options.cameraID == nil ? nil : PixelSize(width: 1280, height: 720)
        return SyntheticFrameSource(configuration: c)
    }

    /// Decodes an audio file to mono Float32 at 48 kHz.
    static func monoSamples(_ url: URL) throws -> [Float] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            throw CLIError("Can't read audio file \(Format.path(url)): \(error.localizedDescription)", code: .noInput)
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CLIError("Can't convert \(Format.path(url)) to 48 kHz mono.")
        }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(file.length) * 48_000 / file.processingFormat.sampleRate) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw CLIError("Out of memory.") }
        // The input block runs synchronously inside convert(): hand over the whole file once.
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if once.done {
                status.pointee = .endOfStream
                return nil
            }
            once.done = true
            status.pointee = .haveData
            return input
        }
        if let error { throw CLIError("Can't convert \(Format.path(url)): \(error.localizedDescription)") }
        guard let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    static func numericID(_ source: CaptureSource) -> String {
        switch source {
        case .display(let id, _): String(id)
        case .window(let id, _, _): String(id)
        case .area(let id, _, _, _, _): String(id)
        case .synthetic(let name): name
        }
    }

    static func cliError(_ error: any Error) -> CLIError {
        if let e = error as? CLIError { return e }
        if let e = error as? CaptureError {
            switch e {
            case .permissionDenied(let p):
                return CLIError("\(p.displayName) permission is off for this terminal.", code: .unavailable,
                                hint: "Turn it on in System Settings › Privacy & Security, then restart the terminal.")
            case .sourceNotFound: return CLIError(e.localizedDescription, code: .noInput)
            default: return CLIError(e.localizedDescription)
            }
        }
        return CLIError.wrap(error)
    }
}

/// A recording in progress. `stop()` may be called any number of times (Ctrl-C, --duration and the
/// recorder's own max-duration stop can race); every caller gets the same bundle.
final class LiveRecording: RecordingControl {
    private let session: RecordingSession
    private let stopTask = Mutex<Task<ProjectBundle, any Error>?>(nil)

    init(session: RecordingSession) { self.session = session }

    var status: AsyncStream<RecorderStatus> { session.status }

    func stop() async throws -> ProjectBundle {
        let session = session
        let task = stopTask.withLock { t -> Task<ProjectBundle, any Error> in
            if let t { return t }
            let new = Task { try await session.stop() }
            t = new
            return new
        }
        do { return try await task.value } catch { throw LiveEngine.cliError(error) }
    }

    func discard() async { await session.discard() }

    var trackIssues: [TrackKind: String] { get async { await session.trackIssues } }

    func addMarker(label: String?) async -> RecordedMarker? { await session.addMarker(label: label) }
}
