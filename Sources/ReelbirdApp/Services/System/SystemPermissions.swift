import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import IOKit.hid

/// Real permission checks using the system APIs directly. Equivalent to
/// `ReelbirdCapture.Permissions`; kept in the app so Settings and onboarding show live state
/// before the capture module is wired in.
struct SystemPermissions: PermissionsService {
    private static let screenAskedKey = "permissions.screenAsked"

    func status(_ p: Permission) -> PermissionState {
        switch p {
        case .screen:
            if CGPreflightScreenCaptureAccess() { return .granted }
            return UserDefaults.standard.bool(forKey: Self.screenAskedKey) ? .denied : .notDetermined
        case .microphone: return Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        case .camera: return Self.map(AVCaptureDevice.authorizationStatus(for: .video))
        case .accessibility: return AXIsProcessTrusted() ? .granted : .notDetermined
        case .inputMonitoring:
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted: return .granted
            case kIOHIDAccessTypeDenied: return .denied
            default: return .notDetermined
            }
        }
    }

    func request(_ p: Permission) async -> PermissionState {
        switch p {
        case .screen:
            UserDefaults.standard.set(true, forKey: Self.screenAskedKey)
            return CGRequestScreenCaptureAccess() ? .granted : .denied
        case .microphone:
            return await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        case .camera:
            return await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        case .accessibility:
            let key = "AXTrustedCheckOptionPrompt" // kAXTrustedCheckOptionPrompt
            return AXIsProcessTrustedWithOptions([key: true] as CFDictionary) ? .granted : .notDetermined
        case .inputMonitoring:
            return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) ? .granted : .denied
        }
    }

    @MainActor func openSettings(for p: Permission) {
        let anchor = switch p {
        case .screen: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        case .camera: "Privacy_Camera"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func map(_ s: AVAuthorizationStatus) -> PermissionState {
        switch s {
        case .authorized: .granted
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }
}

/// Fixed permission states for snapshots and tests.
final class MockPermissions: PermissionsService, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [Permission: PermissionState]
    init(_ states: [Permission: PermissionState] = [:]) { self.states = states }
    func status(_ p: Permission) -> PermissionState { lock.withLock { states[p] ?? .notDetermined } }
    func request(_ p: Permission) async -> PermissionState {
        try? await Task.sleep(for: .milliseconds(300))
        return lock.withLock { states[p] = .granted; return .granted }
    }
    @MainActor func openSettings(for p: Permission) {}
}
