import AVFoundation
import ReelbirdCore
import Synchronization
import VideoToolbox

/// Video encoder configuration for one track.
struct VideoSpec: Sendable, Hashable {
    enum Codec: String, Sendable { case hevc, h264 }
    var codec: Codec
    var size: PixelSize
    var frameRate: Int
    var bitrate: Int
    /// Seconds between keyframes (aligned with the 2 s segments).
    var keyframeInterval: Double = 2
    /// Require the hardware encoder (the default). `false` is the last-resort software fallback.
    var requireHardware = true

    /// `AVAssetWriterInput` output settings: hardware encoder required, no B-frames, BT.709 tags.
    var outputSettings: [String: Any] {
        let profile: String = codec == .hevc ? (kVTProfileLevel_HEVC_Main_AutoLevel as String) : AVVideoProfileLevelH264HighAutoLevel
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: frameRate,
            AVVideoMaxKeyFrameIntervalKey: max(1, Int(Double(frameRate) * keyframeInterval)),
            AVVideoMaxKeyFrameIntervalDurationKey: keyframeInterval,
            AVVideoAllowFrameReorderingKey: false,
            AVVideoProfileLevelKey: profile,
        ]
        if codec == .h264 { compression[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC }
        return [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoEncoderSpecificationKey: requireHardware
                ? [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true]
                : [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true],
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }
}

/// AAC encoder configuration for one track. Input is always 48 kHz Float32 interleaved.
struct AudioSpec: Sendable, Hashable {
    var sampleRate = 48_000
    var channels: Int
    var bitrate: Int

    var outputSettings: [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitrate,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ]
    }
}

enum EncoderSettings {
    /// H.264 hardware encoders top out around 4096 pixels wide; above that the compact preset uses HEVC.
    static let h264MaxWidth = 4096
    static let h264MaxHeight = 2304

    /// Bits per pixel per frame for each preset. Frame rates above 30 count half (screen content
    /// changes little between frames, so 60 fps costs far less than double).
    static func bitsPerPixel(_ q: RecordingOptions.Quality) -> Double {
        switch q {
        case .high: 0.06
        case .max: 0.12
        case .compact: 0.07
        }
    }

    static func effectiveFrameRate(_ fps: Int) -> Double {
        let f = Double(fps)
        return min(f, 30) + max(0, f - 30) * 0.5
    }

    static func screen(size: PixelSize, frameRate: Int, quality: RecordingOptions.Quality) -> VideoSpec {
        var codec: VideoSpec.Codec = quality == .compact ? .h264 : .hevc
        if codec == .h264 && (size.width > h264MaxWidth || size.height > h264MaxHeight) { codec = .hevc }
        let px = Double(size.width * size.height)
        let bitrate = Int(px * effectiveFrameRate(frameRate) * bitsPerPixel(quality))
        return VideoSpec(codec: codec, size: size, frameRate: frameRate, bitrate: max(1_000_000, bitrate))
    }

    static func camera(size: PixelSize, frameRate: Int) -> VideoSpec {
        let px = Double(size.width * size.height)
        return VideoSpec(codec: .h264, size: size, frameRate: frameRate,
                         bitrate: max(1_000_000, Int(px * Double(min(frameRate, 30)) * 0.08)), keyframeInterval: 2)
    }

    /// Quick-share stream: H.264, at most 1920 wide, 30 fps.
    static func share(screen: PixelSize) -> VideoSpec {
        let w = Double(screen.width), h = Double(screen.height)
        let scale = min(1, 1920 / w, 1200 / h)
        let size = PixelSize(width: even(w * scale), height: even(h * scale))
        let px = Double(size.width * size.height)
        return VideoSpec(codec: .h264, size: size, frameRate: 30, bitrate: max(1_500_000, Int(px * 30 * 0.06)))
    }

    // MARK: Encoder availability

    /// Specs to try in order for `spec`: the requested hardware encoder, the other hardware codec
    /// (H.264 needs ~40% more bits for the same quality; it tops out at 4096×2304), then software.
    static func candidates(for spec: VideoSpec) -> [VideoSpec] {
        func with(_ codec: VideoSpec.Codec, hardware: Bool) -> VideoSpec? {
            var s = spec
            s.codec = codec
            s.requireHardware = hardware
            if codec == .h264 && (s.size.width > h264MaxWidth || s.size.height > h264MaxHeight) && hardware { return nil }
            if codec != spec.codec { s.bitrate = codec == .h264 ? Int(Double(spec.bitrate) * 1.4) : Int(Double(spec.bitrate) / 1.4) }
            return s
        }
        let other: VideoSpec.Codec = spec.codec == .hevc ? .h264 : .hevc
        return [with(spec.codec, hardware: true), with(other, hardware: true), with(spec.codec, hardware: false)].compactMap { $0 }
    }

    /// The first candidate the machine can encode, according to `probe` (default: a real
    /// VideoToolbox session). Falls back to the software encoder if nothing else is available.
    static func resolve(_ spec: VideoSpec, probe: (VideoSpec) -> Bool = canEncode) -> VideoSpec {
        let list = candidates(for: spec)
        return list.first(where: probe) ?? list.last ?? spec
    }

    private static let probeCache = Mutex<[String: Bool]>([:])

    /// Whether a compression session for this codec, size and hardware requirement can be created.
    /// Cached per configuration; costs a few milliseconds the first time.
    static func canEncode(_ spec: VideoSpec) -> Bool {
        let key = "\(spec.codec.rawValue) \(spec.size.width)x\(spec.size.height) \(spec.requireHardware)"
        if let cached = probeCache.withLock({ $0[key] }) { return cached }
        let encoderSpec: CFDictionary = (spec.requireHardware
            ? [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true]
            : [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true]) as CFDictionary
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(spec.size.width), height: Int32(spec.size.height),
            codecType: spec.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: encoderSpec, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        if let session { VTCompressionSessionInvalidate(session) }
        let ok = status == noErr && session != nil
        probeCache.withLock { $0[key] = ok }
        return ok
    }

    /// Builds a writer with the first candidate that works: probed first, then actually started,
    /// so an encoder that fails at `startWriting` also falls through to the next codec.
    static func makeWriter(_ spec: VideoSpec, probe: (VideoSpec) -> Bool = canEncode,
                           build: (VideoSpec) throws -> SegmentedWriter) throws -> (SegmentedWriter, VideoSpec) {
        var lastError: (any Error)?
        let list = candidates(for: spec)
        for candidate in list where probe(candidate) || candidate == list.last {
            do {
                return (try build(candidate), candidate)
            } catch {
                CaptureLog.debug("encoder \(candidate.codec) \(candidate.size.width)x\(candidate.size.height) hw=\(candidate.requireHardware): \(error)")
                lastError = error
            }
        }
        throw lastError ?? CaptureError.encoderUnavailable("\(spec.codec.rawValue) \(spec.size.width)x\(spec.size.height)")
    }

    static let microphone = AudioSpec(channels: 1, bitrate: 96_000)
    static let systemAudio = AudioSpec(channels: 2, bitrate: 160_000)
    static let shareAudio = AudioSpec(channels: 2, bitrate: 128_000)
}
