@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import ReelbirdCore

/// The recording's media files, loaded once. Builds `AVMutableComposition`s that already apply trim and
/// cuts, so readers and players see the edited (output) timeline directly.
final class MediaSources: @unchecked Sendable {
    struct Track {
        let kind: TrackKind
        let asset: AVURLAsset
        let track: AVAssetTrack
        /// Media range in the file.
        let fileRange: CMTimeRange
        /// Where the file's first sample sits on the recording timeline.
        let startTime: Double
    }

    let screen: Track?
    let camera: Track?
    let audio: [Track]

    private init(screen: Track?, camera: Track?, audio: [Track]) {
        self.screen = screen; self.camera = camera; self.audio = audio
    }

    static func load(bundle: ProjectBundle, manifest: ProjectManifest) async throws -> MediaSources {
        func load(_ kind: TrackKind, _ type: AVMediaType) async throws -> Track? {
            guard let info = manifest.track(kind), let url = bundle.mediaURL(for: kind, in: manifest),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            do {
                guard let t = try await asset.loadTracks(withMediaType: type).first else { return nil }
                let range = try await t.load(.timeRange)
                guard range.duration.seconds > 0 else { return nil }
                return Track(kind: kind, asset: asset, track: t, fileRange: range, startTime: info.startTime)
            } catch {
                throw RenderError.unreadableMedia("\(kind.rawValue): \(error.localizedDescription)")
            }
        }
        let screen = try await load(.screen, .video)
        let camera = try await load(.camera, .video)
        var audio: [Track] = []
        for k in [TrackKind.microphone, .systemAudio] { if let t = try await load(k, .audio) { audio.append(t) } }
        return MediaSources(screen: screen, camera: camera, audio: audio)
    }

    struct Composition: @unchecked Sendable {
        let asset: AVMutableComposition
        let screen: AVMutableCompositionTrack?
        let camera: AVMutableCompositionTrack?
        /// Audio tracks with their linear gain (mutes already removed).
        let audio: [(kind: TrackKind, track: AVMutableCompositionTrack, gain: Float)]
        let duration: Double

        /// Audio mix with gains normalised to ≤ 1 (AVAudioMix's range). Returns the leftover boost.
        func audioMix() -> (mix: AVAudioMix, boost: Float)? {
            guard !audio.isEmpty else { return nil }
            let peak = max(1, audio.map(\.gain).max() ?? 1)
            let mix = AVMutableAudioMix()
            mix.inputParameters = audio.map { a in
                let p = AVMutableAudioMixInputParameters(track: a.track)
                p.setVolume(a.gain / peak, at: .zero)
                return p
            }
            return (mix, peak)
        }
    }

    static let timescale: CMTimeScale = 90_000
    static func time(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: timescale) }

    /// A composition of the kept ranges, back to back. `video` / `camera` / `audio` choose the tracks.
    func composition(timeline: EditTimeline, video: Bool = true, camera wantCamera: Bool, audio settings: AudioSettings?) throws -> Composition {
        let comp = AVMutableComposition()
        func add(_ src: Track, type: AVMediaType) throws -> AVMutableCompositionTrack? {
            guard let ct = comp.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
            let fileStart = src.fileRange.start.seconds
            let fileDur = src.fileRange.duration.seconds
            var out = 0.0
            var inserted = false
            for r in timeline.kept {
                let a = max(r.start, src.startTime), b = min(r.end, src.startTime + fileDur)
                if b - a > 1e-4 {
                    let at = out + (a - r.start)
                    let end = ct.timeRange.end.seconds.isFinite ? ct.timeRange.end.seconds : 0
                    if at - end > 1e-4 {
                        ct.insertEmptyTimeRange(CMTimeRange(start: Self.time(end), end: Self.time(at)))
                    }
                    let range = CMTimeRange(start: Self.time(fileStart + (a - src.startTime)), duration: Self.time(b - a))
                    do { try ct.insertTimeRange(range, of: src.track, at: Self.time(at)) } catch {
                        throw RenderError.unreadableMedia("\(src.kind.rawValue): \(error.localizedDescription)")
                    }
                    inserted = true
                }
                out += r.duration
            }
            if !inserted { comp.removeTrack(ct); return nil }
            return ct
        }
        let screenTrack = try video ? screen.flatMap { try add($0, type: .video) } : nil
        let cameraTrack = try wantCamera ? camera.flatMap { try add($0, type: .video) } : nil
        var audioTracks: [(TrackKind, AVMutableCompositionTrack, Float)] = []
        if let settings {
            for a in audio {
                let muted = a.kind == .microphone ? settings.microphoneMuted : settings.systemMuted
                let db = a.kind == .microphone ? settings.microphoneGainDB : settings.systemGainDB
                guard !muted, let t = try add(a, type: .audio) else { continue }
                audioTracks.append((a.kind, t, Float(pow(10, min(24, max(-60, db)) / 20))))
            }
        }
        return Composition(asset: comp, screen: screenTrack, camera: cameraTrack,
                           audio: audioTracks.map { (kind: $0.0, track: $0.1, gain: $0.2) }, duration: timeline.duration)
    }

    /// Decoder output settings: NV12 in IOSurface-backed buffers the GPU can read without copying.
    static let decodeSettings: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
    ]
}

/// Walks a video track output and returns, for increasing times, the latest frame at or before each time.
/// Handles variable frame rate (ScreenCaptureKit only delivers changed frames) and frame-rate conversion.
final class FrameStepper {
    private let output: AVAssetReaderTrackOutput
    private(set) var current: CMSampleBuffer?
    private var next: CMSampleBuffer?
    private var finished = false

    init(_ output: AVAssetReaderTrackOutput) { self.output = output }

    private func pull() -> CMSampleBuffer? {
        while !finished {
            guard let sb = output.copyNextSampleBuffer() else { finished = true; return nil }
            if CMSampleBufferGetImageBuffer(sb) != nil { return sb }
        }
        return nil
    }

    /// The frame to show at `t` (output seconds). Before the first frame, the first frame is returned.
    func frame(at t: Double, tolerance: Double) -> CVPixelBuffer? {
        if next == nil, !finished { next = pull() }
        while let n = next, CMSampleBufferGetPresentationTimeStamp(n).seconds <= t + tolerance {
            current = n
            next = pull()
        }
        if let c = current { return CMSampleBufferGetImageBuffer(c) }
        return next.flatMap(CMSampleBufferGetImageBuffer)
    }
}
