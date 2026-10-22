import Foundation
import ReelbirdCore
import Testing
@testable import ReelbirdShare

/// A link carries the step guide (images per revision) and the text layer, and an update leaves nothing of the
/// previous revision's guide behind.
@Suite(.serialized) struct GuidePublishTests {
    static func guide(_ n: Int, note: String? = nil) -> SharedGuide {
        let steps = (1...n).map { i in
            ViewerMeta.Guide.Step(id: "c\(i)000", n: i, t: Double(i), kind: "click", text: "Click \"Item \(i)\"", note: note,
                                  section: i == 1 ? "Start" : nil, w: 160, h: 100, x: 0.5, y: 0.5,
                                  box: NormRect(x: 0.4, y: 0.45, width: 0.2, height: 0.1))
        }
        return SharedGuide(steps: steps, images: steps.map { _ in Data([0xFF, 0xD8, 0xFF, 0xD9]) })
    }

    @Test func publishCarriesTheGuideAndTheTextLayer() async throws {
        let server = try TestSupport.server()
        defer { server.stop() }
        let dir = try TestSupport.tempDir("guide")
        let video = try await Media.shared.polished()
        let bundle = try TestSupport.bundle(in: dir, duration: 3)
        let text = dir.appendingPathComponent("text.json")
        try JSONEncoder().encode(TextLayer(width: 640, height: 360, frames: [
            TextLayer.Frame(start: 0, end: 3, lines: [TextLayer.Line(text: "Inbox", x: 0.1, y: 0.1, w: 0.1, h: 0.03)]),
        ])).write(to: text)

        let info = try await ShareService.publish(bundle: bundle, video: video, poster: .keep, captions: .remove,
                                                  guide: .replace(Self.guide(3)), text: .replace(text),
                                                  destination: server.destination(), secret: server.secret, session: nil) { _ in }
        let layout = try #require(ShareLayout(info: info, destination: server.destination()))
        let m1 = try TestSupport.meta(server, layout)
        #expect(m1.guide?.steps.map(\.image) == ["steps.1/01.jpg", "steps.1/02.jpg", "steps.1/03.jpg"])
        #expect(m1.guide?.steps.first?.section == "Start")
        #expect(m1.text == "text.1.json")
        #expect(server.object(layout.key("steps.1/02.jpg"))?.contentType == "image/jpeg")
        #expect(server.object(layout.key("steps.1/02.jpg"))?.cacheControl?.contains("immutable") == true)
        #expect(server.object(layout.key("text.1.json"))?.contentType == "application/json")
        let html = String(decoding: try #require(server.object(layout.pageKeys[0])).data, as: UTF8.self)
        #expect(html.contains("steps.1/01.jpg") && html.contains("text.1.json"))

        // Update in place with a shorter guide: the old revision's images and text layer go.
        var manifest = try bundle.readManifest()
        manifest.share = info
        try bundle.writeManifest(manifest)
        let info2 = try await ShareService.publish(bundle: bundle, video: video, poster: .keep, captions: .remove,
                                                   guide: .replace(Self.guide(2)), text: .replace(text),
                                                   destination: server.destination(), secret: server.secret, session: nil) { _ in }
        let m2 = try TestSupport.meta(server, layout)
        #expect(m2.guide?.steps.map(\.image) == ["steps.2/01.jpg", "steps.2/02.jpg"])
        #expect(m2.text == "text.2.json")
        for gone in ["steps.1/01.jpg", "steps.1/02.jpg", "steps.1/03.jpg", "text.1.json"] {
            #expect(server.object(layout.key(gone)) == nil, "\(gone) should be deleted")
        }

        // A new video with the guide kept: its times belong to the old video, so it comes down.
        manifest.share = info2
        try bundle.writeManifest(manifest)
        _ = try await ShareService.publish(bundle: bundle, video: video, poster: .keep, captions: .remove,
                                           destination: server.destination(), secret: server.secret, session: nil) { _ in }
        let m3 = try TestSupport.meta(server, layout)
        #expect(m3.guide == nil && m3.text == nil)
        #expect(server.keys(prefix: layout.key("steps.2/")).isEmpty)
        #expect(server.object(layout.key("text.2.json")) == nil)
    }

    @Test func aLongGuideIsTrimmedToFitTheMeta() async throws {
        let server = try TestSupport.server()
        defer { server.stop() }
        let dir = try TestSupport.tempDir("guide-budget")
        let bundle = try TestSupport.bundle(in: dir, duration: 3)
        let note = String(repeating: "Long narration. ", count: 40)
        let info = try await ShareService.publish(bundle: bundle, video: nil, poster: .keep, captions: .remove,
                                                  guide: .replace(Self.guide(SharedGuide.maxSteps + 50, note: note)), text: .remove,
                                                  destination: server.destination(), secret: server.secret, session: nil) { _ in }
        let layout = try #require(ShareLayout(info: info, destination: server.destination()))
        let m = try TestSupport.meta(server, layout)
        let steps = try #require(m.guide?.steps)
        #expect(steps.count <= SharedGuide.maxSteps && steps.count > 50)
        #expect(steps.allSatisfy { ($0.note?.count ?? 0) <= 300 })
        #expect(try #require(server.object(layout.metaKey)).data.count < 200_000)
    }
}
