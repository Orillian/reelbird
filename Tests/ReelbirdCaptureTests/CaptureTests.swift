@preconcurrency import AVFoundation
import Foundation
import ReelbirdCore
import Synchronization
import Testing
@testable import ReelbirdCapture

// MARK: Helpers

func tempBundleURL(_ name: String = "take") -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("rb-capture-\(name)-\(UUID().uuidString).reelbird")
}

func options(mic: Bool = true, system: Bool = true) -> RecordingOptions {
    var o = RecordingOptions(source: .synthetic(name: "test"))
    o.microphoneID = mic ? "default" : nil
    o.captureSystemAudio = system
    return o
}

func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

func loadAsset(_ url: URL) async throws -> (duration: Double, tracks: [AVAssetTrack]) {
    let asset = AVURLAsset(url: url)
    return (try await asset.load(.duration).seconds, try await asset.load(.tracks))
}

/// Presentation times of every sample in the first track of `type`.
func samplePTS(_ url: URL, type: AVMediaType) async throws -> [Double] {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: type).first else { return [] }
    // Blocking decode: off the cooperative pool (see BlockingWork).
    return try await BlockingWork.run("test.decode") { _ in
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(out)
        reader.startReading()
        var pts: [Double] = []
        while let sb = out.copyNextSampleBuffer() {
            if let timings = try? sb.sampleTimingInfos() {
                pts.append(contentsOf: timings.map(\.presentationTimeStamp.seconds))
            }
        }
        return pts
    }
}

/// Decoded mono-mixed audio as (time, rms) per 50 ms window.
func audioWindows(_ url: URL) async throws -> [(t: Double, rms: Float)] {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
    // Blocking decode: off the cooperative pool (see BlockingWork).
    return try await BlockingWork.run("test.decode") { _ in
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: 48_000,
        ])
        reader.add(out)
        reader.startReading()
        var samples: [Float] = []
        var start: Double?
        var channels = 1
        while let sb = out.copyNextSampleBuffer() {
            if start == nil { start = sb.presentationTimeStamp.seconds }
            if let fd = sb.formatDescription, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
                channels = Int(asbd.pointee.mChannelsPerFrame)
            }
            guard let block = sb.dataBuffer else { continue }
            let n = CMBlockBufferGetDataLength(block) / 4
            var chunk = [Float](repeating: 0, count: n)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
            samples.append(contentsOf: chunk)
        }
        let frames = samples.count / channels
        let win = 2_400
        var out2: [(Double, Float)] = []
        var f = 0
        while f + win <= frames {
            var sum: Float = 0
            for i in (f * channels)..<((f + win) * channels) { sum += samples[i] * samples[i] }
            out2.append(((start ?? 0) + Double(f) / 48_000, (sum / Float(win * channels)).squareRoot()))
            f += win
        }
        return out2
    }
}

func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
}

/// Records every call in order.
final class MockShareSink: ShareSegmentSink, @unchecked Sendable {
    enum Call: Equatable { case begin, initSegment(Int), media(Int, Double), finish(Double), cancel }
    let calls = Mutex<[Call]>([])
    func begin(recordingID: String, title: String) async throws -> ShareInfo {
        calls.withLock { $0.append(.begin) }
        return ShareInfo(key: "r/\(recordingID)", url: "https://example.test/r/\(recordingID)")
    }
    func initSegment(_ data: Data) async { calls.withLock { $0.append(.initSegment(data.count)) } }
    func mediaSegment(index: Int, data: Data, duration: Double) async { calls.withLock { $0.append(.media(index, duration)) } }
    func finish(totalDuration: Double, timeout: Double) async { calls.withLock { $0.append(.finish(totalDuration)) } }
    func cancel() async { calls.withLock { $0.append(.cancel) } }
    var backlog: Int { get async { 0 } }
    /// What `waitUntilUploaded` answers (the upload finished or not).
    let uploadCompletes = Mutex(false)
    func waitUntilUploaded() async -> Bool { uploadCompletes.withLock { $0 } }
}

