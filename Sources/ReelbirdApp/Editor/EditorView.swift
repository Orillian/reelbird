import AppKit
import ReelbirdCore
import SwiftUI

struct EditorView: View {
    @Bindable var model: EditorModel
    let app: AppModel?
    @Environment(\.isSnapshot) private var snapshot

    var body: some View {
        VStack(spacing: 0) {
            EditorTopBar(model: model, app: app)
                .background(WindowDragArea())
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    PreviewStage(model: model)
                    TransportBar(model: model)
                    Divider()
                    TimelineView(model: model)
                        .frame(height: 188)
                }
                .background(Theme.stage)
                Divider()
                InspectorView(model: model, app: app)
                    .frame(width: 304)
            }
        }
        .background(Theme.panel)
        .ignoresSafeArea()
        .sheet(isPresented: $model.showExport) {
            ExportSheet(model: model, isPresented: $model.showExport)
        }
    }
}

// MARK: Top bar

struct EditorTopBar: View {
    @Bindable var model: EditorModel
    let app: AppModel?
    @ViewState private var titleDraft = ""
    @ViewState private var titleHover = false
    @FocusState private var titleFocused: Bool
    @Environment(\.isSnapshot) private var snapshot

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            if snapshot { FakeTrafficLights() } else { Color.clear.frame(width: 66) }
            VStack(alignment: .leading, spacing: 1) {
                TextField("Untitled", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5, weight: .semibold))
                    .focused($titleFocused)
                    .onSubmit { model.setTitle(titleDraft); titleFocused = false }
                    .onChange(of: titleFocused) { _, f in if !f { model.setTitle(titleDraft) } }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    // Looks like a title until you point at it, then like the field it is.
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(titleFocused ? Theme.fieldFill : titleHover ? Theme.fieldFill.opacity(0.7) : .clear))
                    .onHover { titleHover = $0 }
                    .padding(.horizontal, -5)
                    .frame(maxWidth: 360, alignment: .leading)
                    .help("Rename")
                    .accessibilityLabel("Title")
                Text(subtitle)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let err = model.saveError {
                StatusLine(tone: .error, text: err).lineLimit(1).frame(maxWidth: 280)
            }
            Menu {
                Button("Library") { app?.openLibrary() }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.bundle.url]) }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 15))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(.secondary)
            .foregroundStyle(.secondary)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
            HStack(spacing: 2) {
                Button { app?.moveToTrash(model.bundle) } label: { Image(systemName: "trash") }
                    .buttonStyle(IconButtonStyle(size: 28))
                    .help("Move to Trash (⌘⌫)")
                    .accessibilityLabel("Move to Trash")
                Button { model.undoManager.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(IconButtonStyle(size: 28))
                    .disabled(!model.undoManager.canUndo)
                    .help("Undo (⌘Z)")
                    .accessibilityLabel("Undo")
                Button { model.undoManager.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .buttonStyle(IconButtonStyle(size: 28))
                    .disabled(!model.undoManager.canRedo)
                    .help("Redo (⇧⌘Z)")
                    .accessibilityLabel("Redo")
            }
            ShareButton(model: model, app: app)
            Button {
                model.showExport = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon)
            }
            .buttonStyle(PrimaryButtonStyle())
            .help("Export (⌘E)")
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(height: 54)
        .background(Theme.panel)
        .onAppear { titleDraft = model.title }
        .onChange(of: model.title) { _, t in if !titleFocused { titleDraft = t } }
    }

    private var subtitle: String {
        let m = model.manifest
        var parts = [TimeFormat.clock(model.outputDuration)]
        if model.outputDuration < model.duration - 0.05 { parts[0] += " of \(TimeFormat.clock(model.duration))" }
        parts.append("\(m.capture.pixelSize.width) × \(m.capture.pixelSize.height)")
        parts.append(m.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
        if m.status == .recovered { parts.append("Recovered") }
        return parts.joined(separator: "  ·  ")
    }
}

/// Window controls drawn in snapshots, where the real ones aren't captured.
struct FakeTrafficLights: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(nsColor: NSColor(hex: 0xFF5F57)))
            Circle().fill(Color(nsColor: NSColor(hex: 0xFEBC2E)))
            Circle().fill(Color(nsColor: NSColor(hex: 0x28C840)))
        }
        .frame(width: 52, height: 12)
        .padding(.trailing, 14)
    }
}

