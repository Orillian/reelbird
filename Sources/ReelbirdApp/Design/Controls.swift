import AppKit
import SwiftUI

/// A compact switch drawn in SwiftUI so it keeps the accent in floating panels and snapshots.
struct BrandSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.Space.s) {
            configuration.label
            Spacer(minLength: 0)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? Theme.accent : Color.primary.opacity(0.14))
                    .frame(width: 30, height: 18)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
                    .frame(width: 14, height: 14)
                    .padding(2)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .animation(Theme.snappy, value: configuration.isOn)
            .onTapGesture { configuration.isOn.toggle() }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

extension ToggleStyle where Self == BrandSwitchStyle {
    static var brand: BrandSwitchStyle { BrandSwitchStyle() }
}

/// The one accent button per surface (Record, Export, Continue).
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14 : 13, weight: .semibold))
            .foregroundStyle(Theme.onAccent.opacity(isEnabled ? 1 : 0.6))
            .padding(.horizontal, large ? 18 : 12)
            .frame(height: large ? 36 : 28)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(configuration.isPressed ? Color(nsColor: .rbAccentPressed) : tint)
                    .opacity(isEnabled ? 1 : 0.4)
            )
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
    }
}

/// Neutral filled button for secondary actions.
struct SecondaryButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14 : 13, weight: .medium))
            .foregroundStyle(Color.primary.opacity(isEnabled ? 0.9 : 0.4))
            .padding(.horizontal, large ? 16 : 11)
            .frame(height: large ? 36 : 28)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.07))
            )
            .contentShape(Rectangle())
    }
}

/// A borderless square icon button with a hover/pressed wash.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var active = false
    @ViewState private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.5, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(active ? Theme.accentText : Color.primary.opacity(0.82))
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(active ? Theme.accentSoft : Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.07 : 0))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// A keyboard shortcut rendered as keycaps, e.g. ⌥⇧R.
struct Keycap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

/// A horizontal level meter: segmented, green → amber → coral near clipping.
struct LevelMeter: View {
    var level: Double
    var segments = 14
    var height: CGFloat = 6
    var active = true

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 2
            let w = (geo.size.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
            HStack(spacing: gap) {
                ForEach(0..<segments, id: \.self) { i in
                    let threshold = Double(i) / Double(segments)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(color(for: i).opacity(active && level > threshold ? 1 : 0.16))
                        .frame(width: w)
                }
            }
        }
        .frame(height: height)
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }

    private func color(for i: Int) -> Color {
        let f = Double(i) / Double(segments)
        if f > 0.86 { return Theme.recording }
        if f > 0.68 { return Theme.warning }
        return Theme.success
    }
}

/// Small caps label above a group of controls.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A label + control row used across the inspector and settings.
struct FieldRow<Content: View>: View {
    let label: String
    var labelWidth: CGFloat = 86
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 26)
    }
}

/// A slider with a trailing numeric readout.
struct ValueSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var format: (Double) -> String
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                .controlSize(.small)
                .tint(Theme.accent)
            Text(format(value))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }
}

/// A segmented control with a sliding selection pill, used for the main mode switches.
struct PillTabs<T: Hashable>: View {
    struct Item { let value: T; let title: String; let symbol: String? }
    @Binding var selection: T
    let items: [Item]
    var compact = false
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                let item = items[i]
                let selected = item.value == selection
                Button {
                    withAnimation(Theme.snappy) { selection = item.value }
                } label: {
                    HStack(spacing: 5) {
                        if let s = item.symbol { Image(systemName: s).font(.system(size: compact ? 11 : 12, weight: .medium)) }
                        Text(item.title).font(.system(size: compact ? 11.5 : 12.5, weight: selected ? .semibold : .medium))
                    }
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: compact ? 24 : 28)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Theme.raised)
                                .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                                .matchedGeometryEffect(id: "pill", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fieldFill))
    }
}

/// A row of colour/option swatches.
struct Swatch: View {
    let fill: AnyShapeStyle
    let selected: Bool
    var size: CGFloat = 26
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(fill)
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .padding(2)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2))
    }
}

/// Inline status message with an icon, for warnings and results.
struct StatusLine: View {
    enum Tone { case info, success, warning, error }
    let tone: Tone
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 12)).foregroundStyle(tone == .info ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private var symbol: String {
        switch tone {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
    private var color: Color {
        switch tone {
        case .info: .secondary
        case .success: Theme.success
        case .warning: Theme.warning
        case .error: Theme.recording
        }
    }
}
