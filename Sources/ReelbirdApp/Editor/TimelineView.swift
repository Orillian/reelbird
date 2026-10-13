import AppKit
import ReelbirdCore
import SwiftUI

/// The editor timeline on the recording (source) timeline: ruler, filmstrip with trim handles,
/// waveform, zoom lane, cuts (hatched), split points and the playhead.
struct TimelineView: View {
    @Bindable var model: EditorModel

    static let gutter: CGFloat = 34
    static let inset: CGFloat = 12
    static let rulerHeight: CGFloat = 24
    static let videoHeight: CGFloat = 50
    static let audioHeight: CGFloat = 34
    static let zoomHeight: CGFloat = 28
    static let laneGap: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let visible = geo.size.width - Self.gutter
            let width = max(visible, (visible - Self.inset * 2) * model.timelineZoom + Self.inset * 2)
            let scale = TimeScale(duration: model.duration, width: width, inset: Self.inset)
            HStack(spacing: 0) {
                laneIcons
                ScrollView(.horizontal) {
                    TimelineContent(model: model, scale: scale)
                        .frame(width: width, height: geo.size.height)
                }
                .scrollIndicators(model.timelineZoom > 1 ? .automatic : .never)
            }
        }
        .background(Theme.panel)
    }

    private var laneIcons: some View {
        VStack(spacing: Self.laneGap) {
            Color.clear.frame(height: Self.rulerHeight - Self.laneGap + 6)
            laneIcon("film", height: Self.videoHeight, label: "Video")
            laneIcon("waveform", height: Self.audioHeight, label: "Audio")
            laneIcon("plus.magnifyingglass", height: Self.zoomHeight, label: "Zooms")
            Spacer(minLength: 0)
        }
        .frame(width: Self.gutter)
    }

    private func laneIcon(_ symbol: String, height: CGFloat, label: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(height: height)
            .help(label)
            .accessibilityLabel(label)
    }
}

/// Maps seconds to x positions.
struct TimeScale {
    let duration: Double
    let width: CGFloat
    let inset: CGFloat
    var pps: CGFloat { (width - inset * 2) / CGFloat(max(0.001, duration)) }
    func x(_ t: Double) -> CGFloat { inset + CGFloat(t) * pps }
    func t(_ x: CGFloat) -> Double { min(max(0, Double((x - inset) / pps)), duration) }
}

struct TimelineContent: View {
    @Bindable var model: EditorModel
    let scale: TimeScale

