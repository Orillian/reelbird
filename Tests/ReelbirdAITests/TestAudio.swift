import AVFoundation
import CoreMedia
import Foundation

/// Test fixtures: synthetic audio files written with the real encoders.
enum TestAudio {
    static func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("reelbird-test-\(UUID().uuidString).\(ext)")
    }

    /// One piece of a generated signal: a sine tone (`amplitude` > 0) or silence.
    struct Piece { var duration: Double; var amplitude: Float }

    /// Writes an AAC (.m4a) file with AVAssetWriter: mono 44.1 kHz, 440 Hz tones and digital silence.
    static func writeAAC(_ pieces: [Piece], to url: URL, sampleRate: Double = 44_100) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        guard let fmt else { throw CocoaError(.fileWriteUnknown) }

        var samples: [Float] = []
        var phase = 0.0
        for p in pieces {
            let n = Int(p.duration * sampleRate)
            for _ in 0..<n {
                samples.append(p.amplitude * Float(sin(phase)))
                phase += 2 * .pi * 440 / sampleRate
            }
        }
        let chunk = 4096
        var offset = 0
        while offset < samples.count {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            let n = min(chunk, samples.count - offset)
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n * 4, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: n * 4, flags: 0,
                                               blockBufferOut: &block)
            guard let block else { throw CocoaError(.fileWriteUnknown) }
            samples.withUnsafeBytes { raw in
                _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress! + offset * 4, blockBuffer: block,
                                                  offsetIntoDestination: 0, dataLength: n * 4)
            }
            var sb: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: n,
                presentationTimeStamp: CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(sampleRate)),
                packetDescriptions: nil, sampleBufferOut: &sb)
            guard let sb, input.append(sb) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            offset += n
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// Speech audio from the system voice (`say`). Returns nil if `say` isn't usable.
    static func say(_ text: String, to url: URL, extraArgs: [String] = []) -> URL? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-o", url.path] + extraArgs + [text]
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        return p.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
