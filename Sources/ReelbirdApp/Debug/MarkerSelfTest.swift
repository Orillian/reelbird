import AppKit
import ReelbirdCore
import ReelbirdRender

extension SelfTest {
    /// Markers (session → events → editor flags → chapters), the after-recording setting, shortcut conflicts
    /// and the post-stop card: its state for each sharing setup, and Copy video / Save / Copy link end to end
    /// (a private pasteboard and a scratch folder, so the self test never touches yours).
    static func markersAndQuickActions(services: Services, prefs: Preferences, root: URL, check: (Bool, String) -> Void) async {
        // Settings
        check(prefs.afterRecording == .quickActions, "after recording: quick actions by default")
        check(AfterRecording.migrated(stored: nil, legacyOpenEditor: true) == .openEditor
              && AfterRecording.migrated(stored: nil, legacyOpenEditor: false) == .nothing
              && AfterRecording.migrated(stored: "openEditor", legacyOpenEditor: false) == .openEditor,
              "the old Open-the-editor toggle carries over")
        check(prefs.markerHotKey == .defaultMarker && HotKey.defaultMarker.display == "⌥⇧M", "marker shortcut defaults to ⌥⇧M")
        check(HotKeyField.conflict(.defaultPause, others: [.defaultRecord, .defaultPause], takenElsewhere: { _ in false })?
                .hasPrefix("Reelbird already uses") == true, "a shortcut Reelbird already uses is refused")
        check(HotKeyField.conflict(.defaultMarker, others: [.defaultRecord], takenElsewhere: { _ in true })?
                .hasPrefix("Another app") == true, "a shortcut another app holds is refused")
        check(HotKeyField.conflict(.defaultMarker, others: [.defaultRecord, .defaultPause, .defaultLayout], takenElsewhere: { _ in false }) == nil,
              "a free shortcut is accepted")
        check(HotKeyField.conflict(.defaultLayout, others: [prefs.recordHotKey, prefs.pauseHotKey, prefs.markerHotKey], takenElsewhere: { _ in false }) == nil
              && HotKeyField.conflict(.defaultLayout, others: [prefs.layoutHotKey], takenElsewhere: { _ in false }) != nil,
              "the marker and camera layout shortcuts don't clash, and each knows the other")

        // Card state
        var live = QuickShareState(shareURL: "https://p/r/abc", shareConfigured: true)
        check(live.linkDone && live.linkTitle == "Link copied", "card: a live link shows as copied")
        check(live.requestCopyVideo() == nil && live.requestSave() == nil && !live.autoDismisses(hovered: false),
              "card: video actions wait for the take to be saved; the card stays while saving")
        live.takeFinished(ok: true)
        check(live.autoDismisses(hovered: false) && !live.autoDismisses(hovered: true), "card: closes by itself unless hovered")
        check(live.requestCopyVideo() == .render && live.videoTitle == "0%" && !live.autoDismisses(hovered: false),
              "card: Copy video starts one render and the card stays while it runs")
        check(live.requestCopyVideo() == nil, "card: a second click doesn't start a second render")
        check(live.requestSave() == nil && live.save == .saving, "card: Save during the render waits for it")
        live.renderProgress(0.5)
        check(live.videoTitle == "50%", "card: render progress shows on Copy video")
        let file = URL(fileURLWithPath: "/tmp/take.mp4")
        let next = live.renderFinished(file)
        check(next == [.saveCopy(file), .copyVideo(file)], "card: the render feeds both Save and Copy video")
        live.videoCopied()
        live.saved(URL(fileURLWithPath: "/tmp/Downloads/take.mp4"))
        check(live.videoDone && live.videoTitle == "Video copied" && !live.linkDone && live.linkTitle == "Copy link",
              "card: copying the video replaces the link on the clipboard")
        live.linkCopied()
        check(live.linkDone && live.videoTitle == "Copy video" && live.requestCopyVideo() == .copyVideo(file),
              "card: the rendered video copies again at once")
        check(live.saveTitle == "Show", "card: after saving, Save shows the file")
        var failed = QuickShareState(shareURL: nil, shareConfigured: true)
        failed.takeFinished(ok: true)
        _ = failed.requestSave()
        failed.renderFailed("Couldn't make the video: disk full")
        check(failed.errorLine?.contains("disk full") == true && failed.videoTitle == "Try again" && failed.requestSave() == .render,
              "card: a failed render says why and can be tried again")
        check(failed.link == .share && failed.linkTitle == "Share…" && !failed.linkDone, "card: sharing set up but off for this take offers Share…")
        let none = QuickShareState(shareURL: nil, shareConfigured: false)
        check(none.link == .setUp && none.linkTitle == "Share…" && none.linkHelp.contains("Set up"), "card: no sharing set up offers setup")

        // A take with markers (mock engine)
        let dir = root.appendingPathComponent("markers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let session = try? services.recorder.makeSession(options: RecordingOptions(source: .display(id: 1, name: "Test")),
                                                               bundleURL: dir.appendingPathComponent("Marked.reelbird"), shareSink: nil)
        else { check(false, "marker take starts"); return }
        check(await session.addMarker(label: nil) == nil, "no marker before recording")
        try? await session.start()
        try? await Task.sleep(for: .milliseconds(300))
        let m1 = await session.addMarker(label: nil)
        try? await Task.sleep(for: .milliseconds(300))
        let m2 = await session.addMarker(label: "Checkout")
        check(m1?.label == "Marker 1" && m2?.number == 2 && m2?.label == "Checkout", "markers are numbered and named")
        guard let bundle = try? await session.stop() else { check(false, "marker take stops"); return }
        let logged = ((try? bundle.readEvents()) ?? []).filter { $0.type == .marker }
        check(logged.count == 2 && logged.last?.label == "Checkout", "markers are logged in events.jsonl")

        // Editor: flags, rename, delete, add, chapters, undo
        if let editor = try? EditorModel(bundle: bundle, services: services) {
            editor.autosaveEnabled = false
            check(editor.markers.map(\.title) == ["Marker 1", "Checkout"], "editor shows the recorded markers")
            editor.renameMarker("m1", to: "  Intro  ")
            check(editor.edit.markers?.first?.title == "Intro" && editor.edit.markers?.first?.id == "m1", "rename keeps the marker's ID")
            editor.seek(source: 3.2)
            editor.addMarkerAtPlayhead()
            check(editor.markers.count == 3 && editor.markers.last?.title == "Marker 3", "M adds a numbered marker at the playhead")
            editor.deleteMarker("m2")
            check(editor.markers.map(\.title) == ["Intro", "Marker 3"], "a marker deletes")
            editor.useMarkersAsChapters()
            check(editor.edit.chapters.map(\.title).suffix(2) == ["Intro", "Marker 3"], "markers become chapters")
            editor.undoManager.undo()
            check(editor.edit.chapters.isEmpty, "Use Markers as Chapters undoes")
        } else {
            check(false, "editor opens the marker take")
        }

        // The card end to end: Copy video (mock render), Save, Copy link
        let board = NSPasteboard(name: NSPasteboard.Name("app.reelbird.selftest.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let saves = root.appendingPathComponent("saved", isDirectory: true)
        let model = QuickShareModel(services: services, shareURL: "https://p/r/abc", shareConfigured: true,
                                    pasteboard: board, saveFolder: { saves })
        await model.takeFinished(bundle)
        check(model.state.canAct && model.thumbnail != nil && (model.duration ?? 0) > 0, "card: thumbnail and length once saved")
        model.copyVideo()
        for _ in 0..<80 where model.state.clipboard != .video { try? await Task.sleep(for: .milliseconds(100)) }
        let copied = board.readObjects(forClasses: [NSURL.self]) as? [URL]
        check(model.state.videoDone && copied?.first.map { FileManager.default.fileExists(atPath: $0.path) } == true,
              "Copy video puts an MP4 file on the pasteboard")
        model.save()
        if case .saved(let url) = model.state.save {
            check(url.deletingLastPathComponent().standardizedFileURL == saves.standardizedFileURL && FileManager.default.fileExists(atPath: url.path),
                  "Save copies the video into the export folder")
        } else {
            check(false, "Save copies the video into the export folder")
        }
        model.copyLink()
        check(board.string(forType: .string) == "https://p/r/abc" && model.state.linkDone, "Copy link copies the link again")
        let second = QuickShareModel.uniqueURL(saves.appendingPathComponent(copied?.first?.lastPathComponent ?? "x.mp4"))
        check(second.lastPathComponent.hasSuffix(" 2.mp4"), "a second save doesn't replace the first")
    }
}
