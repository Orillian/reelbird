import AppKit
import SwiftUI

/// Reelbird's palette: neutral ink base, one warm accent (coral), amber for secondary highlights.
/// 70/30/10: system neutrals carry the UI, ink and text the structure, coral only marks the one
/// thing to press or the live state.
enum Theme {
    static let accent = Color(nsColor: .rbAccent)
    static let accentSoft = Color(nsColor: .rbAccent).opacity(0.14)
    static let amber = Color(nsColor: .rbAmber)
    static let recording = Color(nsColor: .rbRecording)
    static let ink = Color(nsColor: .rbInk)
    /// The dark stage behind the video preview, in both appearances.
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

    static let rbAccent = dynamic(light: NSColor(hex: 0xE45A33), dark: NSColor(hex: 0xFF7A4D))
    static let rbAmber = dynamic(light: NSColor(hex: 0xE59A2F), dark: NSColor(hex: 0xF5B04A))
    static let rbRecording = dynamic(light: NSColor(hex: 0xE5372B), dark: NSColor(hex: 0xFF4B3E))
    static let rbInk = dynamic(light: NSColor(hex: 0x1C1A19), dark: NSColor(hex: 0xF4F1EE))
    static let rbStage = dynamic(light: NSColor(hex: 0xE9E6E3), dark: NSColor(hex: 0x111010))
    static let rbPanel = dynamic(light: NSColor(hex: 0xFBFAF9), dark: NSColor(hex: 0x1E1D1C))
    static let rbRaised = dynamic(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x2A2928))
    static let rbField = dynamic(light: NSColor(hex: 0x000000, alpha: 0.045), dark: NSColor(hex: 0xFFFFFF, alpha: 0.07))
    static let rbSuccess = dynamic(light: NSColor(hex: 0x2E9B5F), dark: NSColor(hex: 0x4CC983))
    static let rbWarning = dynamic(light: NSColor(hex: 0xC27A00), dark: NSColor(hex: 0xF2B544))
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

extension View {
    /// Liquid Glass on macOS 26+, a thick material before that (and in snapshots).
    @ViewBuilder func floatingSurface(cornerRadius: CGFloat, snapshot: Bool) -> some View {
        if #available(macOS 26, *), !snapshot {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .rbPanel).opacity(snapshot ? 1 : 0.92))
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
