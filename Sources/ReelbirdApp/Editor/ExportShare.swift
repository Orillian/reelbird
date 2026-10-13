import AppKit
import ReelbirdCore
import ReelbirdRender
import SwiftUI

// MARK: Export sheet

struct ExportSheet: View {
    @Bindable var model: EditorModel
    @Binding var isPresented: Bool
    @ViewState private var format: ExportOptions.Format = .mp4H264
    @ViewState private var height: Int? = 1080
    @ViewState private var fps: Int? = nil
    /// Export folder, remembered between exports. Empty = Downloads.
    @AppStorage("exportFolderPath") private var exportFolderPath = ""

    private var destination: URL {
        exportFolderPath.isEmpty
            ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            : URL(fileURLWithPath: exportFolderPath, isDirectory: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.exportState {
            case .idle: form
            case .running(let p): running(p)
            case .done(let url): done(url)
            case .failed(let msg): failed(msg)
            }
        }
        .frame(width: 440)
        .background(Theme.panel)
        .animation(Theme.gentle, value: model.exportState)
        .onAppear {
            // A format picked in the command menu ("Export as GIF…").
            if let f = model.pendingExportFormat { format = f; model.pendingExportFormat = nil }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("Export").font(.system(size: 17, weight: .semibold))
            PillTabs(selection: $format, items: [
                .init(value: .mp4H264, title: "MP4", symbol: nil),
                .init(value: .mp4HEVC, title: "HEVC", symbol: nil),
                .init(value: .proRes, title: "ProRes", symbol: nil),
                .init(value: .gif, title: "GIF", symbol: nil),
            ])
            .onChange(of: format) { _, f in
                if f == .gif { height = 480; fps = 15 } else if fps == 15 || fps == 24 { fps = nil; height = 1080 }
            }
            Text(formatHelp).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            VStack(spacing: Theme.Space.s) {
                FieldRow(label: "Resolution", labelWidth: 92) {
                    Picker("Resolution", selection: $height) {
                        if format != .gif {
                            Text("Original (\(model.manifest.capture.pixelSize.height)p)").tag(Int?.none)
                            Text("4K (2160p)").tag(Int?.some(2160))
                            Text("1440p").tag(Int?.some(1440))
                        }
                        Text("1080p").tag(Int?.some(1080))
                        Text("720p").tag(Int?.some(720))
                        if format == .gif { Text("480p").tag(Int?.some(480)) }
                    }
                    .labelsHidden().fixedSize()
                }
                FieldRow(label: "Frame rate", labelWidth: 92) {
                    Picker("Frame rate", selection: $fps) {
                        if format == .gif {
                            Text("15 fps").tag(Int?.some(15)); Text("24 fps").tag(Int?.some(24)); Text("30 fps").tag(Int?.some(30))
                        } else {
                            Text("Original (\(model.manifest.capture.frameRate) fps)").tag(Int?.none)
                            Text("60 fps").tag(Int?.some(60)); Text("30 fps").tag(Int?.some(30))
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                FieldRow(label: "Save to", labelWidth: 92) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder").foregroundStyle(.secondary).font(.system(size: 11))
                        Text(FileManager.default.displayName(atPath: destination.path))
                            .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Button("Change…") { chooseFolder() }.buttonStyle(.link).font(.system(size: 12)).foregroundStyle(Theme.accentText)
                    }
                }
                FieldRow(label: "Estimated size", labelWidth: 92) {
                    Text(estimate).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Export") {
                    model.export(ExportOptions(format: format, height: height, frameRate: fps, destination: destination))
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.xl)
    }

    private func running(_ p: Double) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Exporting…").font(.system(size: 17, weight: .semibold))
            ProgressView(value: p).tint(Theme.accent)
                .accessibilityLabel("Export progress")
            HStack {
                SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text([String(Int(p * 100)) + "%", model.exportTimeLeft(progress: p, now: ctx.date)].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Other recordings stay editable while this runs.").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            HStack {
                Spacer()
                Button("Cancel Export") { model.cancelWork() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, Theme.Space.xs)
        }
        .padding(Theme.Space.xl)
    }

    private func done(_ url: URL) -> some View {
        VStack(spacing: Theme.Space.m) {
            Mascot(pose: .celebrating, size: 104)
                .padding(.top, Theme.Space.s)
            Text("Exported").font(.system(size: 17, weight: .semibold))
            Text(url.lastPathComponent).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack(spacing: Theme.Space.s) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Copy File") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([url as NSURL])
                }
                .buttonStyle(SecondaryButtonStyle())
                Button("Done") { model.exportState = .idle; isPresented = false }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
            Divider().padding(.top, Theme.Space.s)
            HStack(spacing: 4) {
                Text("Reelbird is free and open source.").foregroundStyle(.secondary)
                Link("Support it", destination: URL(string: ReelbirdInfo.supportURL)!)
                    .foregroundStyle(Theme.accentText)
            }
            .font(.system(size: 11.5))
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity)
    }

    private func failed(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Export didn't finish").font(.system(size: 17, weight: .semibold))
            StatusLine(tone: .error, text: msg)
            Text("Your recording and edits are safe.").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Close") { model.exportState = .idle; isPresented = false }.buttonStyle(SecondaryButtonStyle())
                Button("Try Again") { model.exportState = .idle }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(Theme.Space.xl)
    }

    private var formatHelp: String {
        switch format {
        case .mp4H264: "Plays everywhere: Slack, email, every browser."
        case .mp4HEVC: "Half the size of MP4 at the same quality. Plays on Apple devices and modern browsers."
        case .proRes: "Edit-ready master for Final Cut, Resolve or Premiere. Large files."
        case .gif: "Loops silently in docs, READMEs and chats. Best for short clips."
        }
    }

    private var estimate: String {
        let h = Double(height ?? model.manifest.capture.pixelSize.height)
        let pixels = h * h * 16 / 9
        let rate = Double(fps ?? model.manifest.capture.frameRate)
        let bitsPerPixel: Double = switch format {
        case .mp4H264: 0.07
        case .mp4HEVC: 0.04
        case .proRes: 1.6
        case .gif: 0.5
        }
        let bytes = pixels * rate * bitsPerPixel * model.outputDuration / 8
        return "About " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = destination
        if panel.runModal() == .OK, let url = panel.url { exportFolderPath = url.path }
    }
}

// MARK: Share

/// "Share" opens the share popover. Once a link exists the button copies it in one click
/// (with a brief "Copied"), and the chevron beside it opens the popover for updates.
struct ShareButton: View {
    @Bindable var model: EditorModel
    let app: AppModel?
    @ViewState private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 1) {
            Button {
                if model.shareInfo != nil, !model.shareState.isWorking {
                    model.copyLink()
                    withAnimation(reduceMotion ? nil : Theme.snappy) { copied = true }
                    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                         userInfo: [.announcement: "Link copied", .priority: NSAccessibilityPriorityLevel.high.rawValue])
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        withAnimation(reduceMotion ? nil : Theme.snappy) { copied = false }
                    }
                } else {
                    model.showShare.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    if case .working(_, let p) = model.shareState {
                        ProgressView(value: p).progressViewStyle(.circular).controlSize(.mini)
                    } else {
                        Image(systemName: copied ? "checkmark" : "link")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    Text(copied ? "Copied" : model.shareInfo == nil ? "Share" : "Copy Link")
                        .frame(minWidth: model.shareInfo == nil ? nil : 62, alignment: .leading)
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .help(model.shareInfo == nil ? "Share with a link (⇧⌘E)" : "Copy the link")
            if model.shareInfo != nil {
                Button { model.showShare.toggle() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(SecondaryButtonStyle())
                .help("Sharing options (⇧⌘E)")
                .accessibilityLabel("Sharing options")
            }
        }
        .popover(isPresented: $model.showShare, arrowEdge: .bottom) {
            SharePanel(model: model, app: app).frame(width: 340)
        }
    }
}

struct SharePanel: View {
    @Bindable var model: EditorModel
    let app: AppModel?
    @ViewState private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if !model.shareConfigured {
                Text("Share with a link").font(.system(size: 14, weight: .semibold))
                Text("Links upload to your own storage bucket. Cloudflare R2 is free to start and takes about ten minutes to set up, once.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Set Up Sharing…") {
                    model.showShare = false
                    app?.openSettings(.sharing)
                }
                .buttonStyle(PrimaryButtonStyle())
            } else if let info = model.shareInfo {
                Text("Shared").font(.system(size: 14, weight: .semibold))
                HStack(spacing: 6) {
                    Text(info.url)
                        .font(.system(size: 12))
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.fieldFill))
                    Button(copied ? "Copied" : "Copy") {
                        model.copyLink(); copied = true
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(minWidth: 64)
                }
                StatusLine(tone: info.polished ? .success : .info,
                           text: info.polished ? "Plays your edited video." : "Plays the quick recording. Update the link to publish your edits.")
                progressOrError
                HStack {
                    Button("Open in Browser") { model.openLink() }.buttonStyle(SecondaryButtonStyle())
                    Button("Update Link") { model.publish() }.buttonStyle(SecondaryButtonStyle()).disabled(model.shareState.isWorking)
                        .help("Renders your edits and replaces the video behind the same link")
                    Spacer()
                }
                Divider()
                Button("Stop Sharing…", role: .destructive) { confirmUnpublish() }
                    .buttonStyle(.link).font(.system(size: 12)).foregroundStyle(Theme.accentText)
                    .help("Deletes the uploaded files. The link stops working.")
            } else {
                Text("Share with a link").font(.system(size: 14, weight: .semibold))
                Text("Renders your edited video, uploads it to your bucket and copies the link.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                progressOrError
                if !model.shareState.isWorking {
                    Button("Create Link") { model.publish() }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
        .padding(Theme.Space.l)
    }

    private func confirmUnpublish() {
        let alert = NSAlert()
        alert.messageText = "Stop sharing this recording?"
        alert.informativeText = "The uploaded video is deleted from your bucket and the link stops working for everyone who has it. The recording stays on your Mac."
        alert.addButton(withTitle: "Stop Sharing")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { model.unpublish() }
    }

    @ViewBuilder private var progressOrError: some View {
        switch model.shareState {
        case .working(let label, let p):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: p).tint(Theme.accent)
                    .accessibilityLabel(label)
                HStack {
                    Text("\(label)… \(Int(p * 100))%").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { model.cancelWork() }
                        .buttonStyle(.link).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        case .failed(let msg): StatusLine(tone: .error, text: msg)
        case .idle: EmptyView()
        }
    }
}

extension ShareState {
    var isWorking: Bool { if case .working = self { true } else { false } }
}
