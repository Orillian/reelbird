@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import Testing
import ReelbirdCore
@testable import ReelbirdRender

/// An edit with nothing animated, so frames show the screen exactly.
private func flatEdit(_ manifest: ProjectManifest) -> EditDocument {
    var e = EditDocument.initial(for: manifest)
    e.background.kind = .solid
    e.background.colors = [RGBA(hex: "#808080")!]
    e.background.shadow = 0
    e.background.motionBlur = false
    e.zoom.mode = .off
    e.cursor.visible = false
    e.camera.visible = false
    return e
}

/// A bundle whose screen flashes white for two frames at `flashes` (else near black) and whose microphone
/// clicks at the same instants: a clapperboard for A/V sync.
private func clapperBundle(width: Int = 640, height: Int = 360, fps: Int = 30, seconds: Double, flashes: [Double],
                           microphone: Bool = true) async throws -> ProjectBundle {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rb-sync-\(UUID().uuidString).reelbird")
    let bundle = try ProjectBundle.create(at: dir)
    let fm = FileManager.default
    for k in [TrackKind.screen, .microphone] { try fm.createDirectory(at: bundle.directory(for: k), withIntermediateDirectories: true) }
    let flashFrames = Set(flashes.flatMap { t -> [Int] in let n = Int((t * Double(fps)).rounded()); return [n, n + 1] })
    try await Synthetic.writeVideo(url: bundle.directory(for: .screen).appendingPathComponent("screen.mp4"), width: width, height: height,
                                   fps: fps, seconds: seconds, codec: .h264) { y, ys, uv, uvs, w, h, n in
        let luma: Int32 = flashFrames.contains(n) ? 235 : 20
        for r in 0..<h { memset(y + r * ys, luma, w) }
        for r in 0..<(h / 2) { memset(uv + r * uvs, 128, w) }
    }
    var tracks = [TrackInfo(kind: .screen, directory: "screen", file: "screen/screen.mp4", codec: "h264",
                            pixelSize: PixelSize(width: width, height: height), duration: seconds)]
    if microphone {
        var pcm = [Float](repeating: 0, count: Int(seconds * 48_000))
        // Click at the start of each flash frame (frame-aligned, like a real clap filmed at that frame).
        for t in flashes {
            let s = Int((t * Double(fps)).rounded() / Double(fps) * 48_000)
            for k in 0..<96 where s + k < pcm.count { pcm[s + k] = 0.8 * Float(exp(-Double(k) / 20)) * (k % 2 == 0 ? 1 : -1) }
        }
        try await DemoFixture.writePCM(url: bundle.directory(for: .microphone).appendingPathComponent("microphone.m4a"), samples: pcm)
        tracks.append(TrackInfo(kind: .microphone, directory: "microphone", file: "microphone/microphone.m4a", codec: "aac",
                                sampleRate: 48_000, channels: 1, duration: seconds))
    }
    let manifest = ProjectManifest(title: "Sync", appVersion: "test", status: .complete,
                                   capture: CaptureInfo(source: .synthetic(name: "sync"), pixelSize: PixelSize(width: width, height: height),
                                                        scale: 1, frameRate: fps),
                                   clock: ClockInfo(originHostTime: 0), tracks: tracks, duration: seconds)
    try bundle.writeManifest(manifest)
    return bundle
}

/// Output times of the first frame of each flash in an exported file.
private func flashTimes(_ url: URL) async throws -> [Double] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(out)
    reader.startReading()
    var times: [Double] = []
    var wasBright = false
    while let sb = out.copyNextSampleBuffer() {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let o = (CVPixelBufferGetHeight(pb) / 2) * CVPixelBufferGetBytesPerRow(pb) + (CVPixelBufferGetWidth(pb) / 2) * 4
        let bright = base[o + 1] > 128
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        if bright, !wasBright { times.append(CMSampleBufferGetPresentationTimeStamp(sb).seconds) }
        wasBright = bright
    }
    return times
}

/// Output times of each click onset in an exported file's audio.
private func clickTimes(_ url: URL) async throws -> [Double] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
    ])
    reader.add(out)
    reader.startReading()
    var times: [Double] = []
    var last = -1.0
    var index = 0
    var first: Double?
    while let sb = out.copyNextSampleBuffer() {
        if first == nil { first = CMSampleBufferGetPresentationTimeStamp(sb).seconds }
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
        let n = CMBlockBufferGetDataLength(bb) / 4
        var samples = [Float](repeating: 0, count: n)
        samples.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
        for (k, v) in samples.enumerated() where abs(v) > 0.25 {
            let t = (first ?? 0) + Double(index + k) / 48_000
            if t - last > 0.1 { times.append(t) }
            last = t
        }
        index += n
    }
    return times
}

