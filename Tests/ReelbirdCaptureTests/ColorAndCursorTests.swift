import AppKit
import AVFoundation
import Foundation
import ReelbirdCore
import Testing
@testable import ReelbirdCapture

/// Writes `frames` BGRA frames of one grey level through a real SegmentedWriter + consolidation and
/// returns the consolidated file.
func writeGrey(_ level: UInt8, spec: VideoSpec, in dir: URL) async throws -> URL {
    let w = try SegmentedWriter(kind: .screen, directory: dir, video: spec, audio: nil, realTime: false)
    try w.start(at: 0)
    var pool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(nil, nil, [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                       kCVPixelBufferWidthKey as String: spec.size.width, kCVPixelBufferHeightKey as String: spec.size.height,
                                       kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &pool)
    for i in 0..<15 {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        memset(base, Int32(level), CVPixelBufferGetBytesPerRow(buffer) * spec.size.height)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        w.append(pixelBuffer: buffer, at: Double(i) / 30)
    }
    try await w.finish(endTime: 0.5)
    let consolidated = try SegmentStore.consolidate(directory: dir, kind: .screen)
    let summary = try #require(consolidated)
    return dir.deletingLastPathComponent().appendingPathComponent(summary.file)
}

/// Decodes the frame at 0.2 s the way a colour-managed player does (into sRGB) and returns its grey level.
func displayedGrey(_ url: URL) async throws -> Int {
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    let (image, _) = try await gen.image(at: CMTime(seconds: 0.2, preferredTimescale: 600))
    var px = [UInt8](repeating: 0, count: 4)
    let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let ctx = try #require(CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                     space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.draw(image, in: CGRect(x: -10, y: -10, width: image.width, height: image.height))
    return Int(px[1])
}

@Test func screenVideoIsTaggedSRGBAndDisplaysUnchanged() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rb-color-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let spec = EncoderSettings.screen(size: PixelSize(width: 64, height: 64), frameRate: 30, quality: .high)
    #expect(spec.srgbTransfer)
    let url = try await writeGrey(128, spec: spec, in: root.appendingPathComponent("screen"))
    let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
    let fd = try #require(try await track.load(.formatDescriptions).first)
    let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
    #expect(ext[kCVImageBufferTransferFunctionKey as String] as? String == kCVImageBufferTransferFunction_sRGB as String)
    #expect(ext[kCVImageBufferColorPrimariesKey as String] as? String == kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
    #expect(ext[kCVImageBufferYCbCrMatrixKey as String] as? String == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    let grey = try await displayedGrey(url)
    #expect(abs(grey - 128) <= 2, "sRGB 128 displayed as \(grey)")

    // Control: the old BT.709 transfer tag on the same pixels is what looked washed out.
    var old = spec
    old.srgbTransfer = false
    let oldGrey = try await displayedGrey(try await writeGrey(128, spec: old, in: root.appendingPathComponent("old")))
    print("sRGB 128 displays as \(grey) with the sRGB tag, \(oldGrey) with the BT.709 tag")
    // The camera keeps BT.709 (cameras deliver BT.709-encoded video).
    #expect(!EncoderSettings.camera(size: PixelSize(width: 1280, height: 720), frameRate: 30).srgbTransfer)
}

@MainActor @Test func cursorsAreSavedAtFourTimesWithPixelHotSpots() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rb-cursor-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let recorder = CursorRecorder(directory: dir, indexURL: dir.appendingPathComponent("cursors.json"))
    func image(_ size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { r in NSColor.black.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2)).fill(); return true }
    }
    let small = try #require(recorder.register(image: image(NSSize(width: 16, height: 24)), hotSpot: NSPoint(x: 3, y: 5)))
    let big = try #require(recorder.register(image: image(NSSize(width: 256, height: 128)), hotSpot: NSPoint(x: 128, y: 64)))
    recorder.writeIndex()
    let infos = Dictionary(uniqueKeysWithValues: try JSONCoding.decoder.decode([CursorImageInfo].self,
        from: Data(contentsOf: dir.appendingPathComponent("cursors.json"))).map { ($0.id, $0) })
    func pngSize(_ id: String) throws -> (Int, Int) {
        let src = try #require(CGImageSourceCreateWithURL(dir.appendingPathComponent("\(id).png") as CFURL, nil))
        let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        return (img.width, img.height)
    }
    let s = try #require(infos[small])
    #expect(try pngSize(small) == (64, 96))
    #expect(s.width == 16 && s.height == 24 && s.hotX == 12 && s.hotY == 20)
    // Large cursors are capped at 512 px a side; the renderer's scale (PNG width ÷ width) stays consistent.
    let b = try #require(infos[big])
    #expect(try pngSize(big) == (512, 256))
    #expect(b.width == 256 && b.hotX == 256 && b.hotY == 128)
}