// MARK: Preview

struct PreviewStage: View {
    let model: EditorModel
    var body: some View {
        ZStack {
            Theme.stage
            if let err = model.previewError {
                VStack(spacing: Theme.Space.s) {
                    Image(systemName: "film.stack").font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
                    Text("The preview couldn't load").font(.system(size: 14, weight: .semibold))
                    Text(err).font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 380)
                    Text("Your recording files are untouched.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.bundle.url]) }
                        .buttonStyle(SecondaryButtonStyle())
                        .padding(.top, Theme.Space.xs)
                }
                .padding(Theme.Space.xl)
            } else if let player = model.player {
                PlayerHost(view: player.view)
                    .overlay { if model.isCropping { CropOverlay(model: model) } }
                    .padding(28)
                    .padding(.bottom, model.isCropping ? 44 : 0)
                    .onTapGesture { if !model.isCropping { model.togglePlay() } }
                    .accessibilityLabel("Preview")
                    .accessibilityHint(model.isCropping ? "Drag the crop edges; Return keeps the crop, Escape cancels" : "Press space to play or pause")
                if model.isCropping {
                    CropBar(model: model)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 14)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .transition(.opacity)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PlayerHost: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: Transport

struct TransportBar: View {
    @Bindable var model: EditorModel

    var body: some View {
        // Edit tools sit dead centre under the preview, whatever the side groups' widths.
        ZStack {
            tools
            HStack(spacing: Theme.Space.s) {
                playback
                Spacer()
                timelineZoom
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 44)
        .background(Theme.panel)
    }

    private var playback: some View {
        HStack(spacing: Theme.Space.s) {
            HStack(spacing: 2) {
                Button { model.seek(source: 0) } label: { Image(systemName: "backward.end.fill") }
                    .buttonStyle(IconButtonStyle(size: 28)).help("Go to start (Home)")
                    .accessibilityLabel("Go to start")
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle(size: 32))
                .help("Play/Pause (Space) · J K L to shuttle")
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            }
            HStack(spacing: 4) {
                Text(TimeFormat.clock(model.outputTime, tenths: true))
                    .foregroundStyle(.primary)
                Text("/").foregroundStyle(.tertiary)
                Text(TimeFormat.clock(model.outputDuration, tenths: true)).foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .accessibilityElement(children: .combine)
        }
    }

    private var tools: some View {
            HStack(spacing: 4) {
                ToolButton(symbol: "scissors", title: "Split", key: "S") { model.splitAtPlayhead() }
                ToolButton(symbol: "plus.magnifyingglass", title: "Zoom", key: "Z") { model.addZoomAtPlayhead() }
                if let sel = model.selection {
                    ToolButton(symbol: sel.isCut ? "arrow.uturn.backward" : "trash",
                               title: sel.isCut ? "Restore" : sel.isZoom ? "Delete Zoom" : "Cut", key: "⌫") { model.deleteSelection() }
                        .transition(.opacity)
                }
            }
            .animation(Theme.snappy, value: model.selection)
    }

    private var timelineZoom: some View {
            HStack(spacing: 6) {
                Button { model.timelineZoom = max(1, model.timelineZoom / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(IconButtonStyle(size: 24)).help("Zoom out timeline (⌘−)")
                    .accessibilityLabel("Zoom out timeline")
                Slider(value: Binding(get: { log2(model.timelineZoom) }, set: { model.timelineZoom = pow(2, $0) }), in: 0...4)
                    .controlSize(.mini)
                    .frame(width: 72)
                    .tint(Color.secondary)
                    .accessibilityLabel("Timeline zoom")
                Button { model.timelineZoom = min(16, model.timelineZoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(IconButtonStyle(size: 24)).help("Zoom in timeline (⌘=)")
                    .accessibilityLabel("Zoom in timeline")
            }
    }
}

extension TimelineSelection {
    var isCut: Bool { if case .cut = self { true } else { false } }
    var isZoom: Bool { if case .zoom = self { true } else { false } }
}

struct ToolButton: View {
    let symbol: String
    let title: String
    let key: String
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11.5, weight: .medium))
                Text(title).font(.system(size: 12, weight: .medium))
                Text(key).font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hovering ? 0.08 : 0.045)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(title) (\(key))")
    }
}