@Test func audioAndVideoStayInSyncAcrossCuts() async throws {
    let flashes = [0.5, 1.7, 2.9, 4.1, 5.3]
    let bundle = try await clapperBundle(seconds: 6, flashes: flashes)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    var edit = flatEdit(manifest)
    // Trim and cut at times that fall between frames.
    edit.trim = TimeRange(start: 0.23, end: 5.91)
    edit.cuts = [TimeRange(start: 1.13, end: 1.41), TimeRange(start: 3.37, end: 3.52)]
    let timeline = EditTimeline(duration: 6, trim: edit.trim, cuts: edit.cuts)
    for fps in [30, 60] {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("rb-sync-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: dest) }
        _ = try await Exporter.export(bundle: bundle, edit: edit, options: ExportOptions(format: .mp4H264, frameRate: fps, destination: dest)) { _ in }
        let video = try await flashTimes(dest), audio = try await clickTimes(dest)
        let expected = flashes.compactMap { timeline.outputTime(forSource: ($0 * 30).rounded() / 30) }
        #expect(video.count == expected.count, "\(fps) fps flashes \(video) expected \(expected)")
        #expect(audio.count == expected.count, "\(fps) fps clicks \(audio) expected \(expected)")
        let frame = 1 / Double(fps)
        print("SYNC \(fps) fps: flashes \(video.map { String(format: "%.4f", $0) }), clicks \(audio.map { String(format: "%.4f", $0) })")
        for (v, a) in zip(video, audio) {
            #expect(abs(v - a) <= frame + 1e-3, "\(fps) fps: flash at \(v), click at \(a)")
        }
        for (v, e) in zip(video, expected) { #expect(abs(v - e) <= frame + 1e-3, "flash at \(v), expected \(e)") }
    }
}

@Test func exportIsTaggedSRGBAndColoursRoundTrip() async throws {
    let bundle = try await clapperBundle(seconds: 1, flashes: [], microphone: false)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    let edit = flatEdit(manifest)
    for format in [ExportOptions.Format.mp4H264, .mp4HEVC] {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("rb-color-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: dest) }
        _ = try await Exporter.export(bundle: bundle, edit: edit, options: ExportOptions(format: format, destination: dest)) { _ in }
        let asset = AVURLAsset(url: dest)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let fd = try #require(try await track.load(.formatDescriptions).first)
        let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
        #expect(ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String == kCMFormatDescriptionTransferFunction_sRGB as String)
        #expect(ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
        #expect(ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String == kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)
        // Through Apple's colour-managed decode (what QuickTime and Safari show), the #808080 background stays 128.
        let gen = AVAssetImageGenerator(asset: asset)
        let (img, _) = try await gen.image(at: CMTime(value: 1, timescale: 2))
        let px = Pixels(img)
        #expect(px.near(4, 4, (128, 128, 128), tol: 2), "\(format) background shows as \(px[4, 4])")
    }
}

@Test func oddSizedWindowsNoAudioAndVerticalExport() async throws {
    // A window capture with odd pixel dimensions and no microphone.
    let bundle = try await clapperBundle(width: 1001, height: 701, seconds: 1.5, flashes: [0.5], microphone: false)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    var edit = EditDocument.initial(for: manifest)
    for (aspect, height, size) in [(CanvasSettings.Aspect.source, nil as Int?, CGSize(width: 1002, height: 702)),
                                   (.vertical, 1920, CGSize(width: 1080, height: 1920)),
                                   (.square, 721, CGSize(width: 722, height: 722))] {
        edit.canvas.aspect = aspect
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("rb-odd-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: dest) }
        _ = try await Exporter.export(bundle: bundle, edit: edit, options: ExportOptions(format: .mp4H264, height: height, destination: dest)) { _ in }
        let info = try await inspect(dest)
        #expect(info.size == size, "\(aspect): \(info.size)")
        #expect(info.audioCodec == nil)
        #expect(abs(info.duration - 1.5) < 0.1)
    }
}
