import AppKit
import AVFoundation
import CoreGraphics
import ReelbirdCore
import ScreenCaptureKit

/// Something the person can record: a display or a window.
public struct AvailableSource: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case display, window }

    /// Stable within a session: "display-<id>" or "window-<id>".
    public var id: String
    public var kind: Kind
    /// Display name ("Built-in Retina Display") or window title.
    public var title: String
    /// Owning app for windows.
    public var appName: String?
    /// Native pixel size the recording would have.
    public var pixelSize: PixelSize
    /// Frame in global display points (top-left origin).
    public var frame: CGRect
    /// What to put in `RecordingOptions.source`.
    public var source: CaptureSource
    /// Optional preview; `CaptureSources.list()` leaves it `nil` (use `CaptureSources.thumbnail`).
    public var thumbnail: CGImage?

    public init(id: String, kind: Kind, title: String, appName: String?, pixelSize: PixelSize,
                frame: CGRect, source: CaptureSource, thumbnail: CGImage? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.appName = appName
        self.pixelSize = pixelSize; self.frame = frame; self.source = source; self.thumbnail = thumbnail
    }
}

/// Lists displays and on-screen windows (our own windows excluded). Needs Screen Recording permission.
public enum CaptureSources {
    public static func list() async throws -> [AvailableSource] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.permissionDenied(.screen)
        }
        let names = await MainActor.run { displayNames() }
        let pid = getpid()
        var out: [AvailableSource] = []
        for d in content.displays {
            let scale = displayScale(d.displayID)
            let name = names[d.displayID] ?? "Display \(d.displayID)"
            out.append(AvailableSource(
                id: "display-\(d.displayID)", kind: .display, title: name, appName: nil,
                pixelSize: PixelSize(width: even(Double(d.width) * scale), height: even(Double(d.height) * scale)),
                frame: CGDisplayBounds(d.displayID),
                source: .display(id: d.displayID, name: name)))
        }
        let hidden: Set<String> = ["com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter",
                                   "com.apple.notificationcenterui", "com.apple.Spotlight"]
        let invisible = transparentWindowIDs()
        for w in content.windows {
            // Real app windows only: normal layer, visible, big enough to be worth recording. Small floating
            // helpers (tool palettes, "controls" panels, badges) and transparent overlays are left out.
            guard w.windowLayer == 0, w.isOnScreen, w.frame.width >= 160, w.frame.height >= 100,
                  !invisible.contains(w.windowID) else { continue }
            guard let app = w.owningApplication, app.processID != pid, !hidden.contains(app.bundleIdentifier) else { continue }
            let untitled = w.title?.isEmpty != false
            if untitled && (w.frame.width < 400 || w.frame.height < 300) { continue }
            let title = (untitled ? nil : w.title) ?? app.applicationName
            guard !title.isEmpty else { continue }
            let scale = scaleForPoint(CGPoint(x: w.frame.midX, y: w.frame.midY))
            out.append(AvailableSource(
                id: "window-\(w.windowID)", kind: .window, title: title, appName: app.applicationName,
                pixelSize: PixelSize(width: even(w.frame.width * scale), height: even(w.frame.height * scale)),
                frame: w.frame,
                source: .window(id: w.windowID, app: app.applicationName, title: title)))
        }
        return out
    }

    /// On-screen windows the window server draws fully transparent (invisible overlays some apps keep).
    static func transparentWindowIDs() -> Set<CGWindowID> {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var out = Set<CGWindowID>()
        for w in info {
            if let alpha = w[kCGWindowAlpha as String] as? Double, alpha < 0.05,
               let id = w[kCGWindowNumber as String] as? Int { out.insert(CGWindowID(id)) }
        }
        return out
    }

    /// A preview image of a source, at most `maxPixelWidth` wide.
    public static func thumbnail(for source: AvailableSource, maxPixelWidth: Int = 480) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        switch source.source {
        case .display(let id, _):
            guard let d = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.sourceNotFound(source.title) }
            filter = SCContentFilter(display: d, excludingApplications: ownApps(content), exceptingWindows: [])
        case .window(let id, _, _):
            guard let w = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.sourceNotFound(source.title) }
            filter = SCContentFilter(desktopIndependentWindow: w)
        default:
            throw CaptureError.unsupportedSource
        }
        let config = SCStreamConfiguration()
        let aspect = source.frame.height / max(1, source.frame.width)
        config.width = min(maxPixelWidth, source.pixelSize.width)
        config.height = max(2, Int(Double(config.width) * aspect))
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    static func ownApps(_ content: SCShareableContent) -> [SCRunningApplication] {
        let pid = getpid()
        let bundleID = Bundle.main.bundleIdentifier
        return content.applications.filter { $0.processID == pid || (bundleID != nil && $0.bundleIdentifier == bundleID) }
    }

    @MainActor static func displayNames() -> [CGDirectDisplayID: String] {
        var out: [CGDirectDisplayID: String] = [:]
        for s in NSScreen.screens {
            if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                out[n.uint32Value] = s.localizedName
            }
        }
        return out
    }

    /// Backing scale of a display (pixels per point), from its current mode.
    static func displayScale(_ id: CGDirectDisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 else { return 2 }
        return Double(mode.pixelWidth) / Double(mode.width)
    }

    static func scaleForPoint(_ p: CGPoint) -> Double {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(p, 1, &id, &count) == .success, count > 0 else { return 2 }
        return displayScale(id)
    }
}

/// A microphone or camera.
public struct MediaDevice: Identifiable, Hashable, Sendable {
    /// `AVCaptureDevice.uniqueID`: what goes in `RecordingOptions.microphoneID` / `cameraID`.
    public var id: String
    public var name: String
    public var isDefault: Bool
    public init(id: String, name: String, isDefault: Bool) { self.id = id; self.name = name; self.isDefault = isDefault }
}

public enum Devices {
    public static func microphones() -> [MediaDevice] {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        let def = AVCaptureDevice.default(for: .audio)?.uniqueID
        return session.devices.map { MediaDevice(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == def) }
    }

    public static func cameras() -> [MediaDevice] {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                       mediaType: .video, position: .unspecified)
        let def = AVCaptureDevice.default(for: .video)?.uniqueID
        return session.devices.map { MediaDevice(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == def) }
    }

    /// Resolves a device ID ("default" or a uniqueID) to a device.
    static func device(_ id: String, type: AVMediaType) -> AVCaptureDevice? {
        if id == "default" { return AVCaptureDevice.default(for: type) }
        return AVCaptureDevice(uniqueID: id)
    }
}
