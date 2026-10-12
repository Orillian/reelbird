@preconcurrency import AVFoundation
import Foundation
import Testing
import VideoToolbox

/// Encoder settings experiment: `RB_EXP=1 scripts/test.sh --filter encoderExperiment`.
@Test func encoderExperiment() async throws {
    guard ProcessInfo.processInfo.environment["RB_EXP"] != nil else { return }
    let w = 3840, h = 2160, n = 240
    let sp = kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String
    let variants: [(String, AVVideoCodecType, [String: Any], [String: Any]?, OSType, Int)] = [
        ("h264 nv12", .h264, [AVVideoAverageBitRateKey: 50_000_000], nil, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 1),
        ("h264 nv12 speed", .h264, [AVVideoAverageBitRateKey: 50_000_000, sp: true], nil, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 1),
        ("h264 main", .h264, [AVVideoAverageBitRateKey: 50_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel], nil, kCVPixelFormatType_32BGRA, 1),
        ("h264 lowlatency", .h264, [AVVideoAverageBitRateKey: 50_000_000], [kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true], kCVPixelFormatType_32BGRA, 1),
        ("h264 x2 parallel", .h264, [AVVideoAverageBitRateKey: 50_000_000], nil, kCVPixelFormatType_32BGRA, 2),
        ("hevc speed x2 parallel", .hevc, [AVVideoAverageBitRateKey: 32_000_000, sp: true], nil, kCVPixelFormatType_32BGRA, 2),
        ("hevc speed nv12", .hevc, [AVVideoAverageBitRateKey: 32_000_000, sp: true], nil, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 1),
    ]
    for (name, codec, props, spec, fmt, par) in variants {
      let t0 = Date()
      await withTaskGroup(of: Void.self) { g in
       let box = UncheckedExp((codec, props, spec, fmt))
       for _ in 0..<par { g.addTask {
        let (codec, props, spec, fmt) = box.v
        try? await encodeOnce(codec: codec, props: props, spec: spec, fmt: fmt, w: w, h: h, n: n)
       } }
      }
      let dt = Date().timeIntervalSince(t0)
      print("EXP \(name): \(String(format: "%.0f", Double(n * par) / dt)) fps aggregate")
    }
}

func encodeOnce(codec: AVVideoCodecType, props: [String: Any], spec: [String: Any]?, fmt: OSType, w: Int, h: Int, n: Int) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("exp-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: codec, AVVideoWidthKey: w, AVVideoHeightKey: h,
                                                                            AVVideoCompressionPropertiesKey: props].merging(spec.map { [AVVideoEncoderSpecificationKey: $0] } ?? [:]) { a, _ in a })
        input.expectsMediaDataInRealTime = false
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: fmt, kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h, kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()])
        writer.add(input)
        writer.startWriting(); writer.startSession(atSourceTime: .zero)
        var bufs: [CVPixelBuffer] = []
        for i in 0..<8 {
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, ad.pixelBufferPool!, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(pb!)
            let rows = CVPixelBufferIsPlanar(pb!) ? h : h
            let b0 = CVPixelBufferIsPlanar(pb!) ? CVPixelBufferGetBaseAddressOfPlane(pb!, 0)!.assumingMemoryBound(to: UInt8.self) : base
            let bp = CVPixelBufferIsPlanar(pb!) ? CVPixelBufferGetBytesPerRowOfPlane(pb!, 0) : bpr
            for r in 0..<rows { memset(b0 + r * bp, Int32((r / 40 + i * 13) % 255), bp) }
            CVPixelBufferUnlockBaseAddress(pb!, [])
            bufs.append(pb!)
        }
        for i in 0..<n {
            while !input.isReadyForMoreMediaData { usleep(200) }
            ad.append(bufs[i % 8], withPresentationTime: CMTime(value: Int64(i), timescale: 60))
        }
        input.markAsFinished()
        await writer.finishWriting()
}

struct UncheckedExp<T>: @unchecked Sendable { let v: T; init(_ v: T) { self.v = v } }
