import AppKit
import AVFoundation
import ReelbirdCore
import ReelbirdRender

/// `ReelbirdApp --selftest`: drives the app's models end to end against the services (mock by
/// default) without any windows: record → stop → library → editor edits, undo, autosave → export.
@MainActor enum SelfTest {
    static func run() async -> Bool {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) { print(ok ? "  ok   \(what)" : "  FAIL \(what)"); if !ok { failures.append(what) } }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reelbird-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "app.reelbird.selftest")!
        defaults.removePersistentDomain(forName: "app.reelbird.selftest")
        let prefs = Preferences(defaults: defaults)
        prefs.libraryPath = root.path
        let services = Services.mock(permissions: MockPermissions([.screen: .granted]))
        let library = prefs.library
        try? FileManager.default.createDirectory(at: library.root, withIntermediateDirectories: true)

        // Record
        var options = RecordingOptions(source: .display(id: 1, name: "Test"))
        options.cameraID = "facetime"
        let session: any RecordingSessionHandle
        do {
            session = try services.recorder.makeSession(options: options, bundleURL: library.newBundleURL(),
                                                        shareSink: MockShare().makeLiveUploader(
                                                            destination: ShareDestination(endpoint: "https://e", bucket: "b", accessKeyID: "k", publicBaseURL: "https://p"),
                                                            secret: "s"))
        } catch { print("makeSession failed: \(error)"); return false }
        var last = RecorderStatus()
        let watcher = Task { for await s in session.status { last = s } }
        do { try await session.start() } catch { check(false, "start: \(error)") }
        try? await Task.sleep(for: .milliseconds(600))
        check(last.phase == .recording && last.elapsed > 0.3, "status streams while recording (\(String(format: "%.2f", last.elapsed)) s)")
        check(last.shareURL?.hasPrefix("https://p/r/") == true, "share link reserved at start")
        await session.pause()
        try? await Task.sleep(for: .milliseconds(300))
        await session.resume()
        let bundle: ProjectBundle
        do { bundle = try await session.stop() } catch { check(false, "stop: \(error)"); return false }
        watcher.cancel()
        let manifest = try? bundle.readManifest()
        check(manifest?.status == .complete, "manifest written as complete")
        check(manifest?.pauses.count == 1, "pause recorded in manifest")
        check(manifest?.track(.camera) != nil, "camera track recorded")

        // Library
        let store = LibraryStore(services: services, prefs: prefs)
        store.reload()
        check(store.items.count == 1, "library lists the recording")

        // Editor
        guard let editor = try? EditorModel(bundle: bundle, services: services) else { check(false, "editor opens"); return false }
        check(editor.edit.cuts.count == 1, "pause becomes a cut")
        check(!editor.edit.zoom.regions.isEmpty, "auto zooms planned from clicks")
        editor.change("Padding", coalesce: "p") { $0.background.padding = 0.12 }
        editor.change("Padding", coalesce: "p") { $0.background.padding = 0.14 }
        editor.undoManager.undo()
        check(editor.edit.background.padding == BackgroundSettings().padding, "slider drags coalesce into one undo")
        editor.undoManager.redo()
        check(editor.edit.background.padding == 0.14, "redo restores")
        editor.seek(source: 1)
        editor.addZoomAtPlayhead()
        check(editor.selectedZoom?.source == .user, "manual zoom added and selected")
        editor.deleteSelection()
        check(editor.selectedZoom == nil, "zoom deleted")
        editor.seek(source: 2)
        editor.splitAtPlayhead()
        editor.seek(source: 3)
        editor.splitAtPlayhead()
        editor.selection = .segment(editor.segment(containing: 2.5))
        let before = editor.outputDuration
        editor.deleteSelection()
        check(abs((before - editor.outputDuration) - 1) < 0.01, "split + delete cuts one second")
        editor.setTrim(start: 0.5)
        check(editor.edit.trim?.start == 0.5, "trim start")
        try? await Task.sleep(for: .milliseconds(900))
        let saved = try? bundle.readEdit()
        check(saved?.trim?.start == 0.5, "edits autosave to edit.json")

        // Export
        editor.export(ExportOptions(format: .mp4H264, height: 720, destination: root.appendingPathComponent("out")))
        for _ in 0..<60 { if case .done = editor.exportState { break }; try? await Task.sleep(for: .milliseconds(100)) }
        if case .done(let url) = editor.exportState { check(FileManager.default.fileExists(atPath: url.path), "export writes a file") } else { check(false, "export finishes") }

        print(failures.isEmpty ? "SELFTEST PASS" : "SELFTEST FAIL (\(failures.count))")
        return failures.isEmpty
    }
}

