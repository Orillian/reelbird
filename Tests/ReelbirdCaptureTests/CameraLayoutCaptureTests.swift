import CoreGraphics
import Foundation
import ReelbirdCore
import Testing
@testable import ReelbirdCapture

/// The layout shortcut while recording: each switch is logged with the camera events on the recording clock
/// (a switch while paused at the resume), and the first edit opens with matching layout segments.
@Test func liveLayoutSwitchesSeedLayoutSegments() async throws {
    let url = tempBundleURL("camera-layouts")
    defer { try? FileManager.default.removeItem(at: url) }
    var config = SyntheticFrameSource.Configuration()
    config.camera = PixelSize(width: 640, height: 480)
    config.capturedArea = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    var o = options()
    o.cameraID = "synthetic"
    let session = RecordingSession(options: o, bundleURL: url, frameSource: SyntheticFrameSource(configuration: config))
    let d = 200.0, inset = 0.025 * 1080
    session.updateCameraBubble(frame: CGRect(x: 1920 - inset - d, y: 1080 - inset - d, width: d, height: d), shape: .circle)
    try await session.start()
    await sleep(0.8)
    let fullAt = RecordingSession.hostTime
    session.updateCameraLayout(.fullCamera, atHostTime: fullAt)
    await sleep(0.8)
    session.updateCameraLayout(.screenOnly)
    await sleep(0.6)
    await session.pause()
    await sleep(0.2)
    session.updateCameraLayout(.overlay) // while paused: logged at the resume
    await sleep(0.2)
    await session.resume()
    await sleep(0.6)
    let bundle = try await session.stop()

    let events = try bundle.readEvents().filter { $0.type == .camera }
    #expect(events.first?.layout == nil, "a take that never switched writes no layout: \(events.map(\.layout))")
    #expect(events.dropFirst().map(\.layout) == ["fullCamera", "screenOnly", "overlay"], "\(events.map(\.layout))")
    #expect(abs(events[1].t - 0.8) < 0.3, "on the recording clock: \(events[1].t)")
    let pause = try #require(try bundle.readManifest().pauses.first)
    #expect(abs(events[3].t - pause.end) < 1e-3, "switched while paused: logged at the resume")

    let edit = try bundle.readEdit()
    #expect(edit.layouts.map(\.kind) == [.fullCamera, .screenOnly], "\(edit.layouts)")
    #expect(edit.layouts[0].range.end == edit.layouts[1].range.start, "back to back")
    #expect(abs(edit.layouts[1].range.end - pause.end) < 1e-3)
    #expect(edit.camera.position == NormPoint(x: 1, y: 1), "placing the bubble still works")
}
