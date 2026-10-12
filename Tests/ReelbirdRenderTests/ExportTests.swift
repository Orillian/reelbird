@preconcurrency import AVFoundation
import Foundation
import ImageIO
import Testing
import ReelbirdCore
@testable import ReelbirdRender

struct MediaInfo {
    var duration: Double
    var size: CGSize
    var codec: String
    var audioCodec: String?
    var frameRate: Float
}

func inspect(_ url: URL) async throws -> MediaInfo {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    let v = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let (size, fds, fps) = try await v.load(.naturalSize, .formatDescriptions, .nominalFrameRate)
    func fourCC(_ fd: CMFormatDescription) -> String {
        let c = CMFormatDescriptionGetMediaSubType(fd)
        return String(bytes: [UInt8(c >> 24 & 0xff), UInt8(c >> 16 & 0xff), UInt8(c >> 8 & 0xff), UInt8(c & 0xff)], encoding: .ascii) ?? "?"
    }
    var audio: String?
    if let a = try await asset.loadTracks(withMediaType: .audio).first, let afd = try await a.load(.formatDescriptions).first {
        audio = fourCC(afd)
    }
    return MediaInfo(duration: duration, size: size, codec: fds.first.map(fourCC) ?? "?", audioCodec: audio, frameRate: fps)
}

/// CPU seconds used by this process so far (user + system).
func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
}

