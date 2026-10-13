import AppKit
import Observation
import ReelbirdCapture
import ReelbirdCore
import SwiftUI

@MainActor @Observable final class OnboardingModel {
    enum Step: Int, CaseIterable { case welcome, screen, microphone, camera, keystrokes, done }
    var step: Step = .welcome
    private(set) var states: [Permission: PermissionState] = [:]
    /// Screen permission was granted in System Settings but macOS applies it only after a relaunch.
    private(set) var needsRelaunch = false
    @ObservationIgnored let app: AppModel?
    @ObservationIgnored private let permissions: any PermissionsService
    @ObservationIgnored private var timer: Timer?
    /// Live test after granting: mic level and the available devices.
    private(set) var micLevel: Double = 0
    private(set) var microphones: [MediaDevice] = []
    private(set) var cameras: [MediaDevice] = []

    init(app: AppModel?, permissions: (any PermissionsService)? = nil) {
        self.app = app
        self.permissions = permissions ?? app?.services.permissions ?? MockPermissions()
        refresh()
    }

    func refresh() {
        for p in Permission.allCases { states[p] = permissions.status(p) }
    }

    func state(_ p: Permission) -> PermissionState { states[p] ?? .notDetermined }

    // MARK: Device test

    var microphoneID: String {
        get { app?.prefs.microphoneID ?? "default" }
        set { app?.prefs.microphoneID = newValue; startMicTest() }
    }

    var cameraID: String {
        get { app?.prefs.cameraID ?? cameras.first(where: \.isDefault)?.id ?? cameras.first?.id ?? "" }
        set { app?.prefs.cameraID = newValue }
    }

    func startMicTest() {
        guard let services = app?.services else { return }
        microphones = services.capture.microphones()
        services.inputs.startMicrophoneMeter(deviceID: microphoneID) { [weak self] level in self?.micLevel = level }
    }

    func stopMicTest() {
        app?.services.inputs.stopMicrophoneMeter()
        micLevel = 0
    }

    func loadCameras() {
        cameras = app?.services.capture.cameras() ?? []
    }

    func makeCameraView() -> NSView {
        app?.services.inputs.makeCameraView(deviceID: cameraID) ?? NSView()
    }

    func next() {
        guard let n = Step(rawValue: step.rawValue + 1) else { finish(); return }
        withAnimation(Theme.gentle) { step = n }
        if n == .done { app?.prefs.onboardingDone = true }
    }

    func back() {
        guard let p = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation(Theme.gentle) { step = p }
    }

    func request(_ p: Permission) {
        Task {
            let result = await permissions.request(p)
            refresh()
            if p == .screen && result != .granted {
                // macOS shows its own prompt or sends people to System Settings; keep checking.
                permissions.openSettings(for: .screen)
                startPolling()
            } else if p == .inputMonitoring && result != .granted {
                // Already refused once: macOS only allows it in System Settings now.
                if result == .denied { permissions.openSettings(for: .inputMonitoring) }
                startPolling()
            } else if result == .granted {
                if p == .inputMonitoring { app?.prefs.captureKeystrokes = true }
                // Mic and camera stay on their step so people can check them; the rest move on.
                if p != .microphone && p != .camera { next() }
            }
        }
    }

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
                // Screen Recording often reports "not allowed" until the app restarts, even after
                // the switch is on. Offer the relaunch once the user has been to Settings.
                if self.step == .screen && self.state(.screen) != .granted { self.needsRelaunch = true }
                if self.state(self.step.permission ?? .screen) == .granted { self.timer?.invalidate() }
            }
        }
    }

    func relaunch() {
        app?.prefs.onboardingDone = false // come back to the screen step's successor
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    func finish() {
        app?.prefs.onboardingDone = true
        app?.windows.closeOnboarding()
    }
}