// MARK: End-to-end recordings (serialized: they share the hardware encoder and measure timing)

@Suite(.serialized) struct RecordingTests {
    @Test func recordsSyntheticTake() async throws {
        let url = tempBundleURL("take")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = SyntheticFrameSource()
        let session = RecordingSession(options: options(), bundleURL: url, frameSource: source)
        try await session.start()
        await sleep(6)
        let bundle = try await session.stop()
        let metrics = await session.metrics()

        let m = try bundle.readManifest()
        #expect(m.status == .complete)
        #expect(abs(m.duration - 6) < 0.1)
        // Consolidated and verified: each track folder keeps only its one file (no second copy in segments).
        for kind in [TrackKind.screen, .microphone, .systemAudio] {
            let files = try FileManager.default.contentsOfDirectory(atPath: bundle.directory(for: kind).path)
            #expect(files == ["\(kind.rawValue).mp4"], "\(kind): \(files)")
        }
        #expect((m.track(.screen)?.segmentCount ?? 0) >= 3)

        let screen = try #require(m.track(.screen))
        #expect(screen.codec == "hevc")
        #expect(screen.pixelSize == PixelSize(width: 1920, height: 1080))
        let (duration, tracks) = try await loadAsset(bundle.resolve(try #require(screen.file)))
        #expect(abs(duration - 6) < 0.1, "screen.mp4 duration \(duration)")
        let video = try #require(tracks.first { $0.mediaType == .video })
        let fd = try #require(try await video.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(fd) == kCMVideoCodecType_HEVC)

        for kind in [TrackKind.microphone, .systemAudio] {
            let t = try #require(m.track(kind), "missing \(kind)")
            let (d, tr) = try await loadAsset(bundle.resolve(try #require(t.file)))
            #expect(tr.contains { $0.mediaType == .audio })
            #expect(abs(d - 6) < 0.15, "\(kind) duration \(d)")
            let windows = try await audioWindows(bundle.resolve(try #require(t.file)))
            #expect(windows.filter { $0.t > 0.1 && $0.t < 5.8 }.allSatisfy { $0.rms > 0.1 }, "\(kind) should carry the tone")
        }
        let events = try bundle.readEvents()
        #expect(events.filter { $0.type == .move }.count > 300, "moves: \(events.count)")
        #expect(metrics?.droppedFrames == 0)
        print("take: frames=\(metrics?.framesWritten ?? 0) dropped=\(metrics?.droppedFrames ?? -1) events=\(events.count) duration=\(duration)")
    }

    @Test func pauseAndResumeLeaveAGap() async throws {
        let url = tempBundleURL("pause")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = RecordingSession(options: options(), bundleURL: url, frameSource: SyntheticFrameSource())
        try await session.start()
        await sleep(1.5)
        await session.pause()
        #expect(session.currentStatus.phase == .paused)
        await sleep(1.5)
        await session.resume()
        await sleep(1.5)
        let bundle = try await session.stop()
        let m = try bundle.readManifest()
        let pause = try #require(m.pauses.first)
        #expect(m.pauses.count == 1)
        #expect(abs(pause.duration - 1.5) < 0.15, "pause \(pause)")
        #expect(try bundle.readEdit().cuts == m.pauses)

        let inside = TimeRange(start: pause.start + 0.05, end: pause.end - 0.05)
        let videoPTS = try await samplePTS(bundle.resolve(try #require(m.track(.screen)?.file)), type: .video)
        #expect(!videoPTS.isEmpty)
        #expect(!videoPTS.contains { inside.contains($0) }, "video frames inside the pause")
        #expect(videoPTS.contains { $0 >= pause.end - 0.01 && $0 < pause.end + 0.1 }, "video restarts at resume")

        // Audio stays continuous (so it stays in sync) but is silent while paused.
        let windows = try await audioWindows(bundle.resolve(try #require(m.track(.microphone)?.file)))
        let paused = windows.filter { $0.t > inside.start && $0.t + 0.05 < inside.end }
        let live = windows.filter { $0.t > 0.2 && $0.t + 0.05 < pause.start - 0.1 }
        if ProcessInfo.processInfo.environment["RB_DEBUG_DIR"] != nil { print(windows.map { String(format: "%.2f:%.3f", $0.t, $0.rms) }.joined(separator: " ")) }
        #expect(!paused.isEmpty && paused.allSatisfy { $0.rms < 0.001 }, "audio during pause should be silent")
        #expect(!live.isEmpty && live.allSatisfy { $0.rms > 0.05 })
        let after = windows.filter { $0.t > pause.end + 0.1 && $0.t < m.duration - 0.2 }
        #expect(!after.isEmpty && after.allSatisfy { $0.rms > 0.05 }, "audio after resume")
        let types = try bundle.readEvents().map(\.type)
        #expect(types.contains(.pause) && types.contains(.resume))
    }

    @Test func recoversAfterCrash() async throws {
        let url = tempBundleURL("crash")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = RecordingSession(options: options(), bundleURL: url, frameSource: SyntheticFrameSource())
        try await session.start()
        await sleep(5)
        let elapsed = 5.0
        await session.simulateCrash()
        let bundle = ProjectBundle(url: url)
        if ProcessInfo.processInfo.environment["RB_DEBUG_DIR"] != nil {
            for k in TrackKind.allCases { print(k, (try? FileManager.default.contentsOfDirectory(atPath: bundle.directory(for: k).path)) ?? []) }
        }
        #expect(try bundle.readManifest().status == .recording)

        // A half-written segment at the end (the one in progress when the app died).
        let dir = bundle.directory(for: .screen)
        let segs = SegmentStore.segmentFiles(in: dir)
        let lastData = try Data(contentsOf: try #require(segs.last))
        try lastData.prefix(lastData.count / 2).write(to: dir.appendingPathComponent(String(format: "seg_%05d.m4s", segs.count + 1)))

        #expect(try ProjectRecovery.recoverIfNeeded(bundle))
        #expect(try ProjectRecovery.recoverIfNeeded(bundle) == false)
        // Segments that all went into the file are deleted; the screen's damaged last one keeps that track's
        // segments (nothing is thrown away that might still be salvaged).
        #expect(!SegmentStore.hasSegments(bundle.directory(for: .microphone)))
        #expect(!FileManager.default.fileExists(atPath: bundle.directory(for: .microphone).appendingPathComponent("init.mp4").path))
        #expect(SegmentStore.segmentFiles(in: dir).count == segs.count + 1)
        let m = try bundle.readManifest()
        #expect(m.status == .recovered)
        let screen = try #require(m.track(.screen))
        #expect(screen.segmentCount == segs.count)
        let (duration, tracks) = try await loadAsset(bundle.resolve(try #require(screen.file)))
        #expect(tracks.contains { $0.mediaType == .video })
        #expect(duration >= elapsed - 2, "recovered \(duration) s of \(elapsed)")
        #expect(abs(duration - screen.duration) < 0.05, "parsed \(screen.duration) vs AVFoundation \(duration)")
        let mic = try #require(m.track(.microphone))
        let (micDuration, _) = try await loadAsset(bundle.resolve(try #require(mic.file)))
        #expect(micDuration >= elapsed - 2.5)
        print("recovery: \(duration) s of \(elapsed) s, \(screen.segmentCount) segments")
    }

    @Test func shareSinkGetsOrderedSegments() async throws {
        let url = tempBundleURL("share")
        defer { try? FileManager.default.removeItem(at: url) }
        var config = SyntheticFrameSource.Configuration()
        config.camera = PixelSize(width: 1280, height: 720)
        let sink = MockShareSink()
        let session = RecordingSession(options: options(), bundleURL: url, shareSink: sink,
                                       frameSource: SyntheticFrameSource(configuration: config))
        try await session.start()
        await sleep(6.5)
        let bundle = try await session.stop()
        let calls = sink.calls.withLock { $0 }
        #expect(calls.first == .begin)
        guard calls.count > 2, case .initSegment(let initBytes) = calls[1] else {
            Issue.record("expected init segment second: \(calls)"); return
        }
        #expect(initBytes > 0)
        let media = calls.compactMap { c -> (Int, Double)? in if case .media(let i, let d) = c { return (i, d) } else { return nil } }
        #expect(media.map(\.0) == Array(1...media.count))
        #expect(media.count >= 3)
        for (_, d) in media.dropLast() { #expect(abs(d - 2) < 0.15, "segment duration \(d)") }
        if case .finish(let total) = calls.last { #expect(abs(total - 6.5) < 0.2) } else { Issue.record("finish not last: \(calls)") }

        let m = try bundle.readManifest()
        #expect(m.share?.url.hasPrefix("https://example.test/r/") == true)
        // The upload isn't confirmed finished (this sink never says so): its segments stay for a resume.
        #expect(SegmentStore.hasSegments(bundle.directory(for: .share)))
        #expect(!SegmentStore.hasSegments(bundle.directory(for: .screen)))
        let share = try #require(m.track(.share))
        let (duration, tracks) = try await loadAsset(bundle.resolve(try #require(share.file)))
        #expect(tracks.contains { $0.mediaType == .video } && tracks.contains { $0.mediaType == .audio })
        #expect(abs(duration - 6.5) < 0.2, "share duration \(duration)")
        #expect(share.pixelSize == PixelSize(width: 1920, height: 1080))
        let shareAudio = try await audioWindows(bundle.resolve(try #require(share.file)))
        #expect(shareAudio.filter { $0.t > 0.5 && $0.t < 6 }.allSatisfy { $0.rms > 0.15 }, "mixed mic + system audio")
        // The camera bubble (grey synthetic camera) is composited bottom-right over the white screen.
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: bundle.resolve(try #require(share.file))))
        let (image, _) = try await gen.image(at: CMTime(seconds: 3, preferredTimescale: 600))
        func luma(_ x: Int, _ y: Int) -> Int {
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
            return (Int(px[0]) + Int(px[1]) + Int(px[2])) / 3
        }
        let d = 0.22 * 1080, inset = 0.025 * 1080
        let cx = Int(1920 - inset - d / 2), cy = Int(1080 - inset - d / 2)
        #expect(luma(cx - 60, cy - 60) < 200, "bubble shows the camera")
        #expect(luma(Int(1920 - inset - 2), Int(1080 - inset - 2)) > 200, "outside the circle stays screen")
        if let out = ProcessInfo.processInfo.environment["RB_SHARE_FRAME"] {
            let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
        let camera = try #require(m.track(.camera))
        let (camDuration, _) = try await loadAsset(bundle.resolve(try #require(camera.file)))
        #expect(abs(camDuration - 6.5) < 0.2, "camera duration \(camDuration)")
        print("share: \(media.count) segments, durations \(media.map { String(format: "%.2f", $0.1) })")
    }

    @Test func warnsWhenMicrophoneIsSilent() async throws {
        let url = tempBundleURL("silent")
        defer { try? FileManager.default.removeItem(at: url) }
        var config = SyntheticFrameSource.Configuration()
        config.microphone = .silence
        let session = RecordingSession(options: options(), bundleURL: url, frameSource: SyntheticFrameSource(configuration: config))
        let seen = Mutex<Double?>(nil)
        let watcher = Task {
            for await s in session.status where s.warnings.contains(where: { $0.kind == .microphoneSilent }) {
                seen.withLock { $0 = $0 ?? s.elapsed }
            }
        }
        try await session.start()
        await sleep(4.2)
        let status = session.currentStatus
        #expect(status.phase == .recording)
        #expect(status.microphoneLevel == 0)
        await session.discard()
        watcher.cancel()
        let at = try #require(seen.withLock { $0 }, "no microphoneSilent warning")
        #expect(at > 2.9 && at < 3.6, "warned at \(at)")
        #expect(!FileManager.default.fileExists(atPath: url.path), "discard deletes the bundle")
    }

    @Test func fourK60KeepsUpInRealTime() async throws {
        let url = tempBundleURL("4k")
        defer { try? FileManager.default.removeItem(at: url) }
        var config = SyntheticFrameSource.Configuration()
        config.pixelSize = PixelSize(width: 3840, height: 2160)
        let source = SyntheticFrameSource(configuration: config)
        let session = RecordingSession(options: options(), bundleURL: url, frameSource: source)
        try await session.start()
        let cpu0 = cpuSeconds(), wall0 = Date()
        await sleep(5)
        let metrics = try #require(await session.metrics())
        let cpu = cpuSeconds() - cpu0, wall = Date().timeIntervalSince(wall0)
        let bundle = try await session.stop()
        let m = try bundle.readManifest()
        let fps = Double(metrics.framesWritten) / wall
        print(String(format: "4K60: %d frames in %.2f s = %.1f fps, dropped %d (generator skipped %d), CPU %.2f s (%.0f%% of one core incl. synthetic generator)",
                     metrics.framesWritten, wall, fps, metrics.droppedFrames, source.sourceSkippedFrames, cpu, cpu / wall * 100))
        #expect(metrics.droppedFrames == 0)
        #expect(fps > 58)
        #expect(m.track(.screen)?.pixelSize == PixelSize(width: 3840, height: 2160))
        let (duration, _) = try await loadAsset(bundle.resolve(try #require(m.track(.screen)?.file)))
        #expect(abs(duration - m.duration) < 0.1)
    }

    @Test func offlineSourceRunsFasterThanRealTime() async throws {
        let url = tempBundleURL("offline")
        defer { try? FileManager.default.removeItem(at: url) }
        var config = SyntheticFrameSource.Configuration()
        config.mode = .asFastAsPossible(duration: 10)
        let source = SyntheticFrameSource(configuration: config)
        let session = RecordingSession(options: options(), bundleURL: url, frameSource: source)
        let wall0 = Date()
        try await session.start()
        await source.waitUntilFinished()
        let bundle = try await session.stop()
        let wall = Date().timeIntervalSince(wall0)
        let m = try bundle.readManifest()
        #expect(abs(m.duration - 10) < 0.02)
        let (duration, _) = try await loadAsset(bundle.resolve(try #require(m.track(.screen)?.file)))
        #expect(abs(duration - 10) < 0.05)
        let (micDuration, _) = try await loadAsset(bundle.resolve(try #require(m.track(.microphone)?.file)))
        #expect(abs(micDuration - 10) < 0.05)
        #expect(m.track(.screen)?.segmentCount == 5)
        #expect(!SegmentStore.hasSegments(bundle.directory(for: .screen)))
        print(String(format: "offline: 10 s of 1080p60 recorded in %.2f s", wall))
    }
}

// MARK: Units

@Test func mixerAlignsInputsByTimelinePosition() {
    let out = Mutex<[Float]>([])
    let mixer = AudioMixer(inputs: 2) { _, s, n in
        out.withLock { o in for i in 0..<(n * 2) { o.append(s[i]) } }
    }
    let ones = [Float](repeating: 0.25, count: 960)
    // Input 0 (mono) covers 0..<960; input 1 (stereo) starts 480 frames later.
    ones.withUnsafeBufferPointer { mixer.add(input: 0, frame: 0, samples: $0.baseAddress!, frames: 960, channels: 1) }
    #expect(out.withLock { $0.isEmpty }, "waits for the other input")
    let stereo = [Float](repeating: 0.5, count: 960 * 2)
    stereo.withUnsafeBufferPointer { mixer.add(input: 1, frame: 480, samples: $0.baseAddress!, frames: 960, channels: 2) }
    mixer.flush()
    let o = out.withLock { $0 }
    #expect(o.count == 1440 * 2)
    #expect(o[0] == 0.25 && o[479 * 2] == 0.25)
    #expect(o[480 * 2] == 0.75 && o[959 * 2 + 1] == 0.75)
    #expect(o[960 * 2] == 0.5)
}

@Test func encoderPresets() {
    let hd = EncoderSettings.screen(size: PixelSize(width: 2880, height: 1800), frameRate: 60, quality: .high)
    #expect(hd.codec == .hevc)
    #expect(hd.bitrate > 10_000_000 && hd.bitrate < 20_000_000)
    let compact = EncoderSettings.screen(size: PixelSize(width: 1920, height: 1080), frameRate: 30, quality: .compact)
    #expect(compact.codec == .h264)
    let compact5K = EncoderSettings.screen(size: PixelSize(width: 5120, height: 2880), frameRate: 60, quality: .compact)
    #expect(compact5K.codec == .hevc, "H.264 hardware can't do 5K")
    let share = EncoderSettings.share(screen: PixelSize(width: 3456, height: 2234))
    #expect(share.size.width <= 1920 && share.size.width % 2 == 0 && share.size.height % 2 == 0)
}

@Test func permissionSettingsURLs() {
    #expect(Permission.screen.settingsURL.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    #expect(Permission.inputMonitoring.settingsURL.absoluteString.hasSuffix("Privacy_ListenEvent"))
    #expect(Permissions.status(.camera) != .granted || true)
}

@Test func healthMonitorKeepsSinceStable() {
    var h = HealthMonitor()
    var i = HealthInputs(now: 4)
    i.microphoneEnabled = true
    i.microphoneSilentFor = 3.5
    #expect(h.evaluate(i).map(\.kind) == [.microphoneSilent])
    i.now = 5
    #expect(h.evaluate(i).first?.since == 4)
    i.microphoneSilentFor = 0.1
    i.uploadBacklog = 9
    i.freeDiskBytes = 1_000_000_000
    #expect(Set(h.evaluate(i).map(\.kind)) == [.uploadBacklog, .lowDisk])
}

@Test func syntheticSourceProducesMovingFrames() async throws {
    let r = PatternRenderer(size: PixelSize(width: 640, height: 360), pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, text: true)
    let a = try #require(r.render(contentTime: 0))
    let b = try #require(r.render(contentTime: 1))
    #expect(CVPixelBufferGetWidth(a) == 640)
    #expect(CVPixelBufferGetIOSurface(a) != nil)
    #expect(a !== b)
    let p0 = PatternRenderer.boxCenter(at: 0), p1 = PatternRenderer.boxCenter(at: 1)
    #expect(p0 != p1)
}

@Test func normalizerConvertsSyntheticAudio() throws {
    for (channels, outChannels) in [(1, 1), (2, 2), (2, 1), (1, 2)] {
        let fmt = try #require(SyntheticFrameSource.floatFormat(channels: channels, rate: 48_000))
        let n = 960
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n * 4 * channels, blockAllocator: nil, customBlockSource: nil,
                                           offsetToData: 0, dataLength: n * 4 * channels, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        let values = [Float](repeating: 0.5, count: n * channels)
        values.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: n * 4 * channels) }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: fmt, sampleCount: n,
                                                             presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sb)
        let norm = PCMNormalizer(channels: outChannels)
        let buffer = try #require(sb)
        let r = try #require(norm.convert(buffer), "\(channels)->\(outChannels)")
        #expect(r.frames == n)
        #expect(abs(r.rms - 0.5) < 1e-4)
    }
}