@Test func export1080pAllFormats() async throws {
    var o = Synthetic.Options()
    o.width = 1920; o.height = 1080; o.fps = 30; o.seconds = 5; o.camera = true
    let bundle = try await Synthetic.makeBundle(o)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let edit = try bundle.readEdit()
    for format in [ExportOptions.Format.mp4H264, .mp4HEVC, .proRes] {
        let progress = Box<[Double]>([])
        let clock = ContinuousClock()
        var url: URL!
        let elapsed = try await clock.measure {
            url = try await Exporter.export(bundle: bundle, edit: edit, options: ExportOptions(format: format)) { p in progress.value.append(p) }
        }
        let info = try await inspect(url)
        print("1080p30 \(format): \(elapsed), \(String(format: "%.0f", 150 / elapsed.secs)) fps, \(try FileManager.default.attributesOfItem(atPath: url.path)[.size] ?? 0) bytes")
        #expect(url.path.hasPrefix(bundle.exportsURL.path))
        #expect(abs(info.duration - 5) < 0.1, "\(format) duration \(info.duration)")
        #expect(info.size == CGSize(width: 1920, height: 1080))
        let expected = ["mp4H264": "avc1", "mp4HEVC": "hvc1", "proRes": "apcn"][format.rawValue]
        #expect(info.codec == expected, "\(format) codec \(info.codec)")
        #expect(info.audioCodec == "aac ", "audio \(String(describing: info.audioCodec))")
        #expect(progress.value.last == 1)
        #expect(progress.value == progress.value.sorted())
    }
    // GIF: 15 fps, ≤ 540 px tall, 5 s of delays.
    let gif = try await Exporter.export(bundle: bundle, edit: edit, options: ExportOptions(format: .gif)) { _ in }
    let src = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
    #expect(CGImageSourceGetCount(src) == 75)
    let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
    #expect(props[kCGImagePropertyPixelHeight] as? Int == 540)
    #expect(props[kCGImagePropertyPixelWidth] as? Int == 960)
    var total = 0.0
    for i in 0..<CGImageSourceGetCount(src) {
        let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
        let g = p?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        total += (g?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (g?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
    }
    #expect(abs(total - 5) < 0.05, "gif duration \(total)")
}

@Test func exportRespectsCutsTrimSizeAndRate() async throws {
    var o = Synthetic.Options()
    o.seconds = 5
    let bundle = try await Synthetic.makeBundle(o)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    var edit = try bundle.readEdit()
    edit.trim = TimeRange(start: 0.5, end: 5)
    edit.cuts = [TimeRange(start: 1, end: 2)]
    edit.title = "Cut: test/1"
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent("rb-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: dest) }
    let url = try await Exporter.export(bundle: bundle, edit: edit, options: ExportOptions(format: .mp4H264, height: 480, frameRate: 24, destination: dest)) { _ in }
    #expect(url == dest)
    let info = try await inspect(url)
    #expect(abs(info.duration - 3.5) < 0.1, "duration \(info.duration)")
    #expect(info.size == CGSize(width: 854, height: 480))
    #expect(abs(info.frameRate - 24) < 0.5)
    // Default naming sanitises the title.
    let named = try await Exporter.export(bundle: bundle, edit: edit, options: ExportOptions(format: .mp4HEVC, height: 360)) { _ in }
    #expect(named.lastPathComponent.hasPrefix("Cut  test 1 "))
    // Everything cut → a clear error.
    edit.cuts = [TimeRange(start: 0, end: 5)]
    await #expect(throws: RenderError.nothingToExport) {
        _ = try await Exporter.export(bundle: bundle, edit: edit, options: ExportOptions()) { _ in }
    }
}

@Test func exportCancels() async throws {
    var o = Synthetic.Options()
    o.width = 1920; o.height = 1080; o.seconds = 6; o.fps = 60
    let bundle = try await Synthetic.makeBundle(o)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let edit = try bundle.readEdit()
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent("rb-cancel-\(UUID().uuidString).mov")
    let task = Task { try await Exporter.export(bundle: bundle, edit: edit, options: ExportOptions(format: .proRes, destination: dest)) { _ in } }
    try await Task.sleep(for: .milliseconds(150))
    task.cancel()
    let result = await task.result
    #expect(throws: CancellationError.self) { try result.get() }
    #expect(!FileManager.default.fileExists(atPath: dest.path))
}

@Test func posterFromSavedEdit() async throws {
    let bundle = try await Synthetic.makeBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let img = try await Thumbnailer.poster(bundle: bundle, at: 1, maxWidth: 640)
    #expect(img.width == 640 && img.height == 360)
}

/// 4K exports + throughput benchmark. Heavy: run with `RB_BENCH=1 research/heavy.sh scripts/test.sh --filter benchmark4K`.
@Test func benchmark4K() async throws {
    guard ProcessInfo.processInfo.environment["RB_BENCH"] != nil else { return }
    var o = Synthetic.Options()
    o.width = 3840; o.height = 2160; o.fps = 60; o.seconds = 5; o.codec = .hevc; o.camera = true; o.captureScale = 2
    let bundle = try await Synthetic.makeBundle(o)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    var edit = try bundle.readEdit()
    edit.cursor.showKeystrokes = true
    let frames = 300.0
    for format in [ExportOptions.Format.mp4H264, .mp4HEVC, .proRes] {
        let clock = ContinuousClock()
        let cpu0 = cpuSeconds()
        var url: URL!
        let elapsed = try await clock.measure {
            url = try await Exporter.export(bundle: bundle, edit: edit, options: ExportOptions(format: format)) { _ in }
        }
        let cpu = cpuSeconds() - cpu0
        let info = try await inspect(url)
        let fps = frames / elapsed.secs
        print(String(format: "BENCH 4K60 → %@ 3840x2160: %.2f s, %.0f fps (%.2fx realtime), CPU %.0f%% avg",
                     format.rawValue, elapsed.secs, fps, fps / 60, cpu / elapsed.secs * 100))
        #expect(abs(info.duration - 5) < 0.1)
        #expect(info.size == CGSize(width: 3840, height: 2160))
        if format != .proRes { #expect(fps >= 60, "4K export slower than realtime: \(fps) fps") }
    }
    let gifClock = ContinuousClock()
    let gifTime = try await gifClock.measure { _ = try await Exporter.export(bundle: bundle, edit: edit, options: ExportOptions(format: .gif)) { _ in } }
    print("BENCH 4K60 → GIF 960x540@15: \(gifTime)")
}

extension Duration {
    var secs: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
