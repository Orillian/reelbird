import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import IOKit.hid
import ScreenCaptureKit

/// A privacy permission the recorder may need.
public enum Permission: String, CaseIterable, Codable, Hashable, Sendable {
    /// Screen Recording (required).
    case screen
    case microphone
    case camera
    /// Accessibility (focused-element tracking for zoom-to-typing).
    case accessibility
    /// Input Monitoring (keystroke capture for the keystroke overlay). This is the TCC "listen
    /// event" privilege that a listen-only `CGEventTap` for key events needs; Reelbird does not
    /// need Accessibility for keystrokes. Mouse clicks and scrolls need no permission.
    case inputMonitoring

    public var displayName: String {
        switch self {
        case .screen: "Screen Recording"
        case .microphone: "Microphone"
        case .camera: "Camera"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    /// The System Settings pane for this permission.
    public var settingsURL: URL {
        let anchor = switch self {
        case .screen: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        case .camera: "Privacy_Camera"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

public enum PermissionState: String, Codable, Hashable, Sendable {
    case granted, denied, notDetermined
}

/// Checks and requests the privacy permissions. Safe to call from any thread.
public enum Permissions {
    private static let askedKey = "ReelbirdCapture.askedScreenPermission"

    /// Current state without prompting.
    ///
    /// Screen Recording can't tell "denied" from "never asked"; this returns `.notDetermined`
    /// until `request(.screen)` has been called once, `.denied` afterwards.
    public static func status(_ p: Permission) -> PermissionState {
        switch p {
        case .screen:
            if CGPreflightScreenCaptureAccess() { return .granted }
            return UserDefaults.standard.bool(forKey: askedKey) ? .denied : .notDetermined
        case .microphone: return avStatus(.audio)
        case .camera: return avStatus(.video)
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined
        case .inputMonitoring:
            // CGPreflightListenEventAccess is the check paired with event taps; IOHIDCheckAccess
            // (same privilege) additionally tells "denied" from "never asked".
            if CGPreflightListenEventAccess() { return .granted }
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted: return .granted
            case kIOHIDAccessTypeDenied: return .denied
            default: return .notDetermined
            }
        }
    }

    /// Prompts if the system allows it and returns the resulting state.
    /// Screen Recording usually needs an app relaunch after the first grant.
    public static func request(_ p: Permission) async -> PermissionState {
        switch p {
        case .screen:
            UserDefaults.standard.set(true, forKey: askedKey)
            if CGPreflightScreenCaptureAccess() { return .granted }
            if CGRequestScreenCaptureAccess() { return .granted }
            // Enumerating shareable content registers the app in the Screen Recording list.
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                return CGPreflightScreenCaptureAccess() ? .granted : .denied
            } catch {
                return .denied
            }
        case .microphone:
            return await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        case .camera:
            return await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        case .accessibility:
            let key = "AXTrustedCheckOptionPrompt" // kAXTrustedCheckOptionPrompt
            return AXIsProcessTrustedWithOptions([key: true] as CFDictionary) ? .granted : .notDetermined
        case .inputMonitoring:
            // Prompts once per install; afterwards the person must switch it on in System Settings
            // (openSettings(for: .inputMonitoring)), and the app may need a relaunch.
            if CGRequestListenEventAccess() { return .granted }
            if IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) { return .granted }
            return status(.inputMonitoring)
        }
    }

    /// Opens the System Settings pane where the person can turn the permission on.
    public static func openSettings(for p: Permission) {
        let url = p.settingsURL
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    private static func avStatus(_ type: AVMediaType) -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
}
