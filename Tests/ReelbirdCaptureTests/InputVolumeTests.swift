import Foundation
import Testing
@testable import ReelbirdCapture

/// Queries only: never changes the machine's input volume.
@Test func inputVolumeQueriesDoNotCrash() {
    let ids = ["default", "", "no-such-device-uid"] + Devices.microphones().map(\.id)
    for id in ids {
        if let v = Devices.inputVolume(deviceID: id) {
            #expect(v >= 0 && v <= 1, "\(id): \(v)")
        }
    }
    #expect(Devices.inputVolume(deviceID: "no-such-device-uid") == nil)
    #expect(Devices.coreAudioDevice("no-such-device-uid") == nil)
    print("INPUT VOLUME default: \(Devices.inputVolume(deviceID: "default").map { String($0) } ?? "not settable")")
}
