import CoreGraphics
import Foundation
import ReelbirdCore
import Testing
@testable import ReelbirdCapture

/// Markers dropped during a synthetic take land in events.jsonl on the recording clock, numbered, with their
/// label; a marker while paused is kept (it becomes a chapter where the video carries on); none after stop.
@Test func markersAreLoggedOnTheRecordingClock() async throws {
    let url = tempBundleURL("markers")
    defer { try? FileManager.default.removeItem(at: url) }
    var config = SyntheticFrameSource.Configuration()
    config.capturedArea = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let session = RecordingSession(options: options(mic: false, system: false), bundleURL: url,
                                   frameSource: SyntheticFrameSource(configuration: config))
    #expect(await session.addMarker() == nil, "no marker before the take starts")
    try await session.start()
    await sleep(0.6)
    let first = try #require(await session.addMarker())
    await sleep(0.5)
    let second = try #require(await session.addMarker(label: "  Bug shows up  "))
    await session.pause()
    await sleep(0.3)
    let paused = try #require(await session.addMarker())
    await session.resume()
    await sleep(0.4)
    let bundle = try await session.stop()
    #expect(await session.addMarker() == nil, "no marker after stop")

    #expect(first.number == 1 && first.label == "Marker 1")
    #expect(second.number == 2 && second.label == "Bug shows up")
    #expect(paused.number == 3)
    #expect(first.t > 0.3 && second.t > first.t + 0.3 && paused.t >= second.t, "times \(first.t) \(second.t) \(paused.t)")

    let manifest = try bundle.readManifest()
    let events = try bundle.readEvents().filter { $0.type == .marker }
    #expect(events.map(\.t) == [first.t, second.t, paused.t])
    #expect(events.map(\.label) == [nil, "Bug shows up", nil], "only given names are stored")
    #expect(events.allSatisfy { $0.t <= manifest.duration })

    let markers = Markers.resolve(edit: try bundle.readEdit(), events: try bundle.readEvents())
    #expect(markers.map(\.title) == ["Marker 1", "Bug shows up", "Marker 3"])
    #expect(markers.map(\.id) == ["m1", "m2", "m3"])
}
