import AppKit
import ReelbirdCapture
import ReelbirdCore
import SwiftUI

/// `ReelbirdApp --snapshot <dir> [filter] [--live]`: renders every key view with mock data to PNGs in
/// light and dark, without screen-recording permission. Used for design review. `--live` adds scenes
/// built on the real engine.
@MainActor enum SnapshotRunner {
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
        override var canBecomeKey: Bool { true }
    }

    struct Scene {
        let name: String
        let size: CGSize?
        let backdrop: Bool
        let build: () -> AnyView
        /// Animation frames: light appearance only.
        var lightOnly = false
    }

    static func run(dir: URL, filter: String?, live: Bool = false) {
        GlassOverride.inSnapshots = CommandLine.arguments.contains("--glass")
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: "app.reelbird.snapshots")!
        defaults.removePersistentDomain(forName: "app.reelbird.snapshots")
        let prefs = Preferences(defaults: defaults)
        prefs.cameraEnabled = true
        prefs.cameraID = "facetime"
        prefs.lastArea = CGRect(x: 320, y: 180, width: 960, height: 540)
        let permissions = MockPermissions([.screen: .granted, .microphone: .granted, .camera: .notDetermined, .inputMonitoring: .notDetermined])
        let services = Services.mock(permissions: permissions)
        let model = AppModel(services: services, prefs: prefs)

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("reelbird-snapshots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let demoURL = work.appendingPathComponent("Checkout flow walkthrough.reelbird")
        guard let demo = try? MockData.writeDemoBundle(at: demoURL, title: "Checkout flow walkthrough", duration: 46.5,
                                                       share: ShareInfo(key: "r/7Hk2pQx9aB", url: "https://pub-3f9a.r2.dev/r/7Hk2pQx9aB/", polished: false))
        else { print("Couldn't write demo bundle"); return }
        guard let browserDemo = try? MockData.writeDemoBundle(at: work.appendingPathComponent("Checkout in Chrome.reelbird"),
                                                              title: "Checkout flow walkthrough", duration: 46.5,
                                                              source: .window(id: 9, app: "Google Chrome", title: "Checkout – Acme"))
        else { print("Couldn't write demo bundle"); return }

        let sources = MockCaptureSources.sources(withThumbnails: true)
        var scenes: [Scene] = []

        // Source picker
        for tab in SourceTab.allCases {
            scenes.append(Scene(name: "picker-\(tab.rawValue)", size: CGSize(width: 620, height: 600), backdrop: true) {
                prefs.sourceTab = tab
                prefs.microphoneID = MicPolicy.automaticID
                let picker = SourcePickerModel(services: services, prefs: prefs)
                picker.apply(sources)
                picker.selectedWindowID = "win-102"
                picker.area = AreaSelection(rect: CGRect(x: 320, y: 180, width: 960, height: 540), displayID: 1)
                picker.setMicLevelForSnapshot(0.62)
                picker.shareAvailable = tab != .area
                prefs.shareWhileRecording = tab == .window
                return AnyView(SourcePickerView(model: picker, controller: nil, prefs: prefs))
            })
        }

        // Window tab: scrolled to windows on other desktops / minimized, and a search that matches
        // windows in both sections.
        for (name, query, reveal) in [("picker-window-other", "", true), ("picker-window-search", "safari", false)] {
            scenes.append(Scene(name: name, size: CGSize(width: 620, height: 600), backdrop: true) {
                prefs.sourceTab = .window
                prefs.microphoneID = MicPolicy.automaticID
                let picker = SourcePickerModel(services: services, prefs: prefs)
                picker.apply(sources)
                picker.windowQuery = query
                picker.revealOtherWindows = reveal
                picker.selectedWindowID = "win-204"
                picker.setMicLevelForSnapshot(0.62)
                picker.shareAvailable = true
                prefs.shareWhileRecording = false
                return AnyView(SourcePickerView(model: picker, controller: nil, prefs: prefs))
            })
        }

        scenes.append(Scene(name: "picker-access", size: CGSize(width: 620, height: 640), backdrop: true) {
            prefs.sourceTab = .display
            let picker = SourcePickerModel(services: services, prefs: prefs)
            picker.apply(Array(sources.filter { $0.kind == .display }.prefix(1)) + sources.filter { $0.kind == .window })
            picker.setAccessForSnapshot(microphone: .denied, camera: .notDetermined, lowDisk: 3_400_000_000)
            picker.shareAvailable = false
            prefs.shareWhileRecording = false
            return AnyView(SourcePickerView(model: picker, controller: nil, prefs: prefs))
        })

        // Microphone notes in the picker: a Bluetooth mic, and a chosen mic that isn't plugged in.
        for (name, mic) in [("picker-mic-bluetooth", "airpods"), ("picker-mic-missing", "unplugged-usb-mic")] {
            scenes.append(Scene(name: name, size: CGSize(width: 620, height: 640), backdrop: true) {
                prefs.sourceTab = .display
                prefs.microphoneEnabled = true
                prefs.microphoneID = mic
                let picker = SourcePickerModel(services: services, prefs: prefs)
                picker.apply(sources)
                picker.setMicLevelForSnapshot(0.38)
                picker.shareAvailable = true
                prefs.shareWhileRecording = false
                return AnyView(SourcePickerView(model: picker, controller: nil, prefs: prefs))
            })
        }

        // Recording overlays
        func status(elapsed: Double, level: Double, warnings: [HealthWarning] = [], share: Bool = false, backlog: Int = 0) -> RecorderStatus {
            var s = RecorderStatus()
            s.phase = .recording; s.elapsed = elapsed; s.microphoneLevel = level; s.warnings = warnings
            s.shareURL = share ? "https://pub-3f9a.r2.dev/r/7Hk2pQx9aB/" : nil; s.uploadBacklog = backlog
            return s
        }
        scenes.append(Scene(name: "controlbar", size: CGSize(width: 620, height: 170), backdrop: true) {
            AnyView(ControlBarView(controller: nil, prefs: prefs, status: status(elapsed: 74, level: 0.7), phase: .recording))
        })
        scenes.append(Scene(name: "controlbar-warning", size: CGSize(width: 620, height: 170), backdrop: true) {
            AnyView(ControlBarView(controller: nil, prefs: prefs,
                                   status: status(elapsed: 12.4, level: 0, warnings: [HealthWarning(kind: .microphoneSilent, message: "Your mic is silent. Is it muted?", since: 9)],
                                                  share: true, backlog: 2),
                                   phase: .recording))
        })
        // Microphone warnings (one scene each) and the meter's target zone.
        let micWarnings: [(String, HealthWarning, RecordingController.Phase, MicLevelReading)] = [
            ("clipping", HealthWarning(kind: .microphoneClipping, message: "Your mic is clipping. Move back or lower its input level.", since: 40),
             .recording, MicLevelReading(peakDB: -0.2, rmsDB: -9)),
            ("tooquiet", HealthWarning(kind: .microphoneTooQuiet, message: "Your voice is very quiet. Move closer to the mic.", since: 52),
             .recording, MicLevelReading(peakDB: -36, rmsDB: -48)),
            ("disconnected", HealthWarning(kind: .microphoneDisconnected, message: "Shure MV7+ disconnected. Your voice may be missing until it's back.", since: 61),
             .recording, MicLevelReading()),
            ("changed", HealthWarning(kind: .microphoneChanged, message: "macOS switched to AirPods Pro. Still recording from MacBook Pro Microphone.", since: 70),
             .recording, MicLevelReading(peakDB: -12, rmsDB: -24)),
            ("silent", HealthWarning(kind: .microphoneSilent, message: "Your mic is silent. Is it muted or in use by another app?", since: 9),
             .recording, MicLevelReading()),
            ("talking-paused", HealthWarning(kind: .talkingWhilePaused, message: "You're talking while paused.", since: 88),
             .paused, MicLevelReading(peakDB: -14, rmsDB: -26)),
        ]
        for (name, w, phase, levels) in micWarnings {
            scenes.append(Scene(name: "controlbar-mic-\(name)", size: CGSize(width: 620, height: 200), backdrop: true) {
                var st = status(elapsed: w.since + 2.4, level: MicLevelReading.meterPosition(levels.rmsDB), warnings: [w])
                st.phase = phase == .paused ? .paused : .recording
                return AnyView(ControlBarView(controller: nil, prefs: prefs, status: st, phase: phase, levels: levels))
            })
        }
        scenes.append(Scene(name: "controlbar-mic-stack", size: CGSize(width: 620, height: 240), backdrop: true) {
            AnyView(ControlBarView(controller: nil, prefs: prefs,
                                   status: status(elapsed: 75, level: 0.6, warnings: [micWarnings[3].1, micWarnings[0].1]),
                                   phase: .recording, levels: MicLevelReading(peakDB: -3, rmsDB: -14)))
        })
        for (name, db) in [("quiet", -30.0), ("zone", -11.0), ("hot", -4.0)] {
            scenes.append(Scene(name: "controlbar-meter-\(name)", size: CGSize(width: 620, height: 120), backdrop: true) {
                AnyView(ControlBarView(controller: nil, prefs: prefs, status: status(elapsed: 74, level: 0.6), phase: .recording,
                                       levels: MicLevelReading(peakDB: db, rmsDB: db - 12)))
            })
        }
        scenes.append(Scene(name: "controlbar-paused", size: CGSize(width: 620, height: 170), backdrop: true) {
            AnyView(ControlBarView(controller: nil, prefs: prefs, status: status(elapsed: 202, level: 0, share: true), phase: .paused))
        })
        scenes.append(Scene(name: "controlbar-nomic", size: CGSize(width: 620, height: 170), backdrop: true) {
            AnyView(ControlBarView(controller: nil, prefs: prefs, permissions: MockPermissions([.microphone: .denied]),
                                   status: status(elapsed: 31, level: 0), phase: .recording))
        })
        scenes.append(Scene(name: "countdown", size: CGSize(width: 900, height: 560), backdrop: true) {
            AnyView(CountdownView(controller: model.recording, value: 2, sweep: 0.62).background(Color.black.opacity(0.25)))
        })
        scenes.append(Scene(name: "area-bar", size: CGSize(width: 900, height: 560), backdrop: true) {
            AnyView(AreaSnapshot())
        })
        scenes.append(Scene(name: "toast", size: CGSize(width: 520, height: 140), backdrop: true) {
            AnyView(ToastView(title: "Link copied", detail: "Still uploading 2 segments…", symbol: "link"))
        })
        scenes.append(Scene(name: "toast-layout", size: CGSize(width: 560, height: 140), backdrop: true) {
            AnyView(ToastView(title: "Camera only", detail: "The video shows your camera full frame. ⌥⇧L switches to screen only.",
                              symbol: "person.crop.rectangle"))
        })
        scenes += CameraBubbleScenes.scenes(animations: filter?.contains("camera-anim") == true)
        scenes += QuickShareScenes.scenes(services: services, prefs: prefs, status: status(elapsed: 84, level: 0.6))

        // Editor
        func editor(_ section: InspectorSection, variant: String? = nil, bundle: ProjectBundle? = nil,
                    configure: @escaping (EditorModel) -> Void = { _ in }) -> Scene {
            Scene(name: "editor-\(section.rawValue)" + (variant.map { "-\($0)" } ?? ""), size: CGSize(width: 1320, height: 840), backdrop: false) {
                guard let m = try? EditorModel(bundle: bundle ?? demo, services: services) else { return AnyView(Text("Editor failed")) }
                m.autosaveEnabled = false
                m.attachPlayer()
                m.setTimelineMediaForSnapshot(waveform: MockArt.waveform(count: 600, seed: 3),
                                              filmstrip: (0..<6).compactMap { MockArt.image(width: 160, height: 100, variant: MockArt.Variant(rawValue: $0 % 5) ?? .docs) })
                m.section = section
                m.setPlayheadForSnapshot(m.unzoomedTime(after: 4))
                configure(m)
                return AnyView(EditorView(model: m, app: nil))
            }
        }
        scenes.append(editor(.background))
        // The speed popover for a selected part at 1.5×.
        scenes.append(Scene(name: "speed-popover", size: CGSize(width: 340, height: 290), backdrop: true) {
            guard let m = try? EditorModel(bundle: demo, services: services) else { return AnyView(Text("Editor failed")) }
            m.autosaveEnabled = false
            m.selection = .segment(TimeRange(start: 6, end: 12))
            m.setSpeedFromSlider(1.5)
            return AnyView(SpeedPopover(model: m).background(RoundedRectangle(cornerRadius: 12).fill(Theme.raised)))
        })
        // Parts: two split points, the middle part selected with its edge handles; the mock's cut is a chip.
        scenes.append(editor(.background, variant: "parts") { m in
            m.setPlayheadForSnapshot(9)
            m.splitAtPlayhead()
            m.setPlayheadForSnapshot(15)
            m.splitAtPlayhead()
            m.selection = .segment(m.segment(containing: 12))
            m.setPlayheadForSnapshot(12)
        })
        scenes.append(editor(.guide) { m in
            m.change("x") { $0.guide.setEdit(id: "c8120", text: .some("Click \"Checkout\" at the top right")) }
            m.setGuideForSnapshot()
        })
        scenes.append(editor(.cursor) { m in m.change("x") { $0.cursor.showKeystrokes = true } })
        scenes.append(editor(.zoom) { m in
            m.addZoomAtPlayhead()
            m.setPlayheadForSnapshot(13.6)
        })
        // Speed: a slowed part, a 1.25× part (selected: the speed slider shows), applied typing and idle suggestions.
        scenes.append(editor(.zoom, variant: "speed") { m in
            m.change("x") { e in
                e.speed.set(TimeRange(start: 6.2, end: 8.4), rate: 0.5)
                e.speed.set(TimeRange(start: 14, end: 18.5), rate: 1.25, id: "sel")
                e.speed.set(TimeRange(start: 22, end: 26.6), rate: 4, source: .typing)
                e.speed.set(TimeRange(start: 30.4, end: 37.5), rate: 8, source: .idle)
            }
            m.selection = .speed("sel")
            m.setPlayheadForSnapshot(15.2)
        })
        // "Speed up typing": dashed suggestions and the one-click offer.
        scenes.append(editor(.zoom, variant: "speed-suggest") { m in
            m.setSpeedSuggestionsForSnapshot([
                SpeedSuggestion(kind: .typing, range: TimeRange(start: 9.8, end: 14.6), rate: 4),
                SpeedSuggestion(kind: .typing, range: TimeRange(start: 21.5, end: 27), rate: 2),
                SpeedSuggestion(kind: .idle, range: TimeRange(start: 30.4, end: 37.5), rate: 8),
            ])
        })
        // Several zooms selected (shift-click or a box on the zoom lane): one turned off, one instant.
        scenes.append(editor(.zoom, variant: "multi") { m in
            let rs = m.edit.zoom.regions
            guard rs.count >= 4 else { return }
            m.change("x") { e in
                e.zoom.regions[1].enabled = false
                e.zoom.regions[2].instant = true
            }
            m.selectZooms([rs[0].id, rs[2].id, rs[3].id])
            m.section = .zoom
        })
        // Command menu (⌘K): recent commands then every command by area; a search; the shortcut sheet (⌘/).
        scenes.append(editor(.zoom, variant: "palette") { m in
            CommandHistory.setForSnapshot(["export-gif", "split", "motion-blur", "panel-captions"])
            CommandMenu.open(m)
        })
        scenes.append(editor(.zoom, variant: "palette-search") { m in
            CommandHistory.setForSnapshot(["export-gif"])
            CommandMenu.open(m)
            m.paletteQuery = "zoom"
            m.paletteHighlight = 1
        })
        scenes.append(editor(.zoom, variant: "palette-empty") { m in
            CommandMenu.open(m)
            m.paletteQuery = "qqqq"
        })
        scenes.append(editor(.zoom, variant: "shortcuts") { m in m.showShortcuts = true })
        scenes.append(editor(.camera) { m in m.change("x") { $0.camera.shape = .roundedSquare; $0.canvas.aspect = .wide } })
        // Recorded moves listed in the Camera panel and marked on the timeline; a portrait tile mid-video.
        scenes.append(editor(.camera, variant: "moves") { m in
            m.change("x") {
                $0.camera.shape = .portrait
                $0.camera.position = NormPoint(x: 0.5, y: 1)
                $0.camera.moves = [CameraLayout.Move(t: 12.4, x: 0, y: 0), CameraLayout.Move(t: 31.8, x: 1, y: 0)]
            }
            m.setPlayheadForSnapshot(m.unzoomedTime(after: 14))
        })
        // Dragging the bubble on the preview: snapped to both centre lines, guides showing.
        scenes.append(editor(.camera, variant: "drag") { m in
            m.beginCameraDrag()
            m.updateCameraDrag(NormPoint(x: 0.5, y: 0.5), guides: [.centerX, .centerY])
        })
        // Camera layouts on the timeline: camera only and split segments, the split one selected; zoom settings.
        scenes.append(editor(.camera, variant: "layouts") { m in
            m.change("x") {
                $0.canvas.aspect = .wide
                $0.layouts = [LayoutSegment(id: "l1", range: TimeRange(start: 6, end: 11), kind: .fullCamera),
                              LayoutSegment(id: "l2", range: TimeRange(start: 19, end: 27), kind: .split),
                              LayoutSegment(id: "l3", range: TimeRange(start: 33, end: 36), kind: .screenOnly)]
            }
            m.setPlayheadForSnapshot(8.5)
            m.selection = .layout("l2")
        })
        scenes.append(editor(.camera, variant: "zooms") { m in
            m.change("x") { $0.camera.sizeWhileZoomed = 0.6; $0.canvas.aspect = .wide }
            m.setPlayheadForSnapshot(m.unzoomedTime(after: 4))
        })
        scenes.append(editor(.canvas) { m in m.change("x") { $0.canvas.aspect = .vertical } })
        // Crop: a Chrome window before and after "Hide Browser Toolbar", and crop mode on the preview.
        func toolbar(_ m: EditorModel) {
            let size = m.screenPixelSize
            m.setCropSuggestionForSnapshot(CropSuggestion(file: "screen/screen.mp4", fileSize: 1, height: size.height,
                                                          topPixels: Int(MockArt.browserToolbarHeight(width: Double(size.width)).rounded()),
                                                          confidence: 0.94))
        }
        scenes.append(editor(.canvas, variant: "browser", bundle: browserDemo) { m in toolbar(m) })
        scenes.append(editor(.canvas, variant: "toolbar-hidden", bundle: browserDemo) { m in
            toolbar(m)
            m.hideBrowserToolbar()
        })
        scenes.append(editor(.canvas, variant: "crop-mode", bundle: browserDemo) { m in
            toolbar(m)
            m.beginCrop()
            m.updateCropDraft(NormRect(x: 0.06, y: 0.21, width: 0.86, height: 0.71))
        })
        scenes.append(editor(.canvas, variant: "crop-mode-snapped", bundle: browserDemo) { m in
            toolbar(m)
            m.beginCrop()
            if let c = m.toolbarCrop { m.updateCropDraft(c) }
        })
        scenes.append(editor(.canvas, variant: "crop-display", bundle: demo) { m in
            m.setCropSuggestionForSnapshot(CropSuggestion(file: "screen/screen.mp4", fileSize: 1, height: 2234, topPixels: 0, confidence: 0))
            m.setCrop(NormRect(x: 0.2, y: 0.1, width: 0.6, height: 0.6), actionName: "x")
        })
        scenes.append(editor(.audio) { m in
            m.setPlayheadForSnapshot(18)
            m.splitAtPlayhead()
            m.setPlayheadForSnapshot(26)
            m.splitAtPlayhead()
            m.selection = .segment(TimeRange(start: 18, end: 26))
            m.change("x") { $0.trim = TimeRange(start: 1.5, end: 44) }
            m.setAudioAnalysisForSnapshot(AudioAnalysis(microphone: TrackLoudness(file: "microphone/microphone.m4a", fileSize: 0,
                                                                                  integratedLUFS: -25.2, peakDBFS: -9, duration: 42)))
        })
        scenes.append(editor(.audio, variant: "enhancing") { m in
            m.change("x") { $0.audio.enhanceStrength = .strong; $0.audio.enhanceMix = 0.8 }
            m.setVoiceStemProgressForSnapshot(0.4)
            m.setAudioAnalysisForSnapshot(AudioAnalysis(microphone: TrackLoudness(file: "voice/voice.caf", fileSize: 0,
                                                                                  integratedLUFS: -19.4, peakDBFS: -6, duration: 42)))
        })
        scenes.append(editor(.captions) { m in
            m.change("x") { $0.captions.file = "captions.vtt" }
            m.setTranscriptForSnapshot(MockData.transcript)
            m.setPlayheadForSnapshot(9.5)
        })
        // Markers dropped while recording: flags on the ruler, and the chapters made from them.
        scenes.append(editor(.captions, variant: "markers") { m in
            m.change("x") {
                $0.markers = [Marker(id: "m1", t: 6.2, title: "Cart"), Marker(id: "m2", t: 17.5, title: "Shipping details"),
                              Marker(id: "m3", t: 33.4, title: "Paying")]
            }
            m.useMarkersAsChapters()
            m.setPlayheadForSnapshot(17.5)
        })
        scenes += OverlayScenes.scenes { section, variant, configure in editor(section, variant: variant, configure: configure) }

        // Export and share
        func editorModel() -> EditorModel? {
            let m = try? EditorModel(bundle: demo, services: services)
            m?.autosaveEnabled = false
            return m
        }
        scenes.append(Scene(name: "export-form", size: nil, backdrop: false) {
            guard let m = editorModel() else { return AnyView(EmptyView()) }
            return AnyView(ExportSheet(model: m, isPresented: .constant(true)))
        })
        scenes.append(Scene(name: "export-running", size: nil, backdrop: false) {
            guard let m = editorModel() else { return AnyView(EmptyView()) }
            m.exportState = .running(0.64)
            return AnyView(ExportSheet(model: m, isPresented: .constant(true)))
        })
        scenes.append(Scene(name: "export-done", size: nil, backdrop: false) {
            guard let m = editorModel() else { return AnyView(EmptyView()) }
            m.exportState = .done(URL(fileURLWithPath: "/Users/me/Movies/Checkout flow walkthrough.mp4"))
            return AnyView(ExportSheet(model: m, isPresented: .constant(true)))
        })
        scenes.append(Scene(name: "share-shared", size: nil, backdrop: false) {
            guard let m = editorModel() else { return AnyView(EmptyView()) }
            try? services.share.saveDestination(ShareDestination(endpoint: "https://acc.r2.cloudflarestorage.com", bucket: "reelbird",
                                                                 accessKeyID: "AKIA", publicBaseURL: "https://pub-3f9a.r2.dev"), secret: "x")
            return AnyView(PopoverChrome { SharePanel(model: m, app: nil).frame(width: 340) })
        })
        scenes.append(Scene(name: "share-new", size: nil, backdrop: false) {
            guard let m = editorModel() else { return AnyView(EmptyView()) }
            var mf = m.manifest
            mf.share = nil
            try? m.bundle.writeManifest(mf)
            let fresh = editorModel()
            try? services.share.saveDestination(ShareDestination(endpoint: "https://acc.r2.cloudflarestorage.com", bucket: "reelbird",
                                                                 accessKeyID: "AKIA", publicBaseURL: "https://pub-3f9a.r2.dev"), secret: "x")
            fresh?.shareState = .working("Uploading", 0.72)
            let view = fresh.map { AnyView(SharePanel(model: $0, app: nil).frame(width: 340)) } ?? AnyView(EmptyView())
            mf.share = ShareInfo(key: "r/7Hk2pQx9aB", url: "https://pub-3f9a.r2.dev/r/7Hk2pQx9aB/", polished: false)
            try? m.bundle.writeManifest(mf)
            return AnyView(PopoverChrome { view })
        })
        scenes.append(Scene(name: "share-setup", size: nil, backdrop: false) {
            guard let m = editorModel() else { return AnyView(EmptyView()) }
            services.share.clearDestination()
            return AnyView(PopoverChrome { SharePanel(model: m, app: nil).frame(width: 340) })
        })

        // Library
        let now = Date()
        let titles: [(String, Double, Double, Bool, Bool)] = [
            ("Checkout flow walkthrough", 46.5, 0.3, true, false), ("Bug: cart total rounds wrong", 92, 3, true, false),
            ("Onboarding v3 review", 214, 26, false, false), ("Release notes 2.4", 61, 50, true, false),
            ("Weekly update", 312, 120, false, true), ("API keys settings demo", 38, 200, false, false),
            ("Design crit, empty states", 145, 340, false, false), ("Figma handoff", 77, 500, false, false),
        ]
        let libraryItems: [LibraryItem] = titles.enumerated().map { i, t in
            LibraryItem(bundle: ProjectBundle(url: work.appendingPathComponent("\(i).reelbird")), title: t.0, duration: t.1,
                        createdAt: now.addingTimeInterval(-t.2 * 3600), shareURL: t.3 ? "https://pub-3f9a.r2.dev/r/x\(i)/" : nil,
                        sharePolished: false, recovered: t.4, cameraIncluded: i % 2 == 0)
        }
        let posters = Dictionary(uniqueKeysWithValues: libraryItems.enumerated().compactMap { i, item -> (URL, CGImage)? in
            MockArt.image(width: 480, height: 300, variant: MockArt.Variant(rawValue: i % 5) ?? .docs, dark: i % 3 == 1).map { (item.id, $0) }
        })
        scenes.append(Scene(name: "library-grid", size: CGSize(width: 1080, height: 700), backdrop: false) {
            let store = LibraryStore(services: services, prefs: prefs)
            store.setForSnapshot(libraryItems, posters: posters)
            return AnyView(LibraryView(store: store, app: nil))
        })
        scenes.append(Scene(name: "library-list", size: CGSize(width: 1080, height: 700), backdrop: false) {
            let store = LibraryStore(services: services, prefs: prefs)
            store.setForSnapshot(libraryItems, posters: posters)
            store.gridLayout = false
            return AnyView(LibraryView(store: store, app: nil))
        })
        scenes.append(Scene(name: "library-multiselect", size: CGSize(width: 1080, height: 700), backdrop: false) {
            let store = LibraryStore(services: services, prefs: prefs)
            store.setForSnapshot(libraryItems, posters: posters)
            store.selection = Set([1, 2, 4].map { libraryItems[$0].id })
            return AnyView(LibraryView(store: store, app: nil))
        })
        scenes.append(Scene(name: "library-multiselect-list", size: CGSize(width: 1080, height: 700), backdrop: false) {
            let store = LibraryStore(services: services, prefs: prefs)
            store.setForSnapshot(libraryItems, posters: posters)
            store.gridLayout = false
            store.selection = Set([1, 2, 3].map { libraryItems[$0].id })
            return AnyView(LibraryView(store: store, app: nil))
        })
        scenes.append(Scene(name: "library-marquee", size: CGSize(width: 1080, height: 700), backdrop: false) {
            let store = LibraryStore(services: services, prefs: prefs)
            store.setForSnapshot(libraryItems, posters: posters)
            store.selection = Set([1, 2, 5, 6].map { libraryItems[$0].id })
            store.marquee = CGRect(x: 380, y: 150, width: 430, height: 270)
            return AnyView(LibraryView(store: store, app: nil))
        })
        scenes.append(Scene(name: "library-hover-menu", size: CGSize(width: 1080, height: 700), backdrop: false) {
            let store = LibraryStore(services: services, prefs: prefs)
            store.setForSnapshot(libraryItems, posters: posters)
            store.selection = [libraryItems[0].id]
            store.snapshotHover = libraryItems[2].id
            return AnyView(LibraryView(store: store, app: nil))
        })
        scenes.append(Scene(name: "library-empty", size: CGSize(width: 1080, height: 700), backdrop: false) {
            AnyView(LibraryView(store: LibraryStore(services: services, prefs: prefs), app: nil))
        })

        // Settings
        for tab in SettingsTab.allCases {
            scenes.append(Scene(name: "settings-\(tab.rawValue)", size: nil, backdrop: false) {
                if tab == .sharing {
                    try? services.share.saveDestination(ShareDestination(endpoint: "https://8f2c0e.r2.cloudflarestorage.com", bucket: "reelbird",
                                                                         accessKeyID: "4f1d9c2a7b", publicBaseURL: "https://pub-3f9a.r2.dev"), secret: "secret")
                }
                return AnyView(SettingsPane(tab: tab, app: model).background(Color(nsColor: .windowBackgroundColor)))
            })
        }

        // A Screen Recording switch that's on in System Settings but doesn't apply (stale entry).
        scenes.append(Scene(name: "settings-permissions-stuck", size: CGSize(width: 640, height: 480), backdrop: false) {
            let stuck = Services.mock(permissions: MockPermissions([.screen: .denied, .microphone: .granted]))
            return AnyView(PermissionsSettings(model: PermissionsModel(services: stuck)).frame(width: 640, height: 480)
                .background(Color(nsColor: .windowBackgroundColor)))
        })

        // Reelbird Cloud in Settings › Sharing
        let cloudScenes: [(String, CloudStatus?, SharingSettingsModel.CloudPhase)] = [
            ("signed-out", nil, .idle),
            ("waiting", nil, .waiting(code: "BKTW-QRNX", url: URL(string: "https://watch.reelbird.app/device?code=BKTW-QRNX")!)),
            ("no-plan", CloudStatus(email: "sam@example.com", isPro: false, enabled: true, linksUsed: 0, linkLimit: 0,
                                    storageUsed: 0, storageLimit: 0, accountURL: nil,
                                    upgradeURL: URL(string: "https://watch.reelbird.app/upgrade")), .idle),
            ("pro", CloudStatus(email: "sam@example.com", isPro: true, enabled: true, linksUsed: 42, linkLimit: nil,
                                storageUsed: 18_400_000_000, storageLimit: 100_000_000_000, accountURL: nil), .idle),
        ]
        for (name, status, phase) in cloudScenes {
            scenes.append(Scene(name: "settings-sharing-cloud-\(name)", size: CGSize(width: 640, height: 520), backdrop: false) {
                let m = SharingSettingsModel(app: nil)
                m.setForSnapshot(target: .cloud, cloud: status, phase: phase)
                return AnyView(SharingSettings(model: m).frame(width: 640, height: 520).background(Color(nsColor: .windowBackgroundColor)))
            })
        }

        // Onboarding
        for step in [OnboardingModel.Step.welcome, .screen, .camera, .done] {
            scenes.append(Scene(name: "onboarding-\(step.rawValue)-\(step)", size: nil, backdrop: false) {
                let perms = MockPermissions([.screen: step == .camera ? .granted : .notDetermined])
                let m = OnboardingModel(app: nil, permissions: perms)
                m.step = step
                return AnyView(OnboardingView(model: m))
            })
        }

        // Live scenes go first: every snapshot window with a spinner keeps an AppKit animation thread
        // alive, and dozens of them starve the dispatch threads the engine's async work needs.
        if live { scenes = liveScenes(prefs: prefs, work: work) + scenes }

        // Menu bar glyphs
        scenes.append(Scene(name: "menubar", size: CGSize(width: 260, height: 60), backdrop: false) {
            AnyView(HStack(spacing: 18) {
                Image(nsImage: BrandImage.menuBar(recording: false))
                HStack(spacing: 4) {
                    Image(nsImage: BrandImage.menuBar(recording: true))
                    Text("1:14").font(.system(size: 12.5, weight: .medium).monospacedDigit())
                }
                Mascot(pose: .recording, size: 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor)))
        })

        var count = 0
        // `filter` may list several name fragments separated by commas.
        let fragments = filter?.split(separator: ",").map(String.init)
        for scene in scenes where fragments == nil || fragments!.contains(where: { scene.name.contains($0) }) {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] where !(scene.lightOnly && suffix == "dark") {
                let url = dir.appendingPathComponent("\(scene.name)-\(suffix).png")
                render(scene, appearance: appearance, to: url)
                count += 1
            }
        }
        print("Wrote \(count) snapshots to \(dir.path)")
    }

    /// `--snapshot <dir> [filter] --live`: the real engine with this Mac's real permission state, on a
    /// synthetic recording (the Metal preview itself doesn't appear in cached snapshots; posters do).
    private static func liveScenes(prefs: Preferences, work: URL) -> [Scene] {
        let services = Services.live()
        let library = work.appendingPathComponent("live-library", isDirectory: true)
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let bundleURL = library.appendingPathComponent("Synthetic take.reelbird")
        var scenes: [Scene] = []
        scenes.append(Scene(name: "live-picker", size: CGSize(width: 620, height: 600), backdrop: true) {
            prefs.sourceTab = .display
            let picker = SourcePickerModel(services: services, prefs: prefs)
            picker.load()
            wait(seconds: 1.5) { !picker.loading }
            return AnyView(SourcePickerView(model: picker, controller: nil, prefs: prefs))
        })
        // The Guide panel on a real recording with clicks (the synthetic take has none):
        // RB_LIVE_GUIDE_BUNDLE=/path/to/take.reelbird ReelbirdApp --snapshot DIR live-guide --live
        if let path = ProcessInfo.processInfo.environment["RB_LIVE_GUIDE_BUNDLE"] {
            let take = ProjectBundle(url: URL(fileURLWithPath: path))
            scenes.append(Scene(name: "live-guide", size: CGSize(width: 1320, height: 840), backdrop: false) {
                guard let m = try? EditorModel(bundle: take, services: services) else { return AnyView(Text("Editor failed")) }
                m.autosaveEnabled = false
                m.attachPlayer()
                m.section = .guide
                m.loadGuide()
                wait(seconds: 90) {
                    let g = m.guidePanel
                    return g.loaded && g.thumbnails.count == g.steps.count && m.filmstrip.count >= 12
                }
                return AnyView(EditorView(model: m, app: nil))
            })
        }
        guard let bundle = recordSynthetic(at: bundleURL, seconds: 6) else {
            print("Couldn't record the synthetic take for live snapshots")
            return scenes
        }
        scenes.append(Scene(name: "live-editor", size: CGSize(width: 1320, height: 840), backdrop: false) {
            guard let m = try? EditorModel(bundle: bundle, services: services) else { return AnyView(Text("Editor failed")) }
            m.autosaveEnabled = false
            m.attachPlayer()
            wait(seconds: 30) { m.filmstrip.count >= 12 && !m.waveform.isEmpty }
            m.setPlayheadForSnapshot(2)
            return AnyView(EditorView(model: m, app: nil))
        })
        scenes.append(Scene(name: "live-library", size: CGSize(width: 1080, height: 700), backdrop: false) {
            let livePrefs = Preferences(defaults: UserDefaults(suiteName: "app.reelbird.snapshots.live")!)
            livePrefs.libraryPath = library.path
            let store = LibraryStore(services: services, prefs: livePrefs)
            store.reload()
            wait(seconds: 30) { store.posters.count == store.items.count }
            return AnyView(LibraryView(store: store, app: nil))
        })
        return scenes
    }

    /// Records generated frames and tones (as fast as the encoder allows) into a new bundle.
    private static func recordSynthetic(at url: URL, seconds: Double) -> ProjectBundle? {
        var options = RecordingOptions(source: .synthetic(name: "snapshot"))
        options.frameRate = 30
        var config = SyntheticFrameSource.Configuration()
        config.frameRate = 30
        config.mode = .asFastAsPossible(duration: seconds)
        let source = SyntheticFrameSource(configuration: config)
        let session = RecordingSession(options: options, bundleURL: url, frameSource: source)
        var result: ProjectBundle?
        var done = false
        Task {
            do {
                try await session.start()
                await source.waitUntilFinished()
                result = try await session.stop()
            } catch {
                print("Synthetic recording failed: \(error.localizedDescription)")
            }
            done = true
        }
        wait(seconds: 60) { done }
        return result
    }

    /// Runs the main run loop until `condition` holds or `seconds` pass.
    private static func wait(seconds: Double, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    private static func render(_ scene: Scene, appearance: NSAppearance.Name, to url: URL) {
        // Dynamic colours resolved while building the scene follow the snapshot's appearance.
        guard let drawing = NSAppearance(named: appearance) else { return }
        drawing.performAsCurrentDrawingAppearance { renderInCurrentAppearance(scene, appearance: appearance, to: url) }
    }

    private static func renderInCurrentAppearance(_ scene: Scene, appearance: NSAppearance.Name, to url: URL) {
        var content = scene.build()
        if scene.backdrop {
            content = AnyView(ZStack { Backdrop(); content })
        }
        let root = content
            .environment(\.isSnapshot, true)
            .tint(Theme.accent)
            .ignoresSafeArea()
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: appearance)
        let size = scene.size ?? hosting.fittingSize
        let w = KeyWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: appearance)
        w.titlebarAppearsTransparent = true
        w.contentView = hosting
        w.setContentSize(size)
        w.orderFrontRegardless()
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            hosting.layoutSubtreeIfNeeded()
        }
        hosting.displayIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        w.orderOut(nil)
        w.contentView = nil
    }
}