extension OnboardingModel.Step {
    var permission: Permission? {
        switch self {
        case .screen: .screen
        case .microphone: .microphone
        case .camera: .camera
        case .keystrokes: .inputMonitoring
        default: nil
        }
    }
}

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            progress
                .padding(.top, 22)
            Group {
                switch model.step {
                case .welcome: welcome
                case .screen:
                    permissionStep(.screen, title: "Let Reelbird see your screen",
                                   body: "macOS asks before any app can record the screen. Reelbird only records when you press Record, and recordings stay on your Mac.",
                                   allow: "Allow Screen Recording", optional: false)
                case .microphone:
                    permissionStep(.microphone, title: "Record your voice",
                                   body: "Talk people through what you're showing. Reelbird warns you during a take if the mic goes quiet.",
                                   allow: "Allow Microphone", optional: true)
                case .camera:
                    permissionStep(.camera, title: "Add your face",
                                   body: "A small camera bubble makes walkthroughs feel personal. You can move, resize or hide it after recording.",
                                   allow: "Allow Camera", optional: true)
                case .keystrokes:
                    permissionStep(.inputMonitoring, title: "Show your shortcuts",
                                   body: "With Input Monitoring, Reelbird can show the keys you press in your videos. It only listens while you record, and you can turn keystrokes off in Settings.",
                                   allow: "Allow Input Monitoring", optional: true)
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 56)
            .id(model.step)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity))
        }
        .frame(width: 620, height: 520)
        .background(Theme.panel)
        .tint(Theme.accent)
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= model.step.rawValue ? Theme.ink : Color.primary.opacity(0.12))
                    .frame(width: s == model.step ? 22 : 8, height: 6)
            }
        }
        .animation(Theme.gentle, value: model.step)
        .accessibilityElement()
        .accessibilityLabel("Step \(model.step.rawValue + 1) of \(OnboardingModel.Step.allCases.count)")
    }

    private var welcome: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer()
            Mascot(pose: .idle, size: 140)
            VStack(spacing: Theme.Space.s) {
                Text("Meet Reelbird").font(.system(size: 26, weight: .bold))
                Text("Record your screen, your voice and your face. Get a link the moment you stop, and a polished video whenever you want one.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Get Started") { model.next() }
                .buttonStyle(PrimaryButtonStyle(large: true))
                .keyboardShortcut(.defaultAction)
            Text("Takes about a minute. Free and open source.")
                .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                .padding(.bottom, 36)
        }
    }

    private func permissionStep(_ p: Permission, title: String, body: String, allow: String, optional: Bool) -> some View {
        let state = model.state(p)
        return VStack(spacing: Theme.Space.l) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.fieldFill)
                    .frame(width: 96, height: 96)
                Image(systemName: symbol(p))
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(Theme.ink)
                if state == .granted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white, Theme.success)
                        .offset(x: 40, y: 40)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(Theme.gentle, value: state)
            VStack(spacing: Theme.Space.s) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 22, weight: .bold))
                    if optional { Text("Optional").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.fieldFill)) }
                }
                Text(body)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state == .granted && p == .microphone { MicrophoneTest(model: model) }
            if state == .granted && p == .camera { CameraTest(model: model) }
            if p == .screen && model.needsRelaunch && state != .granted {
                VStack(spacing: 6) {
                    StatusLine(tone: .info, text: "Turned it on? macOS applies it after Reelbird reopens.")
                    Button("Quit & Reopen") { model.relaunch() }.buttonStyle(SecondaryButtonStyle())
                }
            }
            Spacer()
            HStack(spacing: Theme.Space.m) {
                Button("Back") { model.back() }.buttonStyle(SecondaryButtonStyle(large: true))
                Spacer()
                if state == .granted {
                    Button("Continue") { model.next() }
                        .buttonStyle(PrimaryButtonStyle(large: true))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(optional ? "Not Now" : "Skip for Now") { model.next() }
                        .buttonStyle(.link)
                        .foregroundStyle(.secondary)
                    Button(allow) { model.request(p) }
                        .buttonStyle(PrimaryButtonStyle(large: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.bottom, 36)
        }
    }

    private var done: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer()
            Mascot(pose: .celebrating, size: 140)
            VStack(spacing: Theme.Space.s) {
                Text("You're ready").font(.system(size: 26, weight: .bold))
                HStack(spacing: 5) {
                    Text("Press")
                    Keycap(text: model.app?.prefs.recordHotKey.display ?? HotKey.defaultRecord.display)
                    Text("from any app to record.")
                }
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                Text("Reelbird lives in your menu bar.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: Theme.Space.m) {
                Button("Open Library") { model.finish(); model.app?.openLibrary() }
                    .buttonStyle(SecondaryButtonStyle(large: true))
                Button("Start a Recording") { model.finish(); model.app?.newRecording() }
                    .buttonStyle(PrimaryButtonStyle(large: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 36)
        }
    }

    private func symbol(_ p: Permission) -> String {
        switch p {
        case .screen: "rectangle.dashed.badge.record"
        case .microphone: "mic"
        case .camera: "video"
        case .inputMonitoring, .accessibility: "keyboard"
        }
    }
}

/// After the mic is allowed: pick a device and watch the meter move while you talk.
private struct MicrophoneTest: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "mic.fill").foregroundStyle(.secondary)
                LevelMeter(level: model.micLevel, segments: 18, height: 8)
                    .frame(width: 180)
                DeviceMenu(devices: model.microphones, selection: $model.microphoneID)
            }
            Text(model.micLevel > 0.05 ? "Sounds good." : "Say something. The bars should move.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .animation(Theme.gentle, value: model.micLevel > 0.05)
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fieldFill))
        .onAppear { model.startMicTest() }
        .onDisappear { model.stopMicTest() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Microphone test")
    }
}

/// After the camera is allowed: a live preview of the bubble and a device menu.
private struct CameraTest: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        HStack(spacing: Theme.Space.l) {
            CameraPreviewRepresentable(make: { model.makeCameraView() })
                .id(model.cameraID)
                .frame(width: 96, height: 96)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
            VStack(alignment: .leading, spacing: 6) {
                Text("This is how you'll look in the bubble.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                DeviceMenu(devices: model.cameras, selection: $model.cameraID)
            }
        }
        .padding(Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fieldFill))
        .onAppear { model.loadCameras() }
    }
}

private struct CameraPreviewRepresentable: NSViewRepresentable {
    let make: () -> NSView
    func makeNSView(context: Context) -> NSView { make() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
