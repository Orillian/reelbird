import CoreAudio
import Foundation
import ReelbirdCore

/// Small CoreAudio lookups for input devices: transport type, nominal sample rate, liveness and the
/// system default input. Device UIDs are the same strings as `AVCaptureDevice.uniqueID` (what
/// ScreenCaptureKit's `microphoneCaptureDeviceID` takes).
enum CoreAudioDevices {
    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func deviceID(forUID uid: String) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { p in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<CFString>.size), p, &size, &device)
        }
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func transport(_ id: AudioObjectID) -> MicTransport? {
        uint32(id, kAudioDevicePropertyTransportType).map { MicTransport(coreAudio: $0) }
    }

    static func nominalSampleRate(_ id: AudioObjectID) -> Double? {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, value > 0 else { return nil }
        return value
    }

    static func hasInput(_ id: AudioObjectID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    static func isAlive(_ id: AudioObjectID) -> Bool { (uint32(id, kAudioDevicePropertyDeviceIsAlive) ?? 0) != 0 }

    /// The system default input's UID and name.
    static func defaultInput() -> (uid: String, name: String)? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown, let uid = string(device, kAudioDevicePropertyDeviceUID) else { return nil }
        return (uid, string(device, kAudioObjectPropertyName) ?? uid)
    }
}

/// Whether the locked recording microphone is still there, and what macOS's default input is now.
public struct MicrophonePresence: Sendable, Hashable {
    public var connected: Bool
    public var systemDefaultID: String?
    public var systemDefaultName: String?
    public init(connected: Bool, systemDefaultID: String? = nil, systemDefaultName: String? = nil) {
        self.connected = connected; self.systemDefaultID = systemDefaultID; self.systemDefaultName = systemDefaultName
    }
}
