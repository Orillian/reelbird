import AppKit
import ReelbirdCore
import SwiftUI

/// `ReelbirdApp --snapshot <dir> [filter]`: renders every key view with mock data to PNGs in
/// light and dark, without screen-recording permission. Used for design review.
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
    }

    static func run(dir: URL, filter: String?) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: "app.reelbird.snapshots")!
        defaults.removePersistentDomain(forName: "app.reelbird.snapshots")
        let prefs = Preferences(defaults: defaults)
        prefs.cameraEnabled = true
        prefs.cameraID = "facetime"
        prefs.lastArea = CGRect(x: 320, y: 180, width: 960, height: 540)
        let permissions = MockPermissions([.screen: .granted, .microphone: .granted, .camera: .notDetermined, .accessibility: .denied])
        let services = Services.mock(permissions: permissions)
        let model = AppModel(services: services, prefs: prefs)

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("reelbird-snapshots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let demoURL = work.appendingPathComponent("Checkout flow walkthrough.reelbird")
        guard let demo = try? MockData.writeDemoBundle(at: demoURL, title: "Checkout flow walkthrough", duration: 46.5,
                                                       share: ShareInfo(key: "r/7Hk2pQx9aB", url: "https://pub-3f9a.r2.dev/r/7Hk2pQx9aB/", polished: false))
        else { print("Couldn't write demo bundle"); return }

        let sources = MockCaptureSources.sources(withThumbnails: true)
        var scenes: [Scene] = []

        // Source picker
        for tab in SourceTab.allCases {
            scenes.append(Scene(name: "picker-\(tab.rawValue)", size: CGSize(width: 620, height: 600), backdrop: true) {
                prefs.sourceTab = tab
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
        scenes.append(Scene(name: "controlbar-paused", size: CGSize(width: 620, height: 170), backdrop: true) {
            AnyView(ControlBarView(controller: nil, prefs: prefs, status: status(elapsed: 202, level: 0, share: true), phase: .paused))
        })
        scenes.append(Scene(name: "countdown", size: CGSize(width: 900, height: 560), backdrop: true) {
            AnyView(CountdownView(controller: model.recording, value: 2).background(Color.black.opacity(0.25)))
        })
        scenes.append(Scene(name: "area-bar", size: CGSize(width: 900, height: 560), backdrop: true) {
            AnyView(AreaSnapshot())
        })
        scenes.append(Scene(name: "toast", size: CGSize(width: 520, height: 140), backdrop: true) {
            AnyView(ToastView(title: "Link copied", detail: "Still uploading 2 segments…", symbol: "link"))
        })
        scenes.append(Scene(name: "camera-bubble", size: CGSize(width: 320, height: 300), backdrop: true) {
            AnyView(CameraBubbleView(camera: MockCameraView(frame: .zero), size: .medium, onResize: { _ in }).frame(width: 212, height: 212))
        })

        // Editor
        func editor(_ section: InspectorSection, configure: @escaping (EditorModel) -> Void = { _ in }) -> Scene {
            Scene(name: "editor-\(section.rawValue)", size: CGSize(width: 1320, height: 840), backdrop: false) {
                guard let m = try? EditorModel(bundle: demo, services: services) else { return AnyView(Text("Editor failed")) }
                m.attachPlayer()
                m.setTimelineMediaForSnapshot(waveform: MockArt.waveform(count: 600, seed: 3),
                                              filmstrip: (0..<6).compactMap { MockArt.image(width: 160, height: 100, variant: MockArt.Variant(rawValue: $0 % 5) ?? .docs) })
                m.section = section
                m.setPlayheadForSnapshot(12.6)
                configure(m)
                return AnyView(EditorView(model: m, app: nil))
            }
        }
        scenes.append(editor(.background))
        scenes.append(editor(.cursor) { m in m.change("x") { $0.cursor.showKeystrokes = true } })
        scenes.append(editor(.zoom) { m in
            m.addZoomAtPlayhead()
            m.setPlayheadForSnapshot(13.6)
        })
        scenes.append(editor(.camera) { m in m.change("x") { $0.camera.shape = .roundedRect; $0.canvas.aspect = .wide } })
        scenes.append(editor(.canvas) { m in m.change("x") { $0.canvas.aspect = .vertical } })
        scenes.append(editor(.audio) { m in
            m.setPlayheadForSnapshot(18)
            m.splitAtPlayhead()
            m.setPlayheadForSnapshot(26)
            m.splitAtPlayhead()
            m.selection = .segment(TimeRange(start: 18, end: 26))
            m.change("x") { $0.trim = TimeRange(start: 1.5, end: 44) }
        })
        scenes.append(editor(.captions) { m in
            m.change("x") { $0.captions.file = "captions.vtt" }
            m.setTranscriptForSnapshot(MockData.transcript)
            m.setPlayheadForSnapshot(9.5)
        })

        // Export and share
        func editorModel() -> EditorModel? {
            let m = try? EditorModel(bundle: demo, services: services)
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
            return AnyView(SharePanel(model: m, app: nil).frame(width: 340))
        })
        scenes.append(Scene(name: "share-setup", size: nil, backdrop: false) {
            guard let m = editorModel() else { return AnyView(EmptyView()) }
            services.share.clearDestination()
            return AnyView(SharePanel(model: m, app: nil).frame(width: 340))
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

        // Onboarding
        for step in [OnboardingModel.Step.welcome, .screen, .camera, .done] {
            scenes.append(Scene(name: "onboarding-\(step.rawValue)-\(step)", size: nil, backdrop: false) {
                let perms = MockPermissions([.screen: step == .camera ? .granted : .notDetermined])
                let m = OnboardingModel(app: nil, permissions: perms)
                m.step = step
                return AnyView(OnboardingView(model: m))
            })
        }

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
        for scene in scenes where filter == nil || scene.name.contains(filter!) {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let url = dir.appendingPathComponent("\(scene.name)-\(suffix).png")
                render(scene, appearance: appearance, to: url)
                count += 1
            }
        }
        print("Wrote \(count) snapshots to \(dir.path)")
    }

    private static func render(_ scene: Scene, appearance: NSAppearance.Name, to url: URL) {
        NSAppearance.current = NSAppearance(named: appearance)
        var content = scene.build()
        if scene.backdrop {
            content = AnyView(ZStack { Backdrop(); content })
        }
        let root = content
            .environment(\.isSnapshot, true)
            .tint(Theme.accent)
        let hosting = NSHostingView(rootView: root)
        let size = scene.size ?? hosting.fittingSize
        let w = KeyWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                          styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
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