    private var videoTop: CGFloat { TimelineView.rulerHeight + 6 }
    private var audioTop: CGFloat { videoTop + TimelineView.videoHeight + TimelineView.laneGap }
    private var zoomTop: CGFloat { audioTop + TimelineView.audioHeight + TimelineView.laneGap }
    private var lanesBottom: CGFloat { zoomTop + TimelineView.zoomHeight }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Click/drag anywhere empty to scrub.
            Color.clear
                .contentShape(Rectangle())
                .gesture(scrubGesture)
            Ruler(scale: scale).frame(height: TimelineView.rulerHeight)
                .gesture(scrubGesture)
            videoLane
            audioLane
            zoomLane
            cutsOverlay
            trimOverlay
            splitMarks
            cameraMoveMarks
            segmentSelection
            Playhead(model: model, scale: scale, height: lanesBottom + 6)
        }
        .coordinateSpace(name: "timeline")
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
            .onChanged { v in
                if model.isPlaying { model.pause() }
                model.seek(source: scale.t(v.location.x))
            }
            .onEnded { v in
                let t = scale.t(v.location.x)
                if v.translation == .zero, v.location.y >= videoTop, v.location.y <= videoTop + TimelineView.videoHeight {
                    if let cut = model.edit.cuts.first(where: { $0.contains(t) }) {
                        model.selection = .cut(cut)
                    } else if !model.splits.isEmpty {
                        model.selection = .segment(model.segment(containing: t))
                    } else {
                        model.selection = nil
                    }
                } else if v.translation == .zero {
                    model.selection = nil
                }
            }
    }

    // MARK: Lanes

    private var videoLane: some View {
        let rect = CGRect(x: scale.x(0), y: videoTop, width: scale.x(model.duration) - scale.x(0), height: TimelineView.videoHeight)
        return Canvas { ctx, _ in
            let clip = Path(roundedRect: CGRect(origin: .zero, size: rect.size), cornerRadius: 7, style: .continuous)
            ctx.clip(to: clip)
            ctx.fill(clip, with: .color(Color.primary.opacity(0.08)))
            let frames = model.filmstrip
            if !frames.isEmpty {
                let fw = rect.height * 16 / 10
                var x: CGFloat = 0
                var i = 0
                while x < rect.width {
                    let img = frames[min(frames.count - 1, Int(Double(x / rect.width) * Double(frames.count)))]
                    ctx.draw(Image(decorative: img, scale: 1), in: CGRect(x: x, y: 0, width: fw, height: rect.height))
                    x += fw; i += 1
                }
                ctx.fill(clip, with: .color(.black.opacity(0.06)))
            }
            ctx.stroke(clip, with: .color(Color.primary.opacity(0.12)), lineWidth: 1)
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
        .allowsHitTesting(false)
    }

    private var audioLane: some View {
        let rect = CGRect(x: scale.x(0), y: audioTop, width: scale.x(model.duration) - scale.x(0), height: TimelineView.audioHeight)
        let muted = model.edit.audio.microphoneMuted
        return Canvas { ctx, size in
            let bg = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 7, style: .continuous)
            ctx.fill(bg, with: .color(Color.primary.opacity(0.045)))
            let w = model.waveform
            guard !w.isEmpty else { return }
            let barW: CGFloat = 2, gap: CGFloat = 1.2
            let count = Int(size.width / (barW + gap))
            var path = Path()
            for i in 0..<max(0, count) {
                let v = CGFloat(w[min(w.count - 1, i * w.count / max(1, count))])
                let h = max(1.5, v * (size.height - 8))
                path.addRoundedRect(in: CGRect(x: CGFloat(i) * (barW + gap), y: (size.height - h) / 2, width: barW, height: h),
                                    cornerSize: CGSize(width: 1, height: 1))
            }
            ctx.fill(path, with: .color(Theme.ink.opacity(muted ? 0.15 : 0.5)))
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
        .allowsHitTesting(false)
    }

    private var zoomLane: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.03))
                .frame(width: scale.x(model.duration) - scale.x(0), height: TimelineView.zoomHeight)
                .offset(x: scale.x(0))
                .allowsHitTesting(false)
            ForEach(model.edit.zoom.regions) { r in
                ZoomRegionView(model: model, region: r, scale: scale,
                               dimmed: model.edit.zoom.mode == .off || (model.edit.zoom.mode == .manual && r.source == .auto))
            }
            if model.edit.zoom.regions.isEmpty {
                Text(model.edit.zoom.mode == .off ? "Zoom is off" : "Press Z to add a zoom at the playhead")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(height: TimelineView.zoomHeight)
                    .offset(x: scale.x(0) + 10)
                    .allowsHitTesting(false)
            }
        }
        .offset(y: zoomTop)
    }

    // MARK: Overlays

    private var cutsOverlay: some View {
        ForEach(Array(model.edit.cuts.enumerated()), id: \.offset) { _, cut in
            let selected = model.selection == .cut(cut)
            let x0 = scale.x(cut.start), x1 = scale.x(cut.end)
            Hatch(selected: selected)
                .frame(width: max(2, x1 - x0), height: lanesBottom - videoTop)
                .offset(x: x0, y: videoTop)
                .onTapGesture { model.selection = .cut(cut) }
                .help("Cut \(TimeFormat.clock(cut.duration, tenths: true)). Press Delete to restore.")
                .accessibilityLabel("Cut from \(TimeFormat.clock(cut.start)) to \(TimeFormat.clock(cut.end))")
        }
    }

    private var trimOverlay: some View {
        let trim = model.edit.trim ?? TimeRange(start: 0, end: model.duration)
        return ZStack(alignment: .topLeading) {
            // Dim what's trimmed away.
            Rectangle().fill(Theme.panel.opacity(0.72))
                .frame(width: max(0, scale.x(trim.start) - scale.x(0)), height: lanesBottom - videoTop)
                .offset(x: scale.x(0), y: videoTop)
                .allowsHitTesting(false)
            Rectangle().fill(Theme.panel.opacity(0.72))
                .frame(width: max(0, scale.x(model.duration) - scale.x(trim.end)), height: lanesBottom - videoTop)
                .offset(x: scale.x(trim.end), y: videoTop)
                .allowsHitTesting(false)
            TrimHandle(leading: true)
                .offset(x: scale.x(trim.start) - 6, y: videoTop)
                .gesture(DragGesture(coordinateSpace: .named("timeline")).onChanged { v in
                    model.setTrim(start: scale.t(v.location.x))
                })
            TrimHandle(leading: false)
                .offset(x: scale.x(trim.end) - 6, y: videoTop)
                .gesture(DragGesture(coordinateSpace: .named("timeline")).onChanged { v in
                    model.setTrim(end: scale.t(v.location.x))
                })
        }
    }

    private var splitMarks: some View {
        ForEach(model.splits, id: \.self) { s in
            Path { p in
                p.move(to: CGPoint(x: scale.x(s), y: videoTop - 2))
                p.addLine(to: CGPoint(x: scale.x(s), y: lanesBottom + 2))
            }
            .stroke(Theme.ink.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            .allowsHitTesting(false)
        }
    }

    /// Where the camera bubble moves: a small mark in its shape just above the video lane. Click to go there;
    /// the Camera panel lists and deletes them.
    @ViewBuilder private var cameraMoveMarks: some View {
        if model.hasCamera, model.edit.camera.visible {
            let shape = model.edit.camera.shape
            ForEach(Array(model.edit.camera.moves.enumerated()), id: \.offset) { _, move in
                let size = shape.glyphSize
                Button { model.seek(source: move.t) } label: {
                    CameraBubbleShape(shape: shape)
                        .fill(Theme.ink)
                        .overlay(CameraBubbleShape(shape: shape).stroke(Theme.panel, lineWidth: 1))
                        .frame(width: size.width * 0.9, height: size.height * 0.9)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Camera moves at \(TimeFormat.clock(model.timeline.outputTime(forSource: move.t) ?? move.t))")
                .accessibilityLabel("Camera move")
                .offset(x: scale.x(move.t) - 8, y: videoTop - 15)
            }
        }
    }

    @ViewBuilder private var segmentSelection: some View {
        if case .segment(let r) = model.selection {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.ink, lineWidth: 2)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.ink.opacity(0.06)))
                .frame(width: scale.x(r.end) - scale.x(r.start), height: TimelineView.videoHeight)
                .offset(x: scale.x(r.start), y: videoTop)
                .allowsHitTesting(false)
        }
    }
}

