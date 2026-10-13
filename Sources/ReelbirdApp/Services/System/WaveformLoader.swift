@preconcurrency import AVFoundation
import ReelbirdCore

/// Reads an audio file once and reduces it to `buckets` peak values in 0...1 for the timeline.
enum WaveformLoader {
    static func load(url: URL, buckets: Int) async -> [Float]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let duration = try? await asset.load(.duration).seconds, duration > 0 else { return nil }
        // The decode loop blocks, so it runs off the cooperative pool (see BlockingWork).
        return await BlockingWork.run("reelbird.waveform", qos: .utility) { cancel -> [Float]? in
            guard let reader = try? AVAssetReader(asset: asset) else { return nil }
            // Mono 16-bit at a low rate is plenty for a picture of the audio.
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1,
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { return nil }
            let total = max(1, Int(duration * 8000))
            let perBucket = max(1, total / buckets)
            var peaks = [Float](repeating: 0, count: buckets)
            var index = 0
            while !cancel.isCancelled, let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
                var length = 0
                var ptr: UnsafeMutablePointer<CChar>?
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr,
                      let ptr else { continue }
                ptr.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
                    for i in 0..<(length / 2) {
                        let b = min(buckets - 1, index / perBucket)
                        let v = Float(abs(Int32(samples[i]))) / 32768
                        if v > peaks[b] { peaks[b] = v }
                        index += 1
                    }
                }
            }
            if cancel.isCancelled { reader.cancelReading(); return nil }
            let maxPeak = max(0.05, peaks.max() ?? 1)
            return peaks.map { min(1, sqrt($0 / maxPeak)) }
        }
    }
}
