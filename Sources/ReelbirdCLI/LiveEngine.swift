@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ReelbirdCapture
import ReelbirdCore
import ReelbirdRender
import Synchronization

/// The real engine: ReelbirdCapture for sources and recording, ReelbirdRender for export.
/// Sharing stays unavailable until ReelbirdShare is wired in.
struct LiveEngine: Engine {
    /// Speech (or any audio file) to play as the synthetic microphone (`record --synthetic --synthetic-mic FILE`).
    var syntheticMicrophone: URL?
    private let fallback = UnavailableEngine()

    // MARK: Capture

    func sources() async throws -> [SourceInfo] {
        let screens: [AvailableSource]
        do { screens = try await CaptureSources.list() } catch { throw Self.cliError(error) }
        let main = String(CGMainDisplayID())
        // Main display first, so `--display 1` is the main display.
        let ordered = screens.filter { Self.numericID($0.source) == main } + screens.filter { Self.numericID($0.source) != main }
        var out = ordered.map { s in
            SourceInfo(kind: s.kind == .display ? .display : .window, id: Self.numericID(s.source), name: s.title,
                       detail: s.appName, isDefault: s.kind == .display && Self.numericID(s.source) == main,
                       width: s.pixelSize.width, height: s.pixelSize.height)
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
            let screens: [AvailableSource]
            do { screens = try await CaptureSources.list() } catch { throw Self.cliError(error) }
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
        if options.shareWhileRecording {
            throw CLIError("Sharing while recording isn't available in this build yet.", code: .unavailable,
                           hint: "Record without --share; share links arrive with the ReelbirdShare module.")
        }
        let session = RecordingSession(options: options, bundleURL: bundleURL, frameSource: frameSource)
        do { try await session.start() } catch {
            await session.discard()
            throw Self.cliError(error)
        }
        return LiveRecording(session: session)
    }

    func recover(bundle: ProjectBundle) throws -> Bool {
        do { return try ProjectRecovery.recoverIfNeeded(bundle) } catch {
            throw CLIError("Couldn't recover \(Format.path(bundle.url)): \(error.localizedDescription)")
        }
    }

    // MARK: Render

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

    // MARK: Share (pending ReelbirdShare)

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

    // MARK: Helpers

    private func displays() async throws -> [(id: CGDirectDisplayID, name: String)] {
        let main = CGMainDisplayID()
        if let list = try? await CaptureSources.list() {
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
        let all = ids.prefix(Int(count)).map { (id: $0, name: "Display \($0)") }
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
}