/// `ReelbirdApp --selftest-live`: the same flow against the real engine with a synthetic capture
/// source (no permissions needed): record → stop → recover check → library poster → editor
/// (real preview player, transcript loading, edits) → MP4 export verified with AVFoundation.
@MainActor enum LiveSelfTest {
    static func run() async -> Bool {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) { print(ok ? "  ok   \(what)" : "  FAIL \(what)"); if !ok { failures.append(what) } }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reelbird-selftest-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "app.reelbird.selftest-live")!
        defaults.removePersistentDomain(forName: "app.reelbird.selftest-live")
        let prefs = Preferences(defaults: defaults)
        prefs.libraryPath = root.path
        let services = Services.live(synthetic: true)
        check(!services.isMock, "live services")
        let library = prefs.library
        try? FileManager.default.createDirectory(at: library.root, withIntermediateDirectories: true)

        // Record ~4 s with a 0.5 s pause: screen, camera, microphone and system audio.
        var options = RecordingOptions(source: .synthetic(name: "selftest"))
        options.frameRate = 30
        options.cameraID = "synthetic"
        options.countdown = 0
        let session: any RecordingSessionHandle
        do { session = try services.recorder.makeSession(options: options, bundleURL: library.newBundleURL(), shareSink: nil) } catch {
            print("makeSession failed: \(error)"); return false
        }
        var last = RecorderStatus()
        let watcher = Task { for await s in session.status { last = s } }
        do { try await session.start() } catch { check(false, "start: \(error.localizedDescription)"); return false }
        try? await Task.sleep(for: .seconds(2))
        check(last.phase == .recording && last.elapsed > 1, "status streams while recording (\(String(format: "%.2f", last.elapsed)) s)")
        check(last.microphoneLevel > 0.1, "microphone level reported (\(String(format: "%.2f", last.microphoneLevel)))")
        await session.pause()
        try? await Task.sleep(for: .milliseconds(500))
        await session.resume()
        try? await Task.sleep(for: .seconds(2))
        let bundle: ProjectBundle
        do { bundle = try await session.stop() } catch { check(false, "stop: \(error.localizedDescription)"); return false }
        watcher.cancel()
        guard let manifest = try? bundle.readManifest() else { check(false, "manifest readable"); return false }
        check(manifest.status == .complete, "manifest written as complete")
        check((3.5...5.5).contains(manifest.duration), "duration \(String(format: "%.2f", manifest.duration)) s")
        for kind in [TrackKind.screen, .camera, .microphone, .systemAudio] {
            let ok = bundle.mediaURL(for: kind, in: manifest).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            check(ok, "\(kind.rawValue) track consolidated")
        }
        check((try? services.recorder.recoverIfNeeded(bundle)) == false, "finished take needs no recovery")

        // Library
        let store = LibraryStore(services: services, prefs: prefs)
        store.reload()
        check(store.items.count == 1, "library lists the recording")
        if let poster = try? await services.render.poster(bundle: bundle, at: 1, maxWidth: 480) {
            check(poster.width == 480, "poster renders (\(poster.width)×\(poster.height))")
        } else { check(false, "poster renders") }

        // Captions written by the CLI are picked up by the editor.
        let vtt = "WEBVTT\n\n00:00:00.500 --> 00:00:02.000\nHello from the self test.\n"
        try? vtt.write(to: bundle.captionsURL, atomically: true, encoding: .utf8)
        var edit = (try? bundle.readEdit()) ?? EditDocument.initial(for: manifest)
        edit.captions.file = "captions.vtt"
        try? bundle.writeEdit(edit)

        // Editor
        guard let editor = try? EditorModel(bundle: bundle, services: services) else { check(false, "editor opens"); return false }
        check(editor.transcript?.segments.first?.text == "Hello from the self test.", "editor reads captions.vtt")
        editor.attachPlayer()
        for _ in 0..<50 where (editor.player?.duration ?? 0) <= 0 { try? await Task.sleep(for: .milliseconds(100)) }
        check(abs((editor.player?.duration ?? 0) - editor.outputDuration) < 0.05,
              "preview player loads (\(String(format: "%.2f", editor.player?.duration ?? 0)) s)")
        editor.setZoomIntensity(0.8)
        check(editor.edit.zoom.intensity == 0.8, "zoom intensity")
        editor.cut(TimeRange(start: 1, end: 2))
        let expected = editor.outputDuration
        check(abs(expected - (manifest.duration - 1 - manifest.pauses.reduce(0) { $0 + $1.duration })) < 0.05,
              "cut shortens the edit to \(String(format: "%.2f", expected)) s")

        // Export
        let out = root.appendingPathComponent("selftest.mp4")
        editor.export(ExportOptions(format: .mp4H264, height: 720, destination: out))
        for _ in 0..<300 {
            if case .running = editor.exportState { try? await Task.sleep(for: .milliseconds(100)) } else { break }
        }
        switch editor.exportState {
        case .done(let url):
            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            let video = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            let size = try? await video.first?.load(.naturalSize)
            check(abs(duration - expected) < 0.15, "export duration \(String(format: "%.2f", duration)) s ≈ \(String(format: "%.2f", expected)) s")
            check(video.count == 1 && audio.count == 1, "export has video and audio tracks")
            check(size.map { Int($0.height) } == 720, "export is 720p (\(size.map { "\(Int($0.width))×\(Int($0.height))" } ?? "?"))")
        case .failed(let message): check(false, "export: \(message)")
        default: check(false, "export finishes")
        }

        print(failures.isEmpty ? "SELFTEST-LIVE PASS" : "SELFTEST-LIVE FAIL (\(failures.count))")
        return failures.isEmpty
    }
}
