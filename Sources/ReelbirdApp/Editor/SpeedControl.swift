import AppKit
import ReelbirdCore
import SwiftUI

/// The toolbar's Speed button. It acts on the selected part or speed segment and shows its speed; with nothing
/// selected it's dimmed and says how to pick a part. Click it for the speed popover.
struct SpeedControl: View {
    @Bindable var model: EditorModel
    @ViewState private var open = false
    @ViewState private var hovering = false

    var body: some View {
        let rate = model.speedSliderRate
        let changed = rate.map { abs($0 - 1) > 1e-9 } ?? false
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "gauge.with.dots.needle.67percent").font(.system(size: 11.5, weight: .medium))
                Text("Speed").font(.system(size: 12, weight: .medium))
                Text(rate.map(SpeedSegment.label) ?? EditorKeys.changeSpeed.display)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(changed ? AnyShapeStyle(Theme.accentText) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(open ? Theme.accent.opacity(0.14) : Color.primary.opacity(hovering && rate != nil ? 0.08 : 0.045)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(rate == nil)
        .opacity(rate == nil ? 0.45 : 1)
        .onHover { hovering = $0 }
        .help(rate == nil ? "Click a part of the video on the timeline, then change its speed here"
                          : "Change the speed of the selected part (\(EditorKeys.changeSpeed.display) steps through presets)")
        .popover(isPresented: $open, arrowEdge: .bottom) { SpeedPopover(model: model) }
        .onChange(of: rate == nil) { _, none in if none { open = false } }
        .accessibilityLabel(rate.map { "Speed, \(SpeedSegment.label($0))" } ?? "Speed, select a part first")
    }
}

/// Speed for the selected part: a big value you can drag sideways, a slider from 0.25× to 4× with 1× in the middle,
/// presets, what it saves, and whether fast parts keep their sound. Dragging previews the value here and applies it
/// on release (one undo step, and the preview rebuilds once); presets apply at once.
struct SpeedPopover: View {
    @Bindable var model: EditorModel
    /// The value while a drag is under way.
    @ViewState private var draft: Double?
    @ViewState private var scrubStart: Double?

    static let range = EditorModel.speedSliderRange
    static let presets: [Double] = [0.25, 0.5, 1, 1.5, 2, 4]
    /// Points of sideways drag that double (or halve) the speed.
    static let pointsPerDoubling: CGFloat = 110

    private var rate: Double { draft ?? model.speedSliderRate ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Speed").font(.system(size: 13, weight: .semibold))
                Spacer()
                value
            }
            slider
            presetRow
            footer
        }
        .padding(16)
        .frame(width: 300)
    }

    /// The big number: drag it left or right to change the speed.
    private var value: some View {
        Text(SpeedSegment.label(rate))
            .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(abs(rate - 1) > 1e-9 ? Theme.accentText : Theme.ink)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(scrubStart == nil ? 0.05 : 0.1)))
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in
                    let start = scrubStart ?? rate
                    if scrubStart == nil { scrubStart = start }
                    let fine: CGFloat = NSEvent.modifierFlags.contains(.shift) ? 4 : 1
                    draft = Self.snapped(start * pow(2, Double(v.translation.width / (Self.pointsPerDoubling * fine))))
                }
                .onEnded { _ in commit(); scrubStart = nil })
            .help("Drag left or right to change the speed (hold Shift for fine steps)")
            .accessibilityLabel("Speed \(SpeedSegment.label(rate))")
            .accessibilityAdjustableAction { dir in
                let i = Self.presets.firstIndex { $0 >= rate - 1e-9 } ?? 0
                let next = dir == .increment ? Self.presets[min(Self.presets.count - 1, i + (abs(Self.presets[i] - rate) < 1e-9 ? 1 : 0))]
                                             : Self.presets[max(0, i - 1)]
                model.setSpeedFromSlider(next)
            }
    }

    /// 0.25×…4× on a doubling scale, so 1× sits in the middle and halving and doubling are the same distance.
    private var slider: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(get: { log2(min(Self.range.upperBound, max(Self.range.lowerBound, rate))) },
                                  set: { draft = Self.snapped(pow(2, $0)) }),
                   in: log2(Self.range.lowerBound)...log2(Self.range.upperBound),
                   onEditingChanged: { editing in if !editing { commit() } })
                .controlSize(.small)
                .tint(Theme.accent)
                .accessibilityLabel("Speed")
                .accessibilityValue(SpeedSegment.label(rate))
            HStack {
                ForEach(["0.25×", "0.5×", "1×", "2×", "4×"], id: \.self) { t in
                    Text(t).font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                    if t != "4×" { Spacer() }
                }
            }
            .accessibilityHidden(true)
        }
    }

    private var presetRow: some View {
        HStack(spacing: 4) {
            ForEach(Self.presets, id: \.self) { p in
                let on = abs(p - rate) < 1e-9
                Button { draft = nil; model.setSpeedFromSlider(p) } label: {
                    Text(SpeedSegment.label(p))
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .frame(maxWidth: .infinity).frame(height: 24)
                        .foregroundStyle(on ? Theme.onAccent : Theme.ink)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Theme.accent : Color.primary.opacity(0.06)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if let part = model.speedTargetRange {
            let d = part.duration
            Text(abs(rate - 1) < 1e-9 ? "This part plays at normal speed (\(TimeFormat.clock(d, tenths: true)))."
                 : "This part plays in \(TimeFormat.clock(d / rate, tenths: true)) instead of \(TimeFormat.clock(d, tenths: true)).")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if rate > SpeedSegment.audibleLimit {
            Toggle("Keep the sound above 2×", isOn: model.binding(\.speed.keepFastAudio, "Keep Fast Sound"))
                .toggleStyle(.brand).font(.system(size: 12))
        }
    }

    private func commit() {
        guard let d = draft else { return }
        draft = nil
        model.setSpeedFromSlider(d)
    }

    /// Rounded to 0.05× and pulled onto a preset when within about 4% of it.
    static func snapped(_ r: Double) -> Double {
        let r = min(range.upperBound, max(range.lowerBound, r))
        if let p = presets.first(where: { abs(log2($0) - log2(r)) < 0.06 }) { return p }
        return (r * 20).rounded() / 20
    }
}
