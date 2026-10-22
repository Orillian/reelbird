@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import Testing
import ReelbirdAI
import ReelbirdCore
import ReelbirdGuide
import ReelbirdShare
@testable import ReelbirdRender

/// The step guide end to end on the realistic demo recording (`DemoFixture`): the steps and what each click hit,
/// the step images, the three exports, the text layer read from an exported video, and what a link publishes.
@Suite(.serialized) struct GuideTests {
    @Test func demoRecordingMakesAGuide() async throws {
        let dir = testTemporaryDirectory.appendingPathComponent("rb-guide-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try await DemoFixture.makeBundle(at: dir.appendingPathComponent("Demo.reelbird"))
        let manifest = try bundle.readManifest()
        let edit = EditDocument.initial(for: manifest)

        // Steps: every click of the script, what it hit read from the screen, the typing folded into its field.
        let steps = try await StepScanner.steps(bundle: bundle, edit: edit, options: StepScanner.Options(useModel: false))
        #expect(steps.map(\.kind) == [.click, .click, .type, .click, .click, .click, .click, .click])
        #expect(steps.map(\.label) == ["Inbox", "+ New Task", "Task name", "Save", "Fix flaky checkout test", "Share", "Copy link", nil])
        #expect(steps[0].text == "Click \"Inbox\"")
        #expect(steps[2].text == "Type in \"Task name\", then press Return" || steps[2].text == "Type in \"Task name\"")
        #expect(steps.last?.text == "Click here")
        // Typing shows only when allowed.
        var shown = edit
        shown.guide.showTypedText = true
        let typed = try await StepScanner.steps(bundle: bundle, edit: shown, options: StepScanner.Options(useModel: false))
        #expect(typed[2].text.hasPrefix("Type \"Record the launch demo for Friday\""))
        // The scan is cached and reused.
        let inputs = try #require(bundle.stepInputs(manifest: manifest))
        #expect(bundle.readSteps(inputs: inputs)?.steps.count == steps.count)

        // Images: the screen just before each click, cropped like the video, no background.
        let built = try await GuideBuilder.build(bundle: bundle, edit: edit, steps: steps)
        #expect(built.images.count == steps.count)
        #expect(built.images.allSatisfy { $0.width == 1600 && $0.height == 1000 })

        // Exports.
        let md = try GuideExport.write(built, title: "Tasks demo", format: .markdown, to: dir.appendingPathComponent("md"))
        let mdText = try String(contentsOf: md, encoding: .utf8)
        #expect(mdText.hasPrefix("# Tasks demo\n"))
        #expect(mdText.contains("1. Click \"Inbox\""))
        #expect(mdText.contains("![Step 8](images/08.jpg)"))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("md/images/08.jpg").path))
        let skill = try GuideExport.write(built, title: "Tasks: demo", format: .skill, to: dir.appendingPathComponent("skill"))
        let skillText = try String(contentsOf: skill, encoding: .utf8)
        #expect(skillText.hasPrefix("---\nname: tasks-demo\ndescription: \"Tasks: demo: step-by-step"))
        let html = try GuideExport.write(built, title: "Tasks demo", format: .html, to: dir.appendingPathComponent("html"))
        let page = try String(contentsOf: html, encoding: .utf8)
        #expect(page.contains("\"steps/01.jpg\""))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("html/steps/08.jpg").path))
        #expect(throws: GuideExport.ExportError.self) {
            try GuideExport.write(built, title: "Tasks demo", format: .html, to: dir.appendingPathComponent("html"))
        }

        // The text layer, from what viewers see.
        let video = try await Exporter.export(bundle: bundle, edit: edit,
                                              options: ExportOptions(format: .mp4H264, height: 1080, destination: dir.appendingPathComponent("v.mp4")),
                                              progress: { _ in })
        let layer = try await ScreenText.read(video: video)
        #expect(layer.width == 1728 && layer.height == 1080)
        let first = try #require(layer.frames.first)
        #expect(first.start == 0)
        let inbox = try #require(first.lines.first { $0.text == "Inbox" })
        #expect(inbox.x < 0.25 && inbox.y < 0.25)
        #expect(layer.frames.contains { f in f.lines.contains { $0.text.contains("Record the launch demo") } })
        #expect(zip(layer.frames, layer.frames.dropFirst()).allSatisfy { $0.end <= $1.start + 1e-9 })

        // What a link publishes, and nothing when both are off.
        let work = dir.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let assets = await GuideBuilder.shareAssets(bundle: bundle, edit: edit, video: video, steps: steps, workDir: work)
        guard case .replace(let guide) = assets.guide, case .replace(let textURL) = assets.text else {
            Issue.record("expected a guide and a text layer"); return
        }
        #expect(guide.steps.count == 8 && guide.images.allSatisfy { $0 != nil })
        #expect(guide.steps.map(\.n) == Array(1...8))
        let inboxStep = guide.steps[0]
        #expect(inboxStep.w == 1600 && inboxStep.h == 1000 && (inboxStep.x ?? 0) > 0.1 && (inboxStep.x ?? 1) < 0.15)
        #expect(try JSONDecoder().decode(TextLayer.self, from: Data(contentsOf: textURL)) == layer)
        var off = edit
        off.guide.share = false
        off.guide.copyText = false
        let none = await GuideBuilder.shareAssets(bundle: bundle, edit: off, video: video, steps: steps, workDir: work)
        if case .remove = none.guide {} else { Issue.record("guide should be off") }
        if case .remove = none.text {} else { Issue.record("text layer should be off") }
    }
}

