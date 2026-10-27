@preconcurrency import AVFoundation
import AppKit
import Foundation
import Testing
import ReelbirdCore
@testable import ReelbirdRender

/// A clapperboard recording: the screen flashes white for two frames at each of `flashes` (else near black) and
/// the microphone and system audio play a short 1 kHz burst from the same instants.
private func clapper(seconds: Double, flashes: [Double], fps: Int = 30) async throws -> ProjectBundle {
    let dir = testTemporaryDirectory.appendingPathComponent("rb-speed-\(UUID().uuidString).reelbird")
    let bundle = try ProjectBundle.create(at: dir)
    let fm = FileManager.default
    for k in [TrackKind.screen, .microphone, .systemAudio] { try fm.createDirectory(at: bundle.directory(for: k), withIntermediateDirectories: true) }
    let frames = Set(flashes.flatMap { t -> [Int] in let n = Int((t * Double(fps)).rounded()); return [n, n + 1] })
    try await Synthetic.writeVideo(url: bundle.directory(for: .screen).appendingPathComponent("screen.mp4"), width: 640, height: 360,
                                   fps: fps, seconds: seconds, codec: .h264) { y, ys, uv, uvs, w, h, n in
        let luma: Int32 = frames.contains(n) ? 235 : 20
        for r in 0..<h { memset(y + r * ys, luma, w) }
        for r in 0..<(h / 2) { memset(uv + r * uvs, 128, w) }
    }
    var pcm = [Float](repeating: 0, count: Int(seconds * 48_000))
    for t in flashes {
        let s = Int((t * Double(fps)).rounded() / Double(fps) * 48_000)
        for k in 0..<2400 where s + k < pcm.count { pcm[s + k] = 0.7 * Float(sin(2 * Double.pi * 1000 * Double(k) / 48_000)) }
    }
    try await DemoFixture.writePCM(url: bundle.directory(for: .microphone).appendingPathComponent("microphone.m4a"), samples: pcm)
    try await DemoFixture.writePCM(url: bundle.directory(for: .systemAudio).appendingPathComponent("systemAudio.m4a"), samples: pcm)
    let tracks = [
        TrackInfo(kind: .screen, directory: "screen", file: "screen/screen.mp4", codec: "h264", pixelSize: PixelSize(width: 640, height: 360), duration: seconds),
        TrackInfo(kind: .microphone, directory: "microphone", file: "microphone/microphone.m4a", codec: "aac", sampleRate: 48_000, channels: 1, duration: seconds),
        TrackInfo(kind: .systemAudio, directory: "systemAudio", file: "systemAudio/systemAudio.m4a", codec: "aac", sampleRate: 48_000, channels: 1, duration: seconds),
    ]
    let manifest = ProjectManifest(title: "Speed", appVersion: "test", status: .complete,
                                   capture: CaptureInfo(source: .synthetic(name: "speed"), pixelSize: PixelSize(width: 640, height: 360), scale: 1, frameRate: fps),
                                   clock: ClockInfo(originHostTime: 0), tracks: tracks, duration: seconds)
    try bundle.writeManifest(manifest)
    return bundle
}

private func flat(_ manifest: ProjectManifest) -> EditDocument {
    var e = EditDocument.initial(for: manifest)
    e.background.kind = .solid
    e.background.colors = [RGBA(hex: "#808080")!]
    e.background.shadow = 0
    e.background.motionBlur = false
    e.zoom.mode = .off
    e.cursor.visible = false
    e.audio.enhance = false
    e.audio.autoLevel = false
    e.audio.duckSystemAudio = false
    e.audio.systemMuted = true
    return e
}

private func flashOnsets(_ url: URL) async throws -> [Double] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    // Blocking decode: off the cooperative pool (see BlockingWork).
    return try await BlockingWork.run("test.decode") { _ in
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out)
        reader.startReading()
        var times: [Double] = []
        var was = false
        while let sb = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            let o = (CVPixelBufferGetHeight(pb) / 2) * CVPixelBufferGetBytesPerRow(pb) + (CVPixelBufferGetWidth(pb) / 2) * 4
            let bright = base[o + 1] > 128
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            if bright, !was { times.append(CMSampleBufferGetPresentationTimeStamp(sb).seconds) }
            was = bright
        }
        return times
    }
}

