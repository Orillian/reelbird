import AppKit
import Observation
import ReelbirdCapture
import ReelbirdCore
import SwiftUI

// MARK: Sharing

@MainActor @Observable final class SharingSettingsModel {
    /// Where new links go.
    enum Target: Hashable { case cloud, bucket }
    var target: Target = .cloud
    /// The tab to show next time the pane opens (or now, with `showTarget`), from a share prompt.
    static var requestedTarget: Target?
    static let showTarget = Notification.Name("app.reelbird.sharing.showTarget")

    // Reelbird Cloud
    private(set) var cloud: CloudStatus?
    enum CloudPhase: Equatable { case idle, starting, waiting(code: String, url: URL), failed(String) }
    private(set) var cloudPhase: CloudPhase = .idle
    @ObservationIgnored private var signInTask: Task<Void, Never>?

    // Your own bucket
    var endpoint = ""
    var bucket = ""
    var region = "auto"
    var accessKeyID = ""
    var secret = ""
    var publicBaseURL = ""
    var prefix = "r"
    enum TestState: Equatable { case idle, testing, ok, failed(String) }
    var test: TestState = .idle
    var saved = false
    private(set) var hasSaved = false

    @ObservationIgnored private let app: AppModel?
    /// Reelbird Cloud is offered (hidden until the hosted service launches).
    let cloudAvailable: Bool

    init(app: AppModel?) {
        self.app = app
        cloudAvailable = app?.services.cloud.isAvailable ?? true
        if let (d, secret) = app?.services.share.ownBucket() {
            endpoint = d.endpoint; bucket = d.bucket; region = d.region; accessKeyID = d.accessKeyID
            publicBaseURL = d.publicBaseURL; prefix = d.prefix
            self.secret = secret ?? ""
            hasSaved = true
        }
        cloud = app?.services.cloud.status()
        // Show what new links use: your bucket only when it's set up and Cloud is off.
        target = cloudAvailable && ((cloud?.enabled ?? false) || !hasSaved) ? .cloud : .bucket
        showRequestedTarget()
        refreshCloud()
    }

    /// Shows the tab a share prompt asked for. Only shows it: choosing happens in the pane.
    func showRequestedTarget() {
        if let t = Self.requestedTarget { target = cloudAvailable ? t : .bucket; Self.requestedTarget = nil }
    }

    func choose(_ t: Target) {
        target = t
        guard let app else { return }
        if t == .cloud, cloud != nil {
            try? app.services.cloud.setEnabled(true)
        } else if t == .bucket {
            try? app.services.cloud.setEnabled(false)
        }
        cloud = app.services.cloud.status() ?? cloud
        app.refreshShareState()
    }

    func refreshCloud() {
        guard let app, cloud != nil else { return }
        Task {
            if let s = try? await app.services.cloud.refresh() { cloud = s }
            app.refreshShareState()
        }
    }