/// Writes what a share link of the demo recording would serve into `RB_GUIDE_PREVIEW_DIR` (index.html, the MP4,
/// step pictures and the text layer), to look at the viewer page with a real guide:
///
///     RB_GUIDE_PREVIEW_DIR=/path scripts/test.sh --filter guideSharePreview   (then serve the folder over HTTP)
@Test func guideSharePreview() async throws {
    guard let path = ProcessInfo.processInfo.environment["RB_GUIDE_PREVIEW_DIR"] else { return }
    let out = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: out.appendingPathComponent("steps.1", isDirectory: true), withIntermediateDirectories: true)
    let work = testTemporaryDirectory.appendingPathComponent("rb-guide-preview-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let bundle = try await DemoFixture.makeBundle(at: work.appendingPathComponent("Demo.reelbird"))
    let manifest = try bundle.readManifest()
    var edit = EditDocument.initial(for: manifest)
    edit.title = "Add a task and share the list"
    let video = try await Exporter.export(bundle: bundle, edit: edit,
                                          options: ExportOptions(format: .mp4H264, height: 1080, destination: out.appendingPathComponent("video.1.mp4")),
                                          progress: { _ in })
    let assets = await GuideBuilder.shareAssets(bundle: bundle, edit: edit, video: video, steps: nil, workDir: work)
    guard case .replace(var guide) = assets.guide, case .replace(let text) = assets.text else { Issue.record("no guide"); return }
    for i in guide.steps.indices {
        let name = String(format: "steps.1/%02d.jpg", i + 1)
        try guide.images[i]?.write(to: out.appendingPathComponent(name))
        guide.steps[i].image = name
    }
    try FileManager.default.copyItem(at: text, to: out.appendingPathComponent("text.1.json"))
    let info = await ShareServiceProbe.videoSize(video)
    var meta = ViewerMeta(id: "preview", title: edit.title ?? "", status: .ready, createdAt: manifest.createdAt, duration: info.duration,
                          pageURL: "./", baseURL: "./", video: "video.1.mp4", width: info.width, height: info.height, revision: 1)
    meta.guide = ViewerMeta.Guide(steps: guide.steps)
    meta.text = "text.1.json"
    try Data(ViewerPage.html(meta).utf8).write(to: out.appendingPathComponent("index.html"))
    print("GUIDE preview written to \(out.path) with \(guide.steps.count) steps")
}

/// The exported video's length and size (what `ShareService.publish` puts in meta.json).
enum ShareServiceProbe {
    static func videoSize(_ url: URL) async -> (duration: Double?, width: Int?, height: Int?) {
        let asset = AVURLAsset(url: url)
        let d = try? await asset.load(.duration)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize) else { return (d?.seconds, nil, nil) }
        return (d?.seconds, Int(size.width), Int(size.height))
    }
}
