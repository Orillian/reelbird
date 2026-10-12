import AVFoundation
import CoreMedia
import Foundation

/// Synchronous AVFoundation helpers shared by the AI features.
enum AudioDecoding {
    struct LoadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// First audio track of a file, loaded without the deprecated synchronous `tracks` API.
    /// Blocks the calling thread; never call it from the main thread.
    static func firstAudioTrack(of asset: AVURLAsset) throws -> AVAssetTrack {
        let box = ResultBox<AVAssetTrack>()
        let done = DispatchSemaphore(value: 0)
        asset.loadTracks(withMediaType: .audio) { tracks, error in
            if let track = tracks?.first {
                box.set(.success(track))
            } else {
                let reason = error?.localizedDescription ?? "the file has no audio track"
                box.set(.failure(LoadError(message: "Can't read audio from \(asset.url.lastPathComponent): \(reason).")))
            }
            done.signal()
        }
        done.wait()
        return try box.get()
    }

    /// Duration of a media file in seconds (0 if unknown).
    static func duration(of url: URL) async -> Double {
        guard let d = try? await AVURLAsset(url: url).load(.duration), d.seconds.isFinite else { return 0 }
        return d.seconds
    }

    /// Decodes the first audio track to a temporary 16-bit PCM CAF file (for APIs that need an `AVAudioFile`
    /// but can't open the source container, e.g. fragmented MP4). The caller deletes the file.
    static func decodeToTemporaryPCM(_ url: URL) throws -> URL {
        let asset = AVURLAsset(url: url)
        let track = try firstAudioTrack(of: asset)
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: any Sendable] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw LoadError(message: "Can't decode \(url.lastPathComponent): \(reader.error?.localizedDescription ?? "unknown error").")
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("reelbird-\(UUID().uuidString).caf")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true) else {
            throw LoadError(message: "Can't create a PCM audio format.")
        }
        let file = try AVAudioFile(forWriting: tmp, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        while let sample = output.copyNextSampleBuffer() {
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard frames > 0, let block = CMSampleBufferGetDataBuffer(sample),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let dst = buffer.int16ChannelData?[0] else { continue }
            buffer.frameLength = frames
            let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: Int(frames) * 2, destination: dst)
            guard status == kCMBlockBufferNoErr else { continue }
            try file.write(from: buffer)
        }
        if reader.status == .failed {
            try? FileManager.default.removeItem(at: tmp)
            throw LoadError(message: "Decoding \(url.lastPathComponent) failed: \(reader.error?.localizedDescription ?? "unknown error").")
        }
        return tmp
    }
}

/// A thread-safe single-value box for bridging callbacks.
final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, any Error>?
    func set(_ v: Result<T, any Error>) { lock.lock(); if value == nil { value = v }; lock.unlock() }
    /// Sets the value only if none was set; returns whether this call set it.
    func trySet(_ v: Result<T, any Error>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard value == nil else { return false }
        value = v
        return true
    }
    func get() throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard let value else { throw AudioDecoding.LoadError(message: "No result.") }
        return try value.get()
    }
}