    func signIn() {
        guard let app else { return }
        signInTask?.cancel()
        cloudPhase = .starting
        signInTask = Task {
            do {
                let code = try await app.services.cloud.beginSignIn()
                cloudPhase = .waiting(code: code.userCode, url: code.verifyURL)
                NSWorkspace.shared.open(code.verifyURL)
                cloud = try await code.wait()
                cloudPhase = .idle
                target = .cloud
                app.refreshShareState()
                refreshCloud()
            } catch is CancellationError {
                cloudPhase = .idle
            } catch {
                cloudPhase = Task.isCancelled ? .idle : .failed((error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        cloudPhase = .idle
    }

    func signOut() {
        guard let app else { return }
        Task {
            await app.services.cloud.signOut()
            cloud = nil
            app.refreshShareState()
        }
    }

    /// Snapshots only.
    func setForSnapshot(target: Target, cloud: CloudStatus?, phase: CloudPhase = .idle) {
        self.target = target
        self.cloud = cloud
        cloudPhase = phase
    }

    func openAccount() {
        if let url = cloud?.accountURL { NSWorkspace.shared.open(url) }
    }

    /// Opens Stripe checkout for Pro; the plan updates when Settings is next shown.
    func upgrade() {
        if let url = cloud?.upgradeURL { NSWorkspace.shared.open(url) }
    }

    var destination: ShareDestination {
        ShareDestination(endpoint: endpoint.trimmingCharacters(in: .whitespaces), bucket: bucket.trimmingCharacters(in: .whitespaces),
                         region: region.isEmpty ? "auto" : region, accessKeyID: accessKeyID.trimmingCharacters(in: .whitespaces),
                         publicBaseURL: publicBaseURL.trimmingCharacters(in: .whitespaces), prefix: prefix.isEmpty ? "r" : prefix)
    }

    var complete: Bool { !endpoint.isEmpty && !bucket.isEmpty && !accessKeyID.isEmpty && !secret.isEmpty && !publicBaseURL.isEmpty }

    func runTest() {
        guard let app else { return }
        test = .testing
        let d = destination, s = secret
        Task {
            do {
                try await app.services.share.testConnection(d, secret: s)
                test = .ok
            } catch {
                test = .failed((error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func save() {
        guard let app else { return }
        do {
            try app.services.share.saveDestination(destination, secret: secret)
            cloud = app.services.cloud.status() ?? cloud
            app.refreshShareState()
            hasSaved = true
            saved = true
        } catch {
            test = .failed("Couldn't save to the Keychain: \(error.localizedDescription)")
        }
    }

    func remove() {
        app?.services.share.clearDestination()
        app?.refreshShareState()
        endpoint = ""; bucket = ""; accessKeyID = ""; secret = ""; publicBaseURL = ""; prefix = "r"; region = "auto"
        hasSaved = false
        test = .idle
    }
}

struct SharingSettings: View {
    @Bindable var model: SharingSettingsModel

    var body: some View {
        SettingsForm {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    if model.cloudAvailable {
                        PillTabs(selection: Binding(get: { model.target }, set: { model.choose($0) }), items: [
                            .init(value: .cloud, title: "Reelbird Pro", symbol: "cloud"),
                            .init(value: .bucket, title: "Your own bucket", symbol: "externaldrive"),
                        ])
                    }
                    Text(model.target == .cloud
                         ? "Reelbird hosts your links on watch.reelbird.app and shows how many people watched. Nothing to set up: Share just works."
                         : model.cloudAvailable
                            ? "Links upload to a storage bucket you own. Nothing goes through Reelbird's servers. Free forever."
                            : "Links upload to a storage bucket you own. Nothing goes through Reelbird's servers, because there aren't any.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.target == .cloud { cloudSections } else { bucketSections }
        }
        .onChange(of: model.destination) { _, _ in model.saved = false; if model.test != .testing { model.test = .idle } }
        // Back from the browser (after upgrading or managing the account): show the new plan.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshCloud() }
        .onReceive(NotificationCenter.default.publisher(for: SharingSettingsModel.showTarget)) { _ in model.showRequestedTarget() }
    }

    // MARK: Reelbird Cloud

    @ViewBuilder private var cloudSections: some View {
        if let c = model.cloud {
            Section("Account") {
                LabeledContent("Signed in as") { Text(c.email) }
                if c.isPro {
                    if let used = c.linksUsed {
                        LabeledContent("Links") { Text("\(used)").monospacedDigit() }
                    }
                    if let used = c.storageUsed, let limit = c.storageLimit, limit > 0 {
                        LabeledContent("Storage") {
                            HStack(spacing: 8) {
                                ProgressView(value: min(1, Double(used) / Double(limit))).frame(width: 120).tint(Theme.accent)
                                Text("\(Self.bytes(used)) of \(Self.bytes(limit))").monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    LabeledContent("Analytics") {
                        Text("Views, retention and sources for every link").foregroundStyle(.secondary)
                    }
                } else {
                    proPitch
                }
            }
            Section {
                HStack(spacing: Theme.Space.s) {
                    if c.isPro && !c.enabled { StatusLine(tone: .info, text: "New links go to your own bucket.") }
                    if !c.isPro { StatusLine(tone: .info, text: "Recording, editing and exporting are free. Pro is only for hosted links.") }
                    Spacer()
                    Button("Sign Out…") { confirmSignOut() }
                    if c.isPro {
                        Button("Manage Account") { model.openAccount() }
                            .buttonStyle(PrimaryButtonStyle())
                    } else {
                        Button("Upgrade to Pro") { model.upgrade() }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(c.upgradeURL == nil)
                    }
                }
            }
        } else {
            Section { proPitch.padding(.vertical, 2) }
            Section {
                switch model.cloudPhase {
                case .waiting(let code, let url):
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Approve this code in your browser").font(.system(size: 12, weight: .medium))
                        Text(code)
                            .font(.system(size: 22, weight: .semibold, design: .monospaced)).tracking(2)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fieldFill))
                            .textSelection(.enabled)
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for approval…").font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { model.cancelSignIn() }
                            Button("Open Browser Again") { NSWorkspace.shared.open(url) }
                        }
                    }
                default:
                    HStack(spacing: Theme.Space.s) {
                        if case .failed(let m) = model.cloudPhase { StatusLine(tone: .error, text: m) }
                        if model.cloudPhase == .starting { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("Sign In…") { model.signIn() }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(model.cloudPhase == .starting)
                    }
                }
            }
        }
    }

    /// What Pro is, in one place (signed out, and signed in without Pro).
    private var proPitch: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Reelbird Pro · $5 a month").font(.system(size: 12, weight: .semibold))
            Text("Share from Reelbird with nothing to set up: unlimited links, 100 GB of video, and anonymous analytics: how many people watched, where they stopped and where they came from. Cancel any time.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func confirmSignOut() {
        let alert = NSAlert()
        alert.messageText = "Sign out of Reelbird Pro?"
        alert.informativeText = "Your hosted links keep playing. To host new links again, sign back in."
        alert.addButton(withTitle: "Sign Out")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { model.signOut() }
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    // MARK: Your own bucket

    @ViewBuilder private var bucketSections: some View {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    DisclosureGroup("How to set up Cloudflare R2") {
                        VStack(alignment: .leading, spacing: 5) {
                            step(1, "In Cloudflare, open R2 and create a bucket, e.g. “reelbird”.")
                            step(2, "In the bucket's Settings, turn on the public r2.dev URL (or connect your own domain) and copy it.")
                            step(3, "Create an R2 API token with Object Read & Write for that bucket. Copy the keys; the secret is shown once.")
                            step(4, "Paste everything below, then click Test Connection.")
                            Link("Full guide", destination: URL(string: ReelbirdInfo.repositoryURL + "/blob/main/docs/SHARING.md")!)
                                .font(.system(size: 12)).foregroundStyle(Theme.accentText).padding(.top, 2)
                        }
                        .padding(.top, 6)
                    }
                    .font(.system(size: 12, weight: .medium))
                }
            }
            Section("Bucket") {
                TextField("Endpoint", text: $model.endpoint, prompt: Text("https://<account>.r2.cloudflarestorage.com"))
                TextField("Bucket", text: $model.bucket, prompt: Text("reelbird"))
                TextField("Region", text: $model.region, prompt: Text("auto"))
                TextField("Access key ID", text: $model.accessKeyID)
                SecureField("Secret access key", text: $model.secret, prompt: Text("Stored in your Keychain"))
            }
            Section("Links") {
                TextField("Public URL", text: $model.publicBaseURL, prompt: Text("https://pub-….r2.dev"))
                TextField("Prefix", text: $model.prefix, prompt: Text("r"))
                if !model.publicBaseURL.isEmpty {
                    LabeledContent("Links look like") {
                        Text("\(model.publicBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(model.prefix)/7Hk2pQx9aB/")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            Section {
                HStack(spacing: Theme.Space.s) {
                    testResult
                    Spacer()
                    if model.hasSaved {
                        Button("Remove…", role: .destructive) { confirmRemove() }
                    }
                    Button("Test Connection") { model.runTest() }
                        .disabled(!model.complete || model.test == .testing)
                    Button(model.saved ? "Saved" : "Save") { model.save() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!model.complete)
                }
            }
    }

    private func confirmRemove() {
        let alert = NSAlert()
        alert.messageText = "Remove this bucket from Reelbird?"
        alert.informativeText = "Reelbird forgets these settings and deletes the secret from your Keychain. Links you already shared keep working; nothing in the bucket is deleted."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { model.remove() }
    }

    @ViewBuilder private var testResult: some View {
        switch model.test {
        case .idle: EmptyView()
        case .testing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Uploading a test file…").font(.system(size: 12)).foregroundStyle(.secondary) }
        case .ok: StatusLine(tone: .success, text: "Connected. Reelbird can upload and your public URL serves files.")
        case .failed(let m): StatusLine(tone: .error, text: m)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary).frame(width: 12)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Permissions

@MainActor @Observable final class PermissionsModel {
    private(set) var states: [Permission: PermissionState] = [:]
    /// Screen Recording was asked for or reset here: macOS applies it after Reelbird reopens.
    private(set) var screenNeedsRelaunch = false
    @ObservationIgnored let services: Services
    @ObservationIgnored private var timer: Timer?

    init(services: Services) {
        self.services = services
        refresh()
    }

    func refresh() {
        for p in Permission.allCases { states[p] = services.permissions.status(p) }
    }

    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopPolling() { timer?.invalidate(); timer = nil }

    /// Permissions whose System Settings switch can show on while not applying to this copy.
    static let resettable: Set<Permission> = [.screen, .accessibility, .inputMonitoring]

    /// Clears Reelbird's own (stale) entry and asks again.
    func resetAndAsk(_ p: Permission) {
        _ = services.permissions.reset(p)
        refresh()
        if p == .screen { screenNeedsRelaunch = true }
        request(p)
    }

    func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    func request(_ p: Permission) {
        if p == .screen { screenNeedsRelaunch = true }
        if states[p] == .notDetermined && p != .screen {
            Task { _ = await services.permissions.request(p); refresh() }
        } else {
            if p == .screen && states[p] == .notDetermined { Task { _ = await services.permissions.request(.screen); refresh() } }
            services.permissions.openSettings(for: p)
        }
    }
}

struct PermissionInfo {
    let permission: Permission
    let title: String
    let detail: String
    let symbol: String
    let required: Bool

    static let shown: [PermissionInfo] = [
        .init(permission: .screen, title: "Screen Recording", detail: "To record your screen or a window.", symbol: "rectangle.dashed.badge.record", required: true),
        .init(permission: .microphone, title: "Microphone", detail: "To record your voice.", symbol: "mic", required: false),
        .init(permission: .camera, title: "Camera", detail: "To show your face in a bubble.", symbol: "video", required: false),
        .init(permission: .inputMonitoring, title: "Input Monitoring", detail: "To show the keys you press, if you turn on keystrokes.", symbol: "keyboard", required: false),
    ]
}

struct PermissionsSettings: View {
    let model: PermissionsModel

    var body: some View {
        SettingsForm {
            Section {
                ForEach(PermissionInfo.shown, id: \.permission) { info in
                    let state = model.states[info.permission] ?? .notDetermined
                    PermissionRow(info: info, state: state,
                                  reset: state == .denied && PermissionsModel.resettable.contains(info.permission)
                                      ? { model.resetAndAsk(info.permission) } : nil) { model.request(info.permission) }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reelbird checks again whenever you come back from System Settings. Screen Recording takes effect after Reelbird reopens.")
                    if PermissionsModel.resettable.contains(where: { model.states[$0] == .denied }) {
                        Text("On in System Settings but Off here? Click Reset: it clears an entry left by an earlier copy of Reelbird, and macOS asks again.")
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.screenNeedsRelaunch && model.states[.screen] != .granted {
                Section {
                    HStack {
                        StatusLine(tone: .info, text: "Turned Screen Recording on? macOS applies it after Reelbird reopens.")
                        Spacer()
                        Button("Quit & Reopen") { model.relaunch() }
                    }
                }
            }
        }
        .onAppear { model.refresh(); model.startPolling() }
        .onDisappear { model.stopPolling() }
    }
}

struct PermissionRow: View {
    let info: PermissionInfo
    let state: PermissionState
    /// Shown for a permission that may be stuck on a stale entry.
    var reset: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: info.symbol)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.fieldFill))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(info.title).font(.system(size: 13, weight: .medium))
                    if !info.required { Text("Optional").font(.system(size: 10.5)).foregroundStyle(.tertiary) }
                }
                Text(info.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            badge
            if let reset {
                Button("Reset", action: reset)
                    .help("Switched on in System Settings but still Off here? This clears Reelbird's old entry so macOS can ask again.")
            }
            if state != .granted {
                Button(state == .notDetermined ? "Allow…" : "Open Settings", action: action)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var badge: some View {
        let (text, color): (String, Color) = switch state {
        case .granted: ("Allowed", Theme.success)
        case .denied: ("Off", Theme.warning)
        case .notDetermined: ("Not set", .secondary)
        }
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(state == .granted ? .secondary : color)
        }
    }
}

// MARK: About

struct AboutSettings: View {
    let app: AppModel?
    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Mascot(pose: .idle, size: 96).padding(.top, Theme.Space.l)
            BrandLogo(height: 26).padding(.top, -6)
            Text("Version \(ReelbirdInfo.version)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            Text("Free and open source under the MIT licence.\nRecordings stay on your Mac unless you share them.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: Theme.Space.s) {
                Button("Website") { open(ReelbirdInfo.websiteURL) }
                    .buttonStyle(SecondaryButtonStyle())
                Button("GitHub") { open(ReelbirdInfo.repositoryURL) }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Welcome Tour") { app?.showOnboarding() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.top, Theme.Space.s)
            .padding(.bottom, Theme.Space.xl)
        }
        .frame(width: 560)
    }

    private func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
}
