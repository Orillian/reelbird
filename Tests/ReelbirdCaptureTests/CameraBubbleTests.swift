import CoreGraphics
import Foundation
import ReelbirdCore
import Testing
@testable import ReelbirdCapture

/// A synthetic take with the live bubble dragged around: before recording (countdown), mid-take, while
/// paused and off the captured area. The log carries each place on the recording clock and the first edit
/// places the camera from it.
@Test func liveBubbleMovesAreRecordedAndPlaced() async throws {
    let url = tempBundleURL("camera-moves")
    defer { try? FileManager.default.removeItem(at: url) }
    var config = SyntheticFrameSource.Configuration()
    config.camera = PixelSize(width: 640, height: 480)
    config.capturedArea = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    var o = options()
    o.cameraID = "synthetic"
    let session = RecordingSession(options: o, bundleURL: url, frameSource: SyntheticFrameSource(configuration: config))
    let d = 200.0, inset = 0.035 * 1080
    // Countdown: first somewhere else, then the default corner; only the place at the start counts.
    session.updateCameraBubble(frame: CGRect(x: 400, y: 300, width: d, height: d), shape: .circle)
    session.updateCameraBubble(frame: CGRect(x: 1920 - inset - d, y: 1080 - inset - d, width: d, height: d), shape: .portrait)
    try await session.start()
    await sleep(1.0)
    // Dragged to the top-left corner (and a little past it, off the screen).
    let movedAt = RecordingSession.hostTime
    session.updateCameraBubble(frame: CGRect(x: -30, y: -20, width: d, height: d), shape: .portrait, atHostTime: movedAt)
    await sleep(0.4)
    await session.pause()
    await sleep(0.2)
    // Moved while paused: logged when recording resumes.
    session.updateCameraBubble(frame: CGRect(x: (1920 - d) / 2, y: (1080 - d) / 2, width: d, height: d), shape: .portrait)
    await sleep(0.3)
    await session.resume()
    await sleep(0.5)
    // A second display to the right: the nearest place on the recorded one is its right edge.
    session.updateCameraBubble(frame: CGRect(x: 2600, y: (1080 - d) / 2, width: d, height: d), shape: .portrait)
    await sleep(0.4)
    let bundle = try await session.stop()

    let events = try bundle.readEvents().filter { $0.type == .camera }
    #expect(events.count == 4, "camera events: \(events.map(\.t))")
    #expect(events.first?.t == 0)
    #expect(events.allSatisfy { $0.shape == "portrait" })
    #expect(events.allSatisfy { e in e.rect.map { $0.x >= 0 && $0.y >= 0 && $0.x + $0.width <= 1 + 1e-9 && $0.y + $0.height <= 1 + 1e-9 } ?? false },
            "every logged frame is inside the captured area")
    let manifest = try bundle.readManifest()
    let pause = try #require(manifest.pauses.first)
    #expect(abs(events[1].t - 1.0) < 0.25, "drag logged on the recording clock: \(events[1].t)")
    #expect(abs(events[2].t - pause.end) < 1e-3, "move made while paused is logged at the resume: \(events[2].t) vs \(pause)")

    let edit = try bundle.readEdit()
    #expect(edit.camera.shape == .portrait)
    #expect(edit.camera.position == NormPoint(x: 1, y: 1), "starts in the default corner")
    #expect(edit.camera.moves.count == 3)
    #expect(edit.camera.moves[0].position == NormPoint(x: 0, y: 0))
    #expect(edit.camera.moves[1].position == NormPoint(x: 0.5, y: 0.5))
    #expect(edit.camera.moves[2].position == NormPoint(x: 1, y: 0.5))
}

@Test func noCameraMeansNoCameraEvents() async throws {
    let url = tempBundleURL("camera-none")
    defer { try? FileManager.default.removeItem(at: url) }
    var config = SyntheticFrameSource.Configuration()
    config.capturedArea = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let session = RecordingSession(options: options(), bundleURL: url, frameSource: SyntheticFrameSource(configuration: config))
    session.updateCameraBubble(frame: CGRect(x: 10, y: 10, width: 100, height: 100), shape: .circle)
    try await session.start()
    await sleep(0.5)
    let bundle = try await session.stop()
    #expect(try bundle.readEvents().filter { $0.type == .camera }.isEmpty)
    #expect(try bundle.readEdit().camera.moves.isEmpty)
}
