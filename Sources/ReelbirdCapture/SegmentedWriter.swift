import AVFoundation
import Foundation
import ReelbirdCore
import Synchronization
import UniformTypeIdentifiers

/// A segment produced by a writer, after it has been written to disk.
struct SegmentOutput: Sendable {
    enum Kind: Sendable { case initialization, media }
    var kind: Kind
    /// 1-based for media segments, 0 for the init segment.
    var index: Int
    var data: Data
    /// Seconds (0 for the init segment).
    var duration: Double
}

/// One `AVAssetWriter` producing fMP4 segments (`init.mp4` + `seg_NNNNN.m4s` + `index.m3u8`) into a
/// track directory as they are produced. A crash loses at most the segment in progress.
///
/// Media time in the segments starts at `startTime` on the recording timeline (the writer's session
/// start); readers of the consolidated file see it starting at 0.
final class SegmentedWriter: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    enum AppendResult { case appended, notReady, closed }

    let kind: TrackKind
    let directory: URL
    let video: VideoSpec?
    let audio: AudioSpec?
    let realTime: Bool
    let segmentInterval: Double

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let audioInput: AVAssetWriterInput?
    private let onSegment: (@Sendable (SegmentOutput) -> Void)?

    private struct State {
        var started = false
        var closed = false
        var startTime: Double = 0
        var lastVideoTime: Double = -.infinity
        var lastSampleEnd: Double = 0
        var sampleCount = 0
        var segments: [(name: String, duration: Double)] = []
        var writeError: String?
    }
    private let state = Mutex(State())
    /// Serializes appends with `finish`/`abandon` so nothing is appended after inputs are marked finished.
    private let appendLock = NSLock()

    init(kind: TrackKind, directory: URL, video: VideoSpec?, audio: AudioSpec?,
         profile: AVFileTypeProfile = .mpeg4CMAFCompliant, segmentInterval: Double = 2, realTime: Bool = true,
         onSegment: (@Sendable (SegmentOutput) -> Void)? = nil) throws {
        self.kind = kind
        self.directory = directory
        self.video = video
        self.audio = audio
        self.realTime = realTime
        self.segmentInterval = segmentInterval
        self.onSegment = onSegment
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = profile
        writer.preferredOutputSegmentInterval = CMTime(seconds: segmentInterval, preferredTimescale: 600)

        if let video {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: video.outputSettings)
            input.expectsMediaDataInRealTime = realTime
            guard writer.canAdd(input) else { throw CaptureError.encoderUnavailable("\(video.codec.rawValue) \(video.size.width)x\(video.size.height)") }
            writer.add(input)
            videoInput = input
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        } else {
            videoInput = nil
            adaptor = nil
        }
        if let audio {
            let hint = AudioPCM.floatFormat(channels: audio.channels, rate: Double(audio.sampleRate), interleaved: true)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audio.outputSettings, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = realTime
            guard writer.canAdd(input) else { throw CaptureError.encoderUnavailable("AAC \(audio.channels)ch") }
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }
        super.init()
        writer.delegate = self
    }

    /// Starts writing with the session (and the first segment) at `time` on the recording timeline.
    func start(at time: Double) throws {
        writer.initialSegmentStartTime = .seconds(time)
        guard writer.startWriting() else {
            let detail = writer.error?.localizedDescription ?? "unknown error"
            throw video != nil ? CaptureError.encoderUnavailable(detail) : CaptureError.writerFailed(detail)
        }
        writer.startSession(atSourceTime: .seconds(time))
        state.withLock { $0.started = true; $0.startTime = time; $0.lastSampleEnd = time }
    }

    var isStarted: Bool { state.withLock { $0.started } }
    var hasSamples: Bool { state.withLock { $0.sampleCount > 0 } }
    var startTime: Double { state.withLock { $0.startTime } }
    var segmentCount: Int { state.withLock { $0.segments.count } }
    /// End of the last appended sample on the recording timeline.
    var lastSampleEnd: Double { state.withLock { $0.lastSampleEnd } }
    var lastVideoTime: Double { state.withLock { $0.lastVideoTime } }
    var failure: String? {
        if writer.status == .failed { return writer.error?.localizedDescription ?? "writer failed" }
        return state.withLock { $0.writeError }
    }

    /// Appends a frame at `time` (timeline seconds). Frames at or before the previous frame are skipped.
    @discardableResult
    func append(pixelBuffer: CVPixelBuffer, at time: Double) -> AppendResult {
        guard let videoInput, let adaptor else { return .closed }
        appendLock.lock(); defer { appendLock.unlock() }
        let ok = state.withLock { s -> Bool in
            guard s.started, !s.closed, time > s.lastVideoTime + 1e-4 else { return false }
            return true
        }
        guard ok, writer.status == .writing else { return .closed }
        guard waitUntilReady(videoInput) else { return .notReady }
        guard adaptor.append(pixelBuffer, withPresentationTime: .seconds(time)) else { return .closed }
        let frame = 1.0 / Double(video?.frameRate ?? 60)
        state.withLock { $0.lastVideoTime = time; $0.lastSampleEnd = max($0.lastSampleEnd, time + frame); $0.sampleCount += 1 }
        return .appended
    }

    /// Appends an LPCM buffer already retimed onto the recording timeline.
    @discardableResult
    func append(audio sampleBuffer: CMSampleBuffer) -> AppendResult {
        guard let audioInput else { return .closed }
        appendLock.lock(); defer { appendLock.unlock() }
        let ok = state.withLock { $0.started && !$0.closed }
        guard ok, writer.status == .writing else { return .closed }
        // Audio must stay continuous (a dropped buffer would shift everything after it), so wait briefly.
        guard waitUntilReady(audioInput, realTimeWait: 0.05) else { return .notReady }
        guard audioInput.append(sampleBuffer) else { return .closed }
        let end = (sampleBuffer.presentationTimeStamp + sampleBuffer.duration).seconds
        state.withLock { $0.lastSampleEnd = max($0.lastSampleEnd, end); $0.sampleCount += 1 }
        return .appended
    }

    private func waitUntilReady(_ input: AVAssetWriterInput, realTimeWait: Double = 0) -> Bool {
        if input.isReadyForMoreMediaData { return true }
        if realTime && realTimeWait <= 0 { return false }
        // Offline: wait for the encoder instead of dropping (bounded so a stuck encoder can't hang capture).
        let deadline = Date().addingTimeInterval(realTime ? realTimeWait : 5)
        while !input.isReadyForMoreMediaData {
            if writer.status != .writing || Date() > deadline { return false }
            usleep(500)
        }
        return true
    }

    /// Finishes the last segment and closes the playlist. Safe to call more than once.
    func finish(endTime: Double? = nil) async throws {
        guard close() else { return }
        guard hasSamples else {
            // A writer that never received a sample can't finish (AVAssetWriter spins); drop it.
            writer.cancelWriting()
            throw CaptureError.writerFailed("\(kind.rawValue): no media was recorded")
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        if let endTime, video != nil, endTime > startTime { writer.endSession(atSourceTime: .seconds(endTime)) }
        await writer.finishWriting()
        writePlaylist(ended: true)
        if writer.status == .failed {
            throw CaptureError.writerFailed("\(kind.rawValue): \(writer.error?.localizedDescription ?? "unknown")")
        }
    }

    /// Stops without finishing (discard, or a simulated crash). Segments already on disk stay.
    func abandon() {
        if close() { writer.cancelWriting() }
    }

    /// Marks the writer closed once no append is in flight. Returns whether it was open.
    private func close() -> Bool {
        appendLock.withLock {
            state.withLock { s -> Bool in
                defer { s.closed = true }
                return s.started && !s.closed
            }
        }
    }

    // MARK: AVAssetWriterDelegate

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        let output: SegmentOutput
        switch segmentType {
        case .initialization:
            write(segmentData, name: "init.mp4")
            output = SegmentOutput(kind: .initialization, index: 0, data: segmentData, duration: 0)
        case .separable:
            let duration = segmentReport?.trackReports.map(\.duration.seconds).filter(\.isFinite).max() ?? segmentInterval
            let index = state.withLock { $0.segments.count + 1 }
            let name = String(format: "seg_%05d.m4s", index)
            write(segmentData, name: name)
            state.withLock { $0.segments.append((name, duration)) }
            writePlaylist(ended: false)
            output = SegmentOutput(kind: .media, index: index, data: segmentData, duration: duration)
        @unknown default:
            return
        }
        onSegment?(output)
    }

    private func write(_ data: Data, name: String) {
        do {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            state.withLock { $0.writeError = "\(name): \(error.localizedDescription)" }
        }
    }

    private func writePlaylist(ended: Bool) {
        let segments = state.withLock { $0.segments }
        let target = max(Int(segmentInterval.rounded(.up)), Int((segments.map(\.duration).max() ?? 0).rounded(.up)))
        var s = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:0\n"
        s += "#EXT-X-PLAYLIST-TYPE:\(ended ? "VOD" : "EVENT")\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-MAP:URI=\"init.mp4\"\n"
        for seg in segments { s += String(format: "#EXTINF:%.5f,\n", seg.duration) + seg.name + "\n" }
        if ended { s += "#EXT-X-ENDLIST\n" }
        try? Data(s.utf8).write(to: directory.appendingPathComponent("index.m3u8"), options: .atomic)
    }
}
