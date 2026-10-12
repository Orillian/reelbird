import Foundation
import ReelbirdCapture

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
