import AVFoundation
import ReelbirdCore
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
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
            ],
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

    static let microphone = AudioSpec(channels: 1, bitrate: 96_000)
    static let systemAudio = AudioSpec(channels: 2, bitrate: 160_000)
    static let shareAudio = AudioSpec(channels: 2, bitrate: 128_000)
}