struct Ruler: View {
    let scale: TimeScale
    var body: some View {
        Canvas { ctx, size in
            let candidates: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
            let step = candidates.first { CGFloat($0) * scale.pps >= 64 } ?? 600
            let minor = step / 5
            var i = 0
            while Double(i) * minor <= scale.duration + 0.001 {
                // Index-based so ticks don't drift and sub-second labels read 0:00.5, not 0:00 twice.
                let t = Double(i) * minor
                let x = scale.x(t)
                let isMajor = i % 5 == 0
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height - (isMajor ? 8 : 4)))
                p.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(p, with: .color(Color.primary.opacity(isMajor ? 0.3 : 0.14)), lineWidth: 1)
                if isMajor {
                    ctx.draw(Text(TimeFormat.clock(t + 0.001, tenths: step < 1)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary),
                             at: CGPoint(x: x + 3, y: 9), anchor: .leading)
                }
                i += 1
            }
        }
        .contentShape(Rectangle())
    }
}

struct Hatch: View {
    let selected: Bool
    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(Path(rect), with: .color(Theme.panel.opacity(0.78)))
            var p = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 7
            }
            ctx.clip(to: Path(rect))
            ctx.stroke(p, with: .color(Color.primary.opacity(selected ? 0.4 : 0.18)), lineWidth: 1)
            if selected { ctx.stroke(Path(rect.insetBy(dx: 1, dy: 1)), with: .color(Theme.ink), lineWidth: 2) }
        }
        .contentShape(Rectangle())
    }
}

struct TrimHandle: View {
    let leading: Bool
    @ViewState private var hovering = false
    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: leading ? 6 : 1, bottomLeadingRadius: leading ? 6 : 1,
                               bottomTrailingRadius: leading ? 1 : 6, topTrailingRadius: leading ? 1 : 6, style: .continuous)
            .fill(Theme.ink.opacity(hovering ? 0.95 : 0.8))
            .overlay(Capsule().fill(Theme.panel).frame(width: 2, height: 16))
            .frame(width: 12, height: TimelineView.videoHeight)
            .contentShape(Rectangle().inset(by: -4))
            .onHover { h in hovering = h; (h ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
            .help(leading ? "Drag to trim the start" : "Drag to trim the end")
            .accessibilityLabel(leading ? "Trim start" : "Trim end")
    }
}

