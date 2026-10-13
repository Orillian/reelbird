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
    /// macOS's current default device of this kind.
    public var isDefault: Bool
    /// How a microphone is connected (`.unknown` for cameras).
    public var transport: MicTransport
    /// A microphone's nominal input sample rate in Hz, when known. Bluetooth headsets report 16 or
    /// 24 kHz while their mic is in use.
    public var sampleRate: Double?
    /// A webcam's microphone.
    public var isCameraMic: Bool

    public init(id: String, name: String, isDefault: Bool, transport: MicTransport = .unknown, sampleRate: Double? = nil,
                isCameraMic: Bool = false) {
        self.id = id; self.name = name; self.isDefault = isDefault
        self.transport = transport; self.sampleRate = sampleRate; self.isCameraMic = isCameraMic
    }

    /// The device as `MicPolicy` sees it.
    public var micCandidate: MicCandidate {
        MicCandidate(id: id, name: name, transport: transport, sampleRate: sampleRate, isSystemDefault: isDefault, isCameraMic: isCameraMic)
    }

    /// Records in call quality (Bluetooth, or 24 kHz and below).
    public var isCallQuality: Bool { MicPolicy.isCallQuality(micCandidate) }
}

extension Array where Element == MediaDevice {
    /// The device `MicPolicy.resolve` picks for a preference value ("auto", "default" or a device ID).
    public func resolveMicrophone(_ id: String?) -> MediaDevice? {
        guard let c = MicPolicy.resolve(id, in: map(\.micCandidate)) else { return nil }
        return first { $0.id == c.id }
    }

    /// The device "Automatic" records with.
    public var bestMicrophone: MediaDevice? { resolveMicrophone(MicPolicy.automaticID) }

    /// The best full-quality microphone to offer instead of `device`.
    public func alternative(to device: MediaDevice) -> MediaDevice? {
        guard let c = MicPolicy.bestAlternative(to: device.micCandidate, in: map(\.micCandidate)) else { return nil }
        return first { $0.id == c.id }
    }
}

public enum Devices {
    /// Audio inputs with their transport type and sample rate (CoreAudio).
    public static func microphones() -> [MediaDevice] {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        let def = CoreAudioDevices.defaultInput()?.uid ?? AVCaptureDevice.default(for: .audio)?.uniqueID
        let video = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                     mediaType: .video, position: .unspecified).devices
        let cameraModels = Set(video.map(\.modelID).filter { !$0.isEmpty })
        return session.devices.map { d in
            let ca = CoreAudioDevices.deviceID(forUID: d.uniqueID)
            var transport = ca.flatMap(CoreAudioDevices.transport) ?? MicTransport(coreAudio: UInt32(bitPattern: d.transportType))
            if transport == .unknown { transport = MicTransport(coreAudio: UInt32(bitPattern: d.transportType)) }
            let lower = d.localizedName.lowercased()
            let cameraMic = transport == .interface
                && (cameraModels.contains(d.modelID) || lower.contains("webcam") || lower.contains("camera"))
            return MediaDevice(id: d.uniqueID, name: d.localizedName, isDefault: d.uniqueID == def, transport: transport,
                               sampleRate: ca.flatMap(CoreAudioDevices.nominalSampleRate), isCameraMic: cameraMic)
        }
    }

    public static func cameras() -> [MediaDevice] {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                       mediaType: .video, position: .unspecified)
        let def = AVCaptureDevice.default(for: .video)?.uniqueID
        return session.devices.map { MediaDevice(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == def) }
    }

    /// Resolves a microphone preference ("auto", "default" or a device ID) to the connected device to
    /// lock the recording to. An explicit device that isn't connected falls back to the best one.
    public static func resolveMicrophone(_ id: String?) -> MediaDevice? { microphones().resolveMicrophone(id) }

    /// Whether the microphone with this UID is still connected, and the current system default input.
    public static func microphonePresence(uid: String) -> MicrophonePresence {
        let connected = CoreAudioDevices.deviceID(forUID: uid).map { CoreAudioDevices.isAlive($0) && CoreAudioDevices.hasInput($0) } ?? false
        let def = CoreAudioDevices.defaultInput()
        return MicrophonePresence(connected: connected, systemDefaultID: def?.uid, systemDefaultName: def?.name)
    }

    /// Resolves a device ID ("default" or a uniqueID) to a device.
    static func device(_ id: String, type: AVMediaType) -> AVCaptureDevice? {
        if id == "default" { return AVCaptureDevice.default(for: type) }
        return AVCaptureDevice(uniqueID: id)
    }
}
