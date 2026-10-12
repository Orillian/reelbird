import AppKit
import SwiftUI

/// The Reelbird robin (brand/mascot-*.svg). Its breast is the record light.
/// Used at most once per screen: onboarding, empty library, export done, link copied.
struct Mascot: View {
    enum Pose { case idle, recording, celebrating, sleeping }
    let pose: Pose
    var size: CGFloat = 120
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if let img = BrandImage.mascot(pose, dark: scheme == .dark) {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Decodes the embedded brand SVGs once.
@MainActor enum BrandImage {
    private static var cache: [String: NSImage] = [:]

    static func svg(_ source: String, key: String, template: Bool = false) -> NSImage? {
        if let c = cache[key] { return c }
        guard let img = NSImage(data: Data(source.utf8)) else { return nil }
        img.isTemplate = template
        cache[key] = img
        return img
    }

    static func mascot(_ pose: Mascot.Pose, dark: Bool) -> NSImage? {
        let (light, darkSrc, name): (String, String, String) = switch pose {
        case .idle: (BrandSVG.mascotIdle, BrandSVG.mascotIdleDark, "idle")
        case .recording: (BrandSVG.mascotRecording, BrandSVG.mascotRecordingDark, "recording")
        case .celebrating: (BrandSVG.mascotCelebrating, BrandSVG.mascotCelebratingDark, "celebrating")
        case .sleeping: (BrandSVG.mascotSleeping, BrandSVG.mascotSleepingDark, "sleeping")
        }
        return svg(dark ? darkSrc : light, key: "mascot-\(name)-\(dark)")
    }

    /// 18 pt template glyph for the status item.
    static func menuBar(recording: Bool) -> NSImage {
        let img = svg(recording ? BrandSVG.menubarRecording : BrandSVG.menubar, key: "menubar-\(recording)", template: true)
            ?? NSImage(systemSymbolName: recording ? "record.circle.fill" : "record.circle", accessibilityDescription: nil)!
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = true
        img.accessibilityDescription = recording ? "Reelbird, recording" : "Reelbird"
        return img
    }

    static func mark(dark: Bool) -> NSImage? {
        svg(dark ? BrandSVG.markDark : BrandSVG.mark, key: "mark-\(dark)")
    }

    static func logo(dark: Bool) -> NSImage? {
        svg(dark ? BrandSVG.logoDark : BrandSVG.logo, key: "logo-\(dark)")
    }
}

/// The bird + wordmark lockup for About and onboarding.
struct BrandLogo: View {
    var height: CGFloat = 28
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if let img = BrandImage.logo(dark: scheme == .dark) {
            Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(height: height)
                .accessibilityLabel("Reelbird")
        }
    }
}