/// Decoded mono audio of a file and the time of its first sample.
private func decodeAudio(_ url: URL) async throws -> (samples: [Float], start: Double) {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    // Blocking decode: off the cooperative pool (see BlockingWork).
    return try await BlockingWork.run("test.decode") { _ in
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(out)
        reader.startReading()
        var samples: [Float] = []
        var start: Double?
        while let sb = out.copyNextSampleBuffer() {
            if start == nil { start = CMSampleBufferGetPresentationTimeStamp(sb).seconds }
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let n = CMBlockBufferGetDataLength(bb) / 4
            var chunk = [Float](repeating: 0, count: n)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
            samples += chunk
        }
        return (samples, start ?? 0)
    }
}

private func clickOnsets(_ a: (samples: [Float], start: Double), threshold: Float = 0.2) -> [Double] {
    var times: [Double] = []
    var last = -1.0
    for (i, v) in a.samples.enumerated() where abs(v) > threshold {
        let t = a.start + Double(i) / 48_000
        if t - last > 0.15 { times.append(t) }
        last = t
    }
    return times
}

/// Peak level in an output time window.
private func peak(_ a: (samples: [Float], start: Double), _ r: TimeRange) -> Float {
    let i0 = max(0, Int((r.start - a.start) * 48_000)), i1 = min(a.samples.count, Int((r.end - a.start) * 48_000))
    guard i1 > i0 else { return 0 }
    return a.samples[i0..<i1].map(abs).max() ?? 0
}

