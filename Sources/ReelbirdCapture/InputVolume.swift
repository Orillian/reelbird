import CoreAudio
import Foundation

extension Devices {
    /// The hardware input volume (0…1) of a microphone, or `nil` when the device has no settable input volume
    /// (many USB mics and interfaces only have a gain knob). `deviceID` is a `MediaDevice.id` or "default".
    public static func inputVolume(deviceID: String) -> Float? {
        guard let dev = coreAudioDevice(deviceID), let element = volumeElements(dev).first else { return nil }
        var address = volumeAddress(element)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(dev, &address, 0, nil, &size, &value) == noErr else { return nil }
        return min(1, max(0, value))
    }

    /// Sets the hardware input volume (0…1) on every settable volume control of the device (the main one,
    /// or each channel). Returns whether it took. This is the same setting as System Settings › Sound › Input.
    @discardableResult
    public static func setInputVolume(_ volume: Float, deviceID: String) -> Bool {
        guard let dev = coreAudioDevice(deviceID) else { return false }
        var value = Float32(min(1, max(0, volume)))
        var ok = false
        for element in volumeElements(dev) {
            var address = volumeAddress(element)
            if AudioObjectSetPropertyData(dev, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr { ok = true }
        }
        return ok
    }

    private static func volumeAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeInput, mElement: element)
    }

    /// The device's settable input volume elements: the main element if it has one, else channels 1 and 2.
    private static func volumeElements(_ dev: AudioObjectID) -> [AudioObjectPropertyElement] {
        func settable(_ element: AudioObjectPropertyElement) -> Bool {
            var address = volumeAddress(element)
            guard AudioObjectHasProperty(dev, &address) else { return false }
            var isSettable: DarwinBoolean = false
            return AudioObjectIsPropertySettable(dev, &address, &isSettable) == noErr && isSettable.boolValue
        }
        if settable(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter(settable)
    }

    /// The Core Audio device for a capture device ID. For Core Audio devices `AVCaptureDevice.uniqueID` is the
    /// Core Audio device UID.
    static func coreAudioDevice(_ deviceID: String) -> AudioObjectID? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        if deviceID == "default" || deviceID.isEmpty {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &dev) == noErr else { return nil }
        } else {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var uid = deviceID as CFString
            let status = withUnsafeMutablePointer(to: &uid) { uidPtr in
                AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &dev)
            }
            guard status == noErr else { return nil }
        }
        return dev == kAudioObjectUnknown ? nil : dev
    }
}
