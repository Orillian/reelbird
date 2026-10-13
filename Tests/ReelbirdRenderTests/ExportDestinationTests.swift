import Foundation
import Testing
import ReelbirdCore
@testable import ReelbirdRender

@Test func exportIntoChosenFolderUsesDefaultNameInsideIt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rb-dest-\(UUID().uuidString)")
    let folder = root.appendingPathComponent("Downloads", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = ProjectBundle(url: root.appendingPathComponent("Demo.reelbird"))
    let manifest = ProjectManifest(title: "Reelbird 2026-10-12 at 17.32.57", appVersion: "test",
                                   capture: CaptureInfo(source: .synthetic(name: "t"), pixelSize: PixelSize(width: 640, height: 360), scale: 1, frameRate: 30),
                                   clock: ClockInfo(originHostTime: 0), duration: 1)
    // A folder (existing, plain path) → file inside it, never the folder itself.
    let plain = URL(fileURLWithPath: folder.path)
    let a = try Exporter.destination(bundle: bundle, manifest: manifest, edit: EditDocument(),
                                     options: ExportOptions(format: .mp4H264, destination: plain))
    #expect(a.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
    #expect(a.lastPathComponent == "Reelbird 2026-10-12 at 17.32.57.mp4")
    // A file path is used as given.
    let file = folder.appendingPathComponent("mine.mp4")
    let b = try Exporter.destination(bundle: bundle, manifest: manifest, edit: EditDocument(),
                                     options: ExportOptions(format: .mp4H264, destination: file))
    #expect(b == file)
    // The temporary file is never written next to the destination.
    #expect(Exporter.partialURL(for: a).deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL)
}
