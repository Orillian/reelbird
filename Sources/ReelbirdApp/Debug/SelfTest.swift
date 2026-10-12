import AppKit
import ReelbirdCore

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