struct Playhead: View {
    @Bindable var model: EditorModel
    let scale: TimeScale
    let height: CGFloat

    var body: some View {
        let x = scale.x(model.playhead)
        ZStack(alignment: .top) {
            Rectangle().fill(Theme.accent).frame(width: 1.5, height: height)
            PlayheadKnob()
                .fill(Theme.accent)
                .frame(width: 13, height: 16)
                .offset(y: 4)
        }
        .frame(width: 13)
        .offset(x: x - 6.5)
        .contentShape(Rectangle())
        .gesture(DragGesture(coordinateSpace: .named("timeline")).onChanged { v in
            if model.isPlaying { model.pause() }
            model.seek(source: scale.t(v.location.x))
        })
        .accessibilityElement()
        .accessibilityLabel("Playhead")
        .accessibilityValue(TimeFormat.clock(model.playhead))
        .accessibilityAdjustableAction { dir in model.step(dir == .increment ? 1 : -1) }
    }
}

struct PlayheadKnob: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.62), cornerSize: CGSize(width: 3, height: 3))
        p.move(to: CGPoint(x: r.minX, y: r.height * 0.55))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.height * 0.55))
        p.closeSubpath()
        return p
    }
}

/// One zoom region: drag to move, drag the edges to resize, click to select.
struct ZoomRegionView: View {
    @Bindable var model: EditorModel
    let region: ZoomRegion
    let scale: TimeScale
    let dimmed: Bool
    @ViewState private var origin: TimeRange?

    private var selected: Bool { model.selection == .zoom(region.id) }

    var body: some View {
        let x0 = scale.x(region.range.start), x1 = scale.x(region.range.end)
        let w = max(10, x1 - x0)
        let user = region.source == .user
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(user ? Theme.ink.opacity(0.82) : Theme.neutralMark.opacity(0.28))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Color.primary.opacity(user ? 0 : 0.18), lineWidth: selected ? 2 : 1)
            if w > 44 {
                HStack(spacing: 4) {
                    Image(systemName: region.focus == nil ? "cursorarrow" : "scope").font(.system(size: 9, weight: .semibold))
                    Text(String(format: "%.1f×", region.scale)).font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(user ? Theme.panel : Color.primary.opacity(0.7))
            }
            HStack {
                edge(leading: true)
                Spacer(minLength: 0)
                edge(leading: false)
            }
        }
        .frame(width: w, height: TimelineView.zoomHeight)
        .opacity(dimmed ? 0.4 : 1)
        .offset(x: x0)
        .onTapGesture { model.selection = .zoom(region.id); model.section = .zoom }
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("timeline"))
            .onChanged { v in
                let o = origin ?? region.range
                origin = o
                let dt = Double(v.translation.width / scale.pps)
                let d = o.duration
                let start = min(max(0, o.start + dt), model.duration - d)
                model.selection = .zoom(region.id)
                model.updateZoom(region.id, coalesce: "move") { $0.range = TimeRange(start: start, end: start + d) }
            }
            .onEnded { _ in origin = nil })
        .help(user ? "Zoom you added. Drag to move, drag edges to resize, Delete to remove." :
                "Automatic zoom from your clicks. Drag to adjust it.")
        .accessibilityElement()
        .accessibilityLabel("\(user ? "Zoom" : "Automatic zoom"), \(String(format: "%.1f", region.scale)) times, at \(TimeFormat.clock(region.range.start))")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private func edge(leading: Bool) -> some View {
        Color.clear
            .frame(width: 7)
            .contentShape(Rectangle())
            .onHover { h in (h ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                .onChanged { v in
                    let t = scale.t(v.location.x)
                    model.selection = .zoom(region.id)
                    model.updateZoom(region.id, coalesce: leading ? "start" : "end") { r in
                        if leading { r.range.start = min(t, r.range.end - 0.3) } else { r.range.end = max(t, r.range.start + 0.3) }
                    }
                })
    }
}
