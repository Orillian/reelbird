import ReelbirdCore
import SwiftUI

extension Color {
    init(caption c: RGBA) { self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) }
}

/// The caption styles as a grid of small previews. None comes first: the style is the on/off switch.
struct StyleGrid: View {
    @Bindable var model: EditorModel
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(CaptionSettings.Style.allCases, id: \.self) { style in
                    let selected = model.edit.captions.style == style
                    Button { model.setCaptionLook(style == .none ? "Hide Captions" : "Caption Style") { $0.style = style } } label: {
                        VStack(spacing: 4) {
                            StyleThumb(style: style, palette: model.edit.captions.palette, uppercase: model.edit.captions.uppercase)
                                .frame(height: 46)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(selected ? Theme.accent : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 0.5))
                            Text(style.title).font(.system(size: 11, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Color.primary : Color.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(help(style))
                    .accessibilityLabel("\(style.title) captions")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            if model.edit.captions.style.isSocial {
                Text("Made for short social clips. For longer videos, Classic, Highlight and Marker are easier to read.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func help(_ s: CaptionSettings.Style) -> String {
        switch s {
        case .none: "No captions in the video (the transcript stays)"
        case .classic: "One or two lines at a time"
        case .highlight: "The spoken word lights up"
        case .marker: "A highlighter box follows the spoken word"
        case .pop: "Words pop in as they're spoken"
        case .oneWord: "One big word at a time"
        case .slam: "Words land hard, one or two at a time"
        }
    }
}

/// A tiny drawing of a style over a mock screen, in the chosen colours.
struct StyleThumb: View {
    let style: CaptionSettings.Style
    let palette: CaptionSettings.Palette
    let uppercase: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(white: 0.30), Color(white: 0.18)], startPoint: .top, endPoint: .bottom)
            RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.92)).padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 14)
                .frame(maxHeight: .infinity, alignment: .top)
            caption.padding(.bottom, style.isWordAtATime ? 10 : 4)
        }
    }

    private var text: Color { Color(caption: palette.text) }
    private var accent: Color { Color(caption: palette.accent) }

    @ViewBuilder private var caption: some View {
        switch style {
        case .none:
            Image(systemName: "captions.bubble").font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                .overlay(Rectangle().fill(.white.opacity(0.75)).frame(width: 20, height: 1.2).rotationEffect(.degrees(-35)))
                .frame(maxHeight: .infinity)
        case .classic:
            pill(Text("Click the button").foregroundColor(text))
        case .highlight:
            pill(Text("Click the ").foregroundColor(text) + Text("button").foregroundColor(accent))
        case .marker:
            pill(HStack(spacing: 2) {
                Text("Click the").foregroundStyle(text)
                Text("button").foregroundStyle(Color(caption: palette.onAccent))
                    .padding(.horizontal, 1.5)
                    .background(RoundedRectangle(cornerRadius: 2).fill(accent))
            })
        case .pop:
            pill(Text("Click the").foregroundColor(text))
        case .oneWord:
            pill(Text(uppercase ? "CLICK" : "Click").font(.system(size: 12, weight: .heavy)).foregroundColor(text), big: true)
        case .slam:
            pill(Text(uppercase ? "NOW" : "Now").font(.system(size: 14, weight: .heavy)).foregroundColor(accent), big: true)
        }
    }

    private func pill<V: View>(_ v: V, big: Bool = false) -> some View {
        v.font(.system(size: 7.5, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, big ? 4 : 3).padding(.vertical, big ? 1 : 1.5)
            .background {
                if let b = palette.backing { RoundedRectangle(cornerRadius: 3).fill(Color(caption: b)) }
            }
            .shadow(color: palette.backing == nil ? .black.opacity(0.6) : .clear, radius: 1)
    }
}

/// A colour choice: the backing with the accent on it.
struct PaletteSwatch: View {
    let palette: CaptionSettings.Palette
    let selected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(palette.backing.map { Color(caption: RGBA($0.r, $0.g, $0.b)) } ?? Color(white: 0.55))
            if palette.backing == nil {
                // Bare: no backing, shown as a hatched tile.
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(white: 0.75))
                    .mask(Stripes().stroke(lineWidth: 2))
            }
            Circle().fill(Color(caption: palette.accent)).frame(width: 9, height: 9)
        }
        .frame(width: 24, height: 24)
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2))
    }

    private struct Stripes: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            var x = -r.height
            while x < r.width { p.move(to: CGPoint(x: x, y: r.maxY)); p.addLine(to: CGPoint(x: x + r.height, y: r.minY)); x += 5 }
            return p
        }
    }
}
