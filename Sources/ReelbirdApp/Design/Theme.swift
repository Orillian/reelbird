import AppKit
import SwiftUI

/// Reelbird's palette (brand/colors.md). 70% system neutrals, 30% ink/paper and muted text,
/// 10% coral. Coral is the only accent and always means "recording", "live" or "press this".
enum Theme {
    /// Coral #FF5A36: record button, live state, the one primary action. Never decoration.
    static let accent = Color(nsColor: .rbAccent)
    /// Coral as text or links: #C93A1E on light surfaces (4.7:1), coral on dark.
    static let accentText = Color(nsColor: .rbAccentText)
    static let accentSoft = Color(nsColor: .rbAccent).opacity(0.13)
    static let recording = Color(nsColor: .rbAccent)
    /// Text and glyphs on coral: always ink (white on coral is only 3.1:1).
    static let onAccent = Color(nsColor: .rbInkFixed)
    /// Ink in light mode, paper in dark mode: primary brand text and the bird.
    static let ink = Color(nsColor: .rbInk)
    static let inkFixed = Color(nsColor: .rbInkFixed)
    static let paper = Color(nsColor: .rbPaper)
    /// Neutral highlight for secondary timeline items (auto zooms), deliberately not coral.
    static let neutralMark = Color(nsColor: .rbNeutralMark)
    /// The dark stage behind the video preview.
    static let stage = Color(nsColor: .rbStage)
    static let hairline = Color(nsColor: .separatorColor)
    static let panel = Color(nsColor: .rbPanel)
    static let raised = Color(nsColor: .rbRaised)
    static let fieldFill = Color(nsColor: .rbField)
    static let success = Color(nsColor: .rbSuccess)
    static let warning = Color(nsColor: .rbWarning)

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 6
        static let control: CGFloat = 8
        static let panel: CGFloat = 14
    }

    /// Spring used for UI state changes. Short and critically damped: no bounce.
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 1)
    static let gentle = Animation.spring(response: 0.45, dampingFraction: 0.9)
}

extension NSColor {
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? dark : light }
    }
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    static let rbAccent = NSColor(hex: 0xFF5A36)
    static let rbAccentPressed = NSColor(hex: 0xE5432B)
    static let rbAccentText = dynamic(light: NSColor(hex: 0xC93A1E), dark: NSColor(hex: 0xFF6E4D))
    static let rbRecording = rbAccent
    static let rbInkFixed = NSColor(hex: 0x1A1512)
    static let rbPaper = NSColor(hex: 0xFFF4E8)
    static let rbInk = dynamic(light: NSColor(hex: 0x1A1512), dark: NSColor(hex: 0xFFF4E8))
    static let rbNeutralMark = dynamic(light: NSColor(hex: 0x6E645C), dark: NSColor(hex: 0xA69C93))
    static let rbStage = dynamic(light: NSColor(hex: 0xECE7E2), dark: NSColor(hex: 0x110D0B))
    static let rbPanel = dynamic(light: NSColor(hex: 0xFCFAF8), dark: NSColor(hex: 0x1F1A17))
    static let rbRaised = dynamic(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x3B332F))
    static let rbField = dynamic(light: NSColor(hex: 0x1A1512, alpha: 0.05), dark: NSColor(hex: 0xFFF4E8, alpha: 0.07))
    static let rbSuccess = dynamic(light: NSColor(hex: 0x2E8A57), dark: NSColor(hex: 0x56C68A))
    static let rbWarning = dynamic(light: NSColor(hex: 0xA86A00), dark: NSColor(hex: 0xF2B544))
}

/// Set by the snapshot renderer: effects the compositor draws (Liquid Glass) are swapped for
/// solid fills so offscreen captures show the real layout.
private struct SnapshotModeKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var isSnapshot: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}

/// `--snapshot … --glass` keeps Liquid Glass in snapshots, to check what an offscreen capture shows.
@MainActor enum GlassOverride { static var inSnapshots = false }

extension View {
    /// Liquid Glass on macOS 26+, a thick material before that (and in snapshots, which can't
    /// capture glass). Used only for the floating controls layer the HIG reserves glass for: the
    /// recording control bar, its warnings and toasts. Content (editor, library, settings) stays on
    /// solid surfaces. `glass: false` keeps a solid panel on every version: the source picker is dense content
    /// (thumbnails, small labels) that has to stay legible over any desktop. `movesWindow: false` is for
    /// bars floating inside a window (the library's selection bar), which shouldn't drag it.
    @MainActor @ViewBuilder func floatingSurface(cornerRadius: CGFloat, snapshot: Bool, glass: Bool = true,
                                                 movesWindow: Bool = true) -> some View {
        // Empty space on every floating panel drags it (SwiftUI's hosting view never moves the window itself).
        let draggable = self.background { if movesWindow { WindowDragArea() } }
        if #available(macOS 26, *), glass, !snapshot || GlassOverride.inSnapshots {
            draggable.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            draggable.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .rbPanel).opacity(snapshot || !glass ? 1 : 0.92))
                    .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            )
        }
    }
}

/// Formats seconds as m:ss or h:mm:ss, optionally with tenths.
enum TimeFormat {
    static func clock(_ seconds: Double, tenths: Bool = false) -> String {
        let s = max(0, seconds.isFinite ? seconds : 0)
        let total = Int(s)
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        var out = h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
        if tenths { out += String(format: ".%d", Int((s - Double(total)) * 10)) }
        return out
    }
}

/// `@State` is a macro in the macOS 27 SDK and the Command Line Tools ship without the
/// SwiftUI macro plugin, so views use the property wrapper through this alias instead.
typealias ViewState<T> = SwiftUI.State<T>

/// A view that moves its window when dragged. Placed behind panel content, so buttons keep their clicks
/// and everything else picks up the panel.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            // Title-bar behaviour: double-click zooms a titled window; anything else drags it.
            if event.clickCount == 2, let w = window, w.styleMask.contains(.titled) { w.performZoom(nil); return }
            window?.performDrag(with: event)
        }
    }
}
