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
    /// The voice (`.microphone`: the voice stem when in use, else the raw track) and system audio.
    let audio: [Track]
    /// The raw microphone when `audio` carries the voice stem instead (preview's "Hear original").
    let originalVoice: Track?
    /// Bundle-relative file playing as the voice.
    let voiceFile: String?

    private init(screen: Track?, camera: Track?, audio: [Track], originalVoice: Track?, voiceFile: String?) {
        self.screen = screen; self.camera = camera; self.audio = audio; self.originalVoice = originalVoice; self.voiceFile = voiceFile
    }

    /// Loads the media. With `audio` settings that turn enhance on and a rendered voice stem, the stem stands in for
    /// the microphone (same timing: it is sample-aligned with the raw track) and the raw track is kept aside.
    static func load(bundle: ProjectBundle, manifest: ProjectManifest, audio settings: AudioSettings? = nil) async throws -> MediaSources {
        func load(_ kind: TrackKind, _ type: AVMediaType, file: String? = nil) async throws -> Track? {
            guard let info = manifest.track(kind), let url = file.map(bundle.resolve) ?? bundle.mediaURL(for: kind, in: manifest),
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
        var original: Track?
        let raw = manifest.track(.microphone)?.file
        let voice = settings.flatMap { bundle.voiceFile(manifest: manifest, settings: $0) } ?? raw
        if let voice, voice != raw, let stem = try? await load(.microphone, .audio, file: voice) {
            audio.append(stem)
            original = try await load(.microphone, .audio)
        } else if let t = try await load(.microphone, .audio) {
            audio.append(t)
        }
        if let t = try await load(.systemAudio, .audio) { audio.append(t) }
        let playing = original == nil ? (audio.contains { $0.kind == .microphone } ? raw : nil) : voice
        return MediaSources(screen: screen, camera: camera, audio: audio, originalVoice: original, voiceFile: playing)
    }

    /// The system-audio duck automation for `timeline`: speech ranges of the voice (`analysis`) on the output timeline.
    /// `nil` when ducking is off, the voice is muted or absent, or system audio is silent.
    func duckCurve(timeline: EditTimeline, settings: AudioSettings, analysis: AudioAnalysis?) -> DuckCurve? {
        guard settings.duckSystemAudio, !settings.microphoneMuted, !settings.systemMuted,
              let voice = audio.first(where: { $0.kind == .microphone }), audio.contains(where: { $0.kind == .systemAudio }),
              let speech = analysis?.microphone?.speech, !speech.isEmpty,
              analysis?.systemAudio.map({ $0.integratedLUFS != nil }) ?? true else { return nil }
        let offset = voice.startTime
        let curve = DuckCurve(recordingRanges: speech.map { TimeRange(start: $0.start + offset, end: $0.end + offset) }, timeline: timeline)
        return curve.ranges.isEmpty ? nil : curve
    }

    struct Composition: @unchecked Sendable {
        let asset: AVMutableComposition
        let screen: AVMutableCompositionTrack?
        let camera: AVMutableCompositionTrack?
        /// Audio tracks with their linear gain (mutes already removed). `isOriginal`: the raw microphone next to the
        /// voice stem (preview only; silent unless "Hear original" is held).
        let audio: [(kind: TrackKind, track: AVMutableCompositionTrack, gain: Float, isOriginal: Bool)]
        let duration: Double
        /// Ducking for the system audio track, when on.
        var duck: DuckCurve?

        /// An audio mix that applies each track's gain (and the system audio's ducking) and limiter in an
        /// `AudioTrackProcessor` tap.
        func audioMix(forPlayback: Bool) -> (mix: AVAudioMix, processors: [AudioTrackProcessor])? {
            guard !audio.isEmpty else { return nil }
            let m = AudioTrackProcessor.mix(audio.map { AudioTrackProcessor.Lane(kind: $0.kind, track: $0.track, gain: $0.gain, isOriginal: $0.isOriginal) },
                                            forPlayback: forPlayback)
            for p in m.processors where p.kind == .systemAudio { p.duck = duck }
            return m
        }
    }

    static let timescale: CMTimeScale = 90_000
    static func time(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: timescale) }

    /// A composition of the kept ranges, back to back. `video` / `camera` / `audio` choose the tracks.
    /// `analysis` supplies the voice's measured loudness for auto level and its speech for ducking.
    /// `originalVoice` adds the raw microphone (at gain 0) when the voice is the stem.
    func composition(timeline: EditTimeline, video: Bool = true, camera wantCamera: Bool, audio settings: AudioSettings?,
                     analysis: AudioAnalysis? = nil, originalVoice: Bool = false) throws -> Composition {
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
        var audioTracks: [(kind: TrackKind, track: AVMutableCompositionTrack, gain: Float, isOriginal: Bool)] = []
        if let settings {
            for a in audio {
                guard settings.gainDB(for: a.kind, analysis: analysis) != nil, let t = try add(a, type: .audio) else { continue }
                audioTracks.append((a.kind, t, settings.linearGain(for: a.kind, analysis: analysis), false))
            }
            if originalVoice, let o = self.originalVoice, let t = try add(o, type: .audio) {
                audioTracks.append((.microphone, t, 0, true))
            }
        }
        var result = Composition(asset: comp, screen: screenTrack, camera: cameraTrack, audio: audioTracks, duration: timeline.duration)
        if let settings { result.duck = duckCurve(timeline: timeline, settings: settings, analysis: analysis) }
        return result
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