@Test func exportAtMixedSpeedsKeepsLengthAndSync() async throws {
    let flashes = [0.5, 1.7, 2.9, 4.1, 5.3]
    let bundle = try await clapper(seconds: 6, flashes: flashes)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    var edit = flat(manifest)
    edit.cuts = [TimeRange(start: 0.9, end: 1.1)]
    edit.speed = SpeedSettings(segments: [
        SpeedSegment(range: TimeRange(start: 1.4, end: 2.05), rate: 0.5),
        SpeedSegment(range: TimeRange(start: 2.6, end: 3.43), rate: 2),
        SpeedSegment(range: TimeRange(start: 3.8, end: 4.62), rate: 4),
    ], keepFastAudio: true)
    let timeline = EditTimeline(manifest: manifest, edit: edit)
    let expected = flashes.compactMap { timeline.outputTime(forSource: ($0 * 30).rounded() / 30) }
    #expect(expected.count == 5)

    let dest = testTemporaryDirectory.appendingPathComponent("rb-speed-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: dest) }
    _ = try await Exporter.export(bundle: bundle, edit: edit, options: ExportOptions(format: .mp4H264, frameRate: 30, destination: dest)) { _ in }
    let info = try await inspect(dest)
    let asset = AVURLAsset(url: dest)
    let vDur = try await asset.loadTracks(withMediaType: .video).first!.load(.timeRange).duration.seconds
    let aDur = try await asset.loadTracks(withMediaType: .audio).first!.load(.timeRange).duration.seconds
    print("SPEED DURATION file \(info.duration) video \(vDur) audio \(aDur) timeline \(timeline.duration)")
    #expect(abs(info.duration - timeline.duration) < 0.06, "duration \(info.duration), timeline \(timeline.duration)")
    // The sound ends with the picture, to the audio frame: the stretcher's tail never overhangs.
    #expect(abs(aDur - vDur) <= 1024.0 / 48_000, "audio \(aDur), video \(vDur)")
    #expect(abs(info.duration - vDur) < 1e-3, "file \(info.duration), video \(vDur)")
    let video = try await flashOnsets(dest)
    let audio = clickOnsets(try await decodeAudio(dest))
    print("SPEED SYNC flashes \(video.map { String(format: "%.3f", $0) }), clicks \(audio.map { String(format: "%.3f", $0) }), expected \(expected.map { String(format: "%.3f", $0) })")
    #expect(video.count == expected.count)
    #expect(audio.count == expected.count)
    let frame = 1.0 / 30
    for (v, e) in zip(video, expected) { #expect(abs(v - e) <= frame + 1e-3, "flash at \(v), expected \(e)") }
    // Stretched sound starts within a frame (plus the stretcher's ~15 ms) of the picture, and within 15 ms of its
    // exact output time (the picture is frame-quantised; the sound isn't).
    for (v, a) in zip(video, audio) { #expect(abs(v - a) <= frame + 0.02, "flash at \(v), burst at \(a)") }
    for (a, e) in zip(audio, expected) { #expect(abs(a - e) <= 0.015, "burst at \(a), expected \(e)") }
}

/// A fast stretch at the very end leaves the sound tracks short of the picture; the export still ends both together.
@Test func exportEndingInSilentSpeedKeepsAudioAsLongAsVideo() async throws {
    let bundle = try await clapper(seconds: 3, flashes: [0.5, 1.5])
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    var edit = flat(manifest)
    edit.speed.set(TimeRange(start: 2, end: 3), rate: 4)
    let timeline = EditTimeline(manifest: manifest, edit: edit)
    #expect(timeline.pieces.last?.audible == false)
    let dest = testTemporaryDirectory.appendingPathComponent("rb-speed-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: dest) }
    _ = try await Exporter.export(bundle: bundle, edit: edit, options: ExportOptions(format: .mp4H264, frameRate: 30, destination: dest)) { _ in }
    let asset = AVURLAsset(url: dest)
    let vDur = try await asset.loadTracks(withMediaType: .video).first!.load(.timeRange).duration.seconds
    let aDur = try await asset.loadTracks(withMediaType: .audio).first!.load(.timeRange).duration.seconds
    #expect(abs(vDur - (timeline.duration * 30).rounded(.down) / 30) < 1e-3, "video \(vDur), timeline \(timeline.duration)")
    #expect(abs(aDur - vDur) <= 1024.0 / 48_000, "audio \(aDur), video \(vDur)")
}

@Test func soundOver2xIsSilentByDefaultAndFades() async throws {
    let bundle = try await clapper(seconds: 4, flashes: [0.5, 2.0, 3.5])
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    var edit = flat(manifest)
    edit.speed.set(TimeRange(start: 1.5, end: 2.5), rate: 4)
    let timeline = EditTimeline(manifest: manifest, edit: edit)
    #expect(timeline.pieces.map(\.audible) == [true, false, true])
    let dest = testTemporaryDirectory.appendingPathComponent("rb-speed-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: dest) }
    _ = try await Exporter.export(bundle: bundle, edit: edit, options: ExportOptions(format: .mp4H264, frameRate: 30, destination: dest)) { _ in }
    let info = try await inspect(dest)
    #expect(abs(info.duration - 3.25) < 0.06, "duration \(info.duration)")
    let a = try await decodeAudio(dest)
    let fast = timeline.pieces[1].output
    #expect(peak(a, TimeRange(start: fast.start + 0.02, end: fast.end - 0.02)) < 0.002, "silent while fast")
    let onsets = clickOnsets(a)
    #expect(onsets.count == 2, "clicks \(onsets)")
    // The 3.5 s click lands at its output time after the fast stretch: the audio track kept its place.
    if let last = onsets.last, let want = timeline.outputTime(forSource: 3.5) { #expect(abs(last - want) < 0.04, "click \(last), want \(want)") }
    #expect(a.samples.count >= Int((timeline.duration - 0.1) * 48_000), "audio runs to the end")
}

@Test func compositionPlacesPiecesOnTheOutputTimeline() async throws {
    var o = Synthetic.Options()
    o.seconds = 4
    let bundle = try await Synthetic.makeBundle(o)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    let sources = try await MediaSources.load(bundle: bundle, manifest: manifest)
    var speed = SpeedSettings(segments: [SpeedSegment(range: TimeRange(start: 1, end: 2), rate: 2),
                                         SpeedSegment(range: TimeRange(start: 2.5, end: 3), rate: 0.5)])
    let timeline = EditTimeline(duration: 4, trim: nil, cuts: [TimeRange(start: 3.5, end: 3.7)], speed: speed)
    let comp = try sources.composition(timeline: timeline, camera: false, audio: AudioSettings())
    let screenEnd = try #require(comp.screen).timeRange.end.seconds
    let audioEnd = try #require(comp.audio.first).track.timeRange.end.seconds
    #expect(abs(screenEnd - timeline.duration) < 0.002, "screen \(screenEnd) vs \(timeline.duration)")
    #expect(abs(audioEnd - timeline.duration) < 0.002, "audio \(audioEnd) vs \(timeline.duration)")
    // The cut's join gets a near-zero silence, so the sound dips over a few ms there instead of clicking.
    let join = try #require(timeline.joins.first)
    #expect(timeline.joins.count == 1)
    #expect(comp.silent.count == 1 && abs(comp.silent[0].start - join) < 0.001 && comp.silent[0].duration < 0.002, "\(comp.silent)")
    #expect(AudioTrackProcessor.silenceRanges(comp.silent).count == 1)
    // Too fast: the sound of that piece is left out, the picture isn't.
    speed.set(TimeRange(start: 1, end: 2), rate: 8)
    let fast = EditTimeline(duration: 4, trim: nil, cuts: [], speed: speed)
    let c2 = try sources.composition(timeline: fast, camera: false, audio: AudioSettings())
    #expect(c2.silent == [TimeRange(start: 1, end: 1.125)])
    let segs = try #require(c2.audio.first?.track.segments)
    #expect(segs.contains { $0.isEmpty && abs($0.timeMapping.target.start.seconds - 1) < 0.001 })
    #expect(abs(try #require(c2.screen).timeRange.end.seconds - fast.duration) < 0.002)
}

/// The system audio's duck automation runs on the output timeline, sped-up pieces included: the tap's clock is
/// the composition's.
@Test func duckingFollowsTheSpedUpTimeline() async throws {
    var o = Synthetic.Options()
    o.seconds = 4
    let bundle = try await Synthetic.makeBundle(o)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    let sources = try await MediaSources.load(bundle: bundle, manifest: manifest)
    let speed = SpeedSettings(segments: [SpeedSegment(range: TimeRange(start: 0.5, end: 2.5), rate: 2)])
    let timeline = EditTimeline(duration: 4, trim: nil, cuts: [], speed: speed)
    // Speech from 2.6 to 3.2 s of the recording: 1.6–2.2 s of output.
    let curve = DuckCurve(recordingRanges: [TimeRange(start: 2.6, end: 3.2)], timeline: timeline)
    #expect(curve.ranges == [TimeRange(start: 1.6, end: 2.2)])
    var settings = AudioSettings()
    settings.autoLevel = false
    let comp = try sources.composition(timeline: timeline, camera: false, audio: settings)
    let track = try #require(comp.audio.first).track
    let m = AudioTrackProcessor.mix([AudioTrackProcessor.Lane(kind: .systemAudio, track: track, gain: 1)], forPlayback: false)
    m.processors[0].duck = curve
    // Blocking decode: off the cooperative pool (see BlockingWork).
    let inputs = Unchecked((comp.asset, track, m.mix))
    let samples: [Float] = try await BlockingWork.run("test.decode") { _ in
        let (asset, track, mix) = inputs.value
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        out.audioMix = mix
        out.audioTimePitchAlgorithm = MediaSources.timePitch
        reader.add(out)
        reader.startReading()
        var samples: [Float] = []
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let n = CMBlockBufferGetDataLength(bb) / 4
            var chunk = [Float](repeating: 0, count: n)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
            samples += chunk
        }
        return samples
    }
    let a = (samples: samples, start: 0.0)
    let ducked = peak(a, TimeRange(start: 1.75, end: 2.05)), open = peak(a, TimeRange(start: 1.0, end: 1.4))
    let after = peak(a, TimeRange(start: 3.0, end: 3.2))
    print("SPEED DUCK ducked \(ducked) open \(open) after \(after)")
    #expect(ducked < open * 0.4, "ducked \(ducked) vs open \(open)")
    #expect(after > open * 0.8)
    withExtendedLifetime(m) {}
}

@MainActor
@Test func previewPlaysTheSpeedEdit() async throws {
    var o = Synthetic.Options()
    o.seconds = 3
    let bundle = try await Synthetic.makeBundle(o)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let player = try PreviewPlayer(bundle: bundle)
    var ready = false
    player.onReady = { _ in ready = true }
    let start = Date()
    while !ready, Date().timeIntervalSince(start) < 5 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(ready)
    var edit = try bundle.readEdit()
    player.seek(to: 2.5)
    edit.speed.set(TimeRange(start: 0, end: 2), rate: 4)
    player.update(edit: edit)
    #expect(abs(player.duration - 1.5) < 1e-9)
    // The playhead stays on the same recording moment (2.5 s → output 1.0 s).
    #expect(abs(player.currentTime - 1.0) < 1e-6)
    let item = try #require(player.currentItemForTesting)
    #expect(item.audioTimePitchAlgorithm == MediaSources.timePitch)
    let d = try await item.asset.load(.duration).seconds
    #expect(abs(d - 1.5) < 0.01, "item duration \(d)")
    // Turning on "keep sound" re-plans: the fast piece becomes audible.
    edit.speed.keepFastAudio = true
    player.update(edit: edit)
    #expect(player.plan.timeline.pieces.allSatisfy { $0.audible })
}
