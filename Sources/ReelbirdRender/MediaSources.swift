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
        /// HDR or wide-gamut video (PQ, HLG, linear; BT.2020 or P3 primaries) that must be converted to SDR
        /// sRGB on decode. Screen captures are sRGB; this covers camera feeds and imported clips.
        var needsColorConversion = false
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
                let (range, formats) = try await t.load(.timeRange, .formatDescriptions)
                guard range.duration.seconds > 0 else { return nil }
                var track = Track(kind: kind, asset: asset, track: t, fileRange: range, startTime: info.startTime)
                if type == .video { track.needsColorConversion = formats.contains(where: Self.isWideOrHDR) }
                return track
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

    /// The colour space everything is composited in: BT.709 primaries and matrix, sRGB transfer.
    static let sdrColorProperties: [String: String] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: kCVImageBufferTransferFunction_sRGB as String,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]

    /// Decode settings for a track: HDR and wide-gamut video is tone-mapped to SDR sRGB by VideoToolbox
    /// (measured: PQ greys land within 2 code values of their SDR encoding up to diffuse white); SDR video
    /// decodes untouched, since screen captures already hold sRGB values.
    func decodeSettings(for kind: TrackKind) -> [String: any Sendable] {
        let t = kind == .camera ? camera : screen
        guard t?.needsColorConversion == true else { return Self.decodeSettings }
        var s = Self.decodeSettings
        s[AVVideoColorPropertiesKey] = Self.sdrColorProperties
        return s
    }

    /// For preview: an item video composition that tone-maps HDR/wide-gamut video to the SDR space export
    /// uses, so preview and export match. `nil` when the track needs nothing.
    func applySDRConversion(kind: TrackKind, to item: AVPlayerItem, asset: AVAsset) {
        let t = kind == .camera ? camera : screen
        guard t?.needsColorConversion == true else { return }
        let props = Self.sdrColorProperties
        AVMutableVideoComposition.videoComposition(withPropertiesOf: asset) { vc, _ in
            guard let vc else { return }
            vc.colorPrimaries = props[AVVideoColorPrimariesKey]
            vc.colorTransferFunction = props[AVVideoTransferFunctionKey]
            vc.colorYCbCrMatrix = props[AVVideoYCbCrMatrixKey]
            let box = Unchecked((item, vc))
            DispatchQueue.main.async { box.value.0.videoComposition = box.value.1 }
        }
    }

    static func isWideOrHDR(_ fd: CMFormatDescription) -> Bool {
        let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
        let transfer = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        let primaries = ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
        let hdrTransfers = [kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG,
                            kCMFormatDescriptionTransferFunction_Linear].map { $0 as String }
        let widePrimaries = [kCMFormatDescriptionColorPrimaries_ITU_R_2020, kCMFormatDescriptionColorPrimaries_P3_D65,
                             kCMFormatDescriptionColorPrimaries_DCI_P3].map { $0 as String }
        return transfer.map(hdrTransfers.contains) == true || primaries.map(widePrimaries.contains) == true
    }
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