/// A popover as it appears over the editor: panel fill, hairline, shadow (the real popover
/// background is drawn by AppKit and doesn't appear in offscreen captures).
private struct PopoverChrome<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
            .padding(28)
            .background(Theme.stage)
    }
}

/// A stand-in desktop behind floating panels.
private struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geo in
            if let img = MockArt.image(width: Int(geo.size.width * 2), height: Int(geo.size.height * 2), variant: .browser, dark: scheme == .dark) {
                Image(decorative: img, scale: 2).resizable()
            }
        }
    }
}

/// Area selection as it looks on screen: dimmed desktop, clear rectangle, size bar.
private struct AreaSnapshot: View {
    var body: some View {
        GeometryReader { geo in
            let r = CGRect(x: 170, y: 110, width: 560, height: 315)
            ZStack(alignment: .topLeading) {
                Path { p in p.addRect(CGRect(origin: .zero, size: geo.size)); p.addRect(r) }
                    .fill(Color.black.opacity(0.38), style: FillStyle(eoFill: true))
                Rectangle().strokeBorder(Theme.accent, lineWidth: 1.5).frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                ForEach(0..<8, id: \.self) { i in
                    let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
                               CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
                    Circle().fill(.white).overlay(Circle().strokeBorder(Theme.accent, lineWidth: 1.5))
                        .frame(width: 10, height: 10).offset(x: pts[i].x - 5, y: pts[i].y - 5)
                }
                AreaBar(pixelSize: CGSize(width: r.width * 2, height: r.height * 2), onCancel: {}, onRecord: {})
                    .fixedSize()
                    .offset(x: r.midX - 120, y: r.maxY + 12)
            }
        }
    }
}
