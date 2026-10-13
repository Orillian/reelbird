@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import ReelbirdRender

/// An interleaved stereo Float32 buffer of `frames` frames at `start` (in frames), every sample `value`.
private func buffer(start: Int, frames: Int, value: Float = 0.1) throws -> CMSampleBuffer {
    var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                           mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                           mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                           mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    var fd: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                   magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
    let samples = [Float](repeating: value, count: frames * 2)
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: frames * 8, blockAllocator: nil,
                                       customBlockSource: nil, offsetToData: 0, dataLength: frames * 8, flags: 0, blockBufferOut: &block)
    samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: frames * 8) }
    var sb: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block!, formatDescription: try #require(fd),
                                                         sampleCount: frames, presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: 48_000),
                                                         packetDescriptions: nil, sampleBufferOut: &sb)
    return try #require(sb)
}

/// Checks the output is gapless from zero and returns its frame count and samples (left channel).
private func collect(_ buffers: [CMSampleBuffer]) -> (frames: Int, left: [Float]) {
    var frames = 0
    var left: [Float] = []
    for b in buffers {
        #expect(CMSampleBufferGetPresentationTimeStamp(b) == CMTime(value: CMTimeValue(frames), timescale: 48_000))
        let n = CMSampleBufferGetNumSamples(b)
        var s = [Float](repeating: 0, count: n * 2)
        s.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(CMSampleBufferGetDataBuffer(b)!, atOffset: 0, dataLength: n * 8, destination: $0.baseAddress!) }
        left += stride(from: 0, to: s.count, by: 2).map { s[$0] }
        frames += n
    }
    return (frames, left)
}

/// The mix output hands out whole 8192-frame buffers past the end: the finisher cuts at the exact frame.
@Test func mixFinisherCutsTheLastBufferAtTheEnd() throws {
    let length = MixFinisher.frames(5.4, sampleRate: 48_000)
    #expect(length == 259_200)
    let f = MixFinisher(sampleRate: 48_000, channels: 2, length: length)
    var out: [CMSampleBuffer] = []
    var at = 0
    // An odd-sized buffer partway, as the time-pitch stretcher produces at a speed change.
    for n in [8192, 8192, 2705] + Array(repeating: 8192, count: 40) where !f.isComplete {
        out += f.process(try buffer(start: at, frames: n))
        at += n
    }
    out += f.finish()
    let (frames, left) = collect(out)
    #expect(frames == length)
    #expect(f.isComplete)
    // Look-ahead delays removed: sound from frame 0 (the processors' delay is already in the input, so the
    // first frames hold the limiter's ramp-in of the processors' silence, then full level).
    #expect(abs(left[frames - 1] - 0.1) < 1e-6)
}

/// Input that stops short (a silent piece at the end) is padded with silence to the full length.
@Test func mixFinisherPadsShortInput() throws {
    let length = 48_000
    let f = MixFinisher(sampleRate: 48_000, channels: 2, length: length)
    var out = f.process(try buffer(start: 0, frames: 10_000))
    out += f.finish()
    let (frames, left) = collect(out)
    #expect(frames == length)
    #expect(left[length - 1] == 0)
    #expect(left[5_000] > 0.09)
}

/// Buffers are placed by their timestamps: a gap becomes silence, an overlap is dropped, a 1-frame rounding is ignored.
@Test func mixFinisherPlacesBuffersByTime() throws {
    let latency = AudioTrackProcessor.latency(sampleRate: 48_000)
    let f = MixFinisher(sampleRate: 48_000, channels: 2, length: 30_000)
    var out = f.process(try buffer(start: 0, frames: 10_000, value: 0.1))
    out += f.process(try buffer(start: 15_000, frames: 5_000, value: 0.2)) // gap 10 000–15 000
    out += f.process(try buffer(start: 19_000, frames: 2_000, value: 0.3)) // overlaps 1 000 frames
    out += f.process(try buffer(start: 20_999, frames: 1_000, value: 0.4)) // 1 frame early: contiguous
    out += f.finish()
    let (frames, left) = collect(out)
    #expect(frames == 30_000)
    // Output frame k is input frame k + the processors' latency (already in the mix output).
    func at(_ input: Int) -> Float { left[input - latency] }
    #expect(abs(at(5_000) - 0.1) < 1e-6)
    #expect(at(12_000) == 0)
    #expect(abs(at(17_000) - 0.2) < 1e-6)
    #expect(abs(at(20_500) - 0.3) < 1e-6)
    #expect(abs(at(21_500) - 0.4) < 1e-6)
    #expect(at(25_000) == 0)
}
