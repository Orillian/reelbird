@preconcurrency import AVFoundation
import Foundation
import MediaToolbox
import ReelbirdCore
import Synchronization

/// Shared settings of every limiter in the audio path.
enum AudioDSP {
    /// Output ceiling: −1.5 dBFS on samples and estimated inter-sample peaks, so boosts never clip and AAC
    /// encoding (which overshoots heavily limited peaks by up to ~0.4 dB, measured) still decodes under −1 dBFS.
    static let ceiling: Float = 0.841_395_1
    /// How far ahead the limiter looks. Each limiter delays its audio by exactly this much.
    static let lookahead = 0.005
    /// Time for the gain to recover after a peak.
    static let release = 0.12
}

/// A look-ahead brick-wall limiter. Gain reduction starts `lookahead` before a peak and ramps smoothly
/// (sliding minimum + box filter, so the gain is guaranteed under the ceiling at the peak), then releases
/// exponentially. Peaks include an inter-sample estimate (Catmull-Rom at ¼, ½, ¾ between samples), so the
/// reconstructed waveform stays under the ceiling too, not just the samples. Channels are linked.
///
/// The output is the input delayed by `latency` frames. Not thread-safe: one audio thread owns it.
final class PeakLimiter {
    let channels: Int
    /// Delay in frames between input and output.
    let latency: Int
    let ceiling: Float
    private let releaseCoeff: Float
    private let delay: UnsafeMutablePointer<Float>
    private var delayPos = 0
    /// Last three input samples per channel (x[n-3], x[n-2], x[n-1]).
    private let history: UnsafeMutablePointer<Float>
    /// Monotonic deque of (index, required gain) for the sliding minimum.
    private let dqIndex: UnsafeMutablePointer<Int>
    private let dqValue: UnsafeMutablePointer<Float>
    private var dqHead = 0, dqCount = 0
    /// The last `latency` sliding minimums and their sum (the box filter).
    private let box: UnsafeMutablePointer<Float>
    private var boxPos = 0
    private var boxSum: Double
    private var gain: Float = 1
    private var frame = 0
    private let pointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    /// Lowest gain applied since the last `takeMinimumGain()` (diagnostics, tests).
    private(set) var minimumGain: Float = 1

    init(channels: Int, sampleRate: Double, ceiling: Float = AudioDSP.ceiling,
         lookahead: Double = AudioDSP.lookahead, release: Double = AudioDSP.release) {
        self.channels = max(1, channels)
        latency = max(1, Int((lookahead * sampleRate).rounded()))
        self.ceiling = ceiling
        releaseCoeff = Float(1 - exp(-1 / (release * sampleRate)))
        delay = .allocate(capacity: latency * self.channels)
        delay.initialize(repeating: 0, count: latency * self.channels)
        history = .allocate(capacity: 3 * self.channels)
        history.initialize(repeating: 0, count: 3 * self.channels)
        dqIndex = .allocate(capacity: latency + 1)
        dqIndex.initialize(repeating: 0, count: latency + 1)
        dqValue = .allocate(capacity: latency + 1)
        dqValue.initialize(repeating: 1, count: latency + 1)
        box = .allocate(capacity: latency)
        box.initialize(repeating: 1, count: latency)
        boxSum = Double(latency)
        pointers = .allocate(capacity: self.channels)
        pointers.initialize(repeating: delay, count: self.channels)
    }

    deinit {
        delay.deallocate(); history.deallocate(); dqIndex.deallocate(); dqValue.deallocate()
        box.deallocate(); pointers.deallocate()
    }

    func takeMinimumGain() -> Float { defer { minimumGain = 1 }; return minimumGain }

    /// Limits `frames` frames in place. `base(c)` is channel c's first sample; samples of one channel are
    /// `stride` floats apart (1 for non-interleaved buffers, `channels` for interleaved).
    func process(frames: Int, stride: Int, base: (Int) -> UnsafeMutablePointer<Float>) {
        for c in 0..<channels { pointers[c] = base(c) }
        let cap = latency + 1
        for i in 0..<frames {
            let o = i * stride
            // Requirement for the previous frame: its sample and the curve between it and the one before.
            var peak: Float = 0
            for c in 0..<channels {
                let h = history + 3 * c
                let p0 = h[0], p1 = h[1], p2 = h[2], p3 = pointers[c][o]
                peak = max(peak, abs(p2), Self.interSamplePeak(p0, p1, p2, p3))
                h[0] = p1; h[1] = p2; h[2] = p3
            }
            let required: Float = peak > ceiling ? ceiling / peak : 1
            // Sliding minimum over the last `latency` requirements.
            while dqCount > 0, dqValue[(dqHead + dqCount - 1) % cap] >= required { dqCount -= 1 }
            let slot = (dqHead + dqCount) % cap
            dqIndex[slot] = frame; dqValue[slot] = required; dqCount += 1
            while dqIndex[dqHead] <= frame - latency { dqHead = (dqHead + 1) % cap; dqCount -= 1 }
            let held = dqValue[dqHead]
            // Box filter over the last `latency` minimums.
            boxSum += Double(held - box[boxPos])
            box[boxPos] = held
            boxPos = (boxPos + 1) % latency
            let target = Float(boxSum / Double(latency))
            gain = target < gain ? target : gain + (target - gain) * releaseCoeff
            if gain < minimumGain { minimumGain = gain }
            // Delay line: output the frame from `latency` frames ago.
            let d = delay + delayPos * channels
            for c in 0..<channels {
                let x = pointers[c][o]
                pointers[c][o] = d[c] * gain
                d[c] = x
            }
            delayPos = (delayPos + 1) % latency
            frame += 1
        }
    }

    /// Largest magnitude of the Catmull-Rom curve between p1 and p2 at t = ¼, ½, ¾.
    @inline(__always)
    static func interSamplePeak(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float) -> Float {
        let a = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3
        let b = p0 - 2.5 * p1 + 2 * p2 - 0.5 * p3
        let c = -0.5 * p0 + 0.5 * p2
        func at(_ t: Float) -> Float { abs(((a * t + b) * t + c) * t + p1) }
        return max(at(0.25), at(0.5), at(0.75))
    }
}

/// Gain, ducking and limiting for one audio track, run inside an `MTAudioProcessingTap`. The same processor
/// type runs in the editor's preview (on the `AVPlayerItem`'s audio mix) and in export (on the
/// `AVAssetReaderAudioMixOutput`'s audio mix), so both sound the same. `gain` and `duck` may change at any time
/// from any thread; a gain change ramps over one buffer, so live edits don't click.
final class AudioTrackProcessor: @unchecked Sendable {
    /// One track of an audio mix.
    struct Lane {
        var kind: TrackKind
        var track: AVAssetTrack
        var gain: Float
        /// The raw microphone next to the voice stem ("Hear original" in preview).
        var isOriginal = false
    }

    let kind: TrackKind
    let isOriginal: Bool
    private let targetGain: Synchronization.Atomic<UInt32>
    private let sourceTimeBits = Synchronization.Atomic<UInt64>(Double.nan.bitPattern)
    private let duckState = Mutex<DuckCurve?>(nil)
    // Below: touched only by MediaToolbox's prepare/process/unprepare, which it serialises.
    private var limiter: PeakLimiter?
    private var appliedGain: Float
    private var interleaved = false
    private var isFloat = true
    private var sampleRate = 48_000.0
    /// Frames processed since `prepare`: the clock when a buffer comes without a time.
    private var framesSincePrepare = 0
    private var channelData: [UnsafeMutablePointer<Float>?] = []

    init(kind: TrackKind, gain: Float, isOriginal: Bool = false) {
        self.kind = kind
        self.isOriginal = isOriginal
        targetGain = Synchronization.Atomic(gain.bitPattern)
        appliedGain = gain
    }

    /// Ducking automation on the output timeline (system audio under the voice), or `nil` for none.
    var duck: DuckCurve? {
        get { duckState.withLock { $0 } }
        set { duckState.withLock { $0 = newValue } }
    }

    /// Steps between duck-gain evaluations; the gain ramps linearly in between.
    private static let duckStep = 32

    /// Linear gain applied before the limiter.
    var gain: Float {
        get { Float(bitPattern: targetGain.load(ordering: .relaxed)) }
        set { targetGain.store(newValue.bitPattern, ordering: .relaxed) }
    }

    /// Frames of delay the processor adds (the limiter's look-ahead) at `sampleRate`.
    static func latency(sampleRate: Double) -> Int { max(1, Int((AudioDSP.lookahead * sampleRate).rounded())) }

    func prepare(format: AudioStreamBasicDescription) {
        isFloat = format.mFormatID == kAudioFormatLinearPCM && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
        interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        limiter = isFloat ? PeakLimiter(channels: Int(format.mChannelsPerFrame), sampleRate: format.mSampleRate) : nil
        channelData = Array(repeating: nil, count: max(1, Int(format.mChannelsPerFrame)))
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        framesSincePrepare = 0
        appliedGain = gain
    }

    func unprepare() { limiter = nil }

    /// Item time of the start of the last buffer processed (diagnostics, tests). NaN before the first.
    var lastSourceTime: Double { Double(bitPattern: sourceTimeBits.load(ordering: .relaxed)) }
    fileprivate func noteSourceTime(_ t: CMTimeRange) {
        if t.start.isNumeric { sourceTimeBits.store(t.start.seconds.bitPattern, ordering: .relaxed) }
    }

    /// Applies the gain (ramped from the last buffer's), the duck automation and the limiter to `frames` frames in
    /// place. `time`: output time of the first frame (NaN = continue from the previous buffer).
    func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, time: Double = .nan) {
        guard frames > 0, let limiter else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let target = gain
        let start = appliedGain
        let step = (target - start) / Float(frames)
        let channels = limiter.channels
        let t0 = time.isFinite ? time : Double(framesSincePrepare) / sampleRate
        framesSincePrepare = time.isFinite ? Int((time * sampleRate).rounded()) + frames : framesSincePrepare + frames
        // The duck curve, when it changes anything in this buffer. Never blocks the audio thread.
        let curve = duckState.withLockIfAvailable { $0 } ?? nil
        let duck = curve.flatMap { $0.isActive(from: t0, to: t0 + Double(frames) / sampleRate) ? $0 : nil }
        let rate = sampleRate
        func gainAt(_ f: Int, _ duckGain: Float) -> Float { (start + step * Float(f + 1)) * duckGain }
        // Duck gain for frame f, linear between evaluations every `duckStep` frames.
        var d0: Float = 1, d1: Float = 1, segment = -1
        func duckGain(_ f: Int) -> Float {
            guard let duck else { return 1 }
            let k = f / Self.duckStep
            if k != segment {
                segment = k
                d0 = duck.gain(at: t0 + Double(k * Self.duckStep) / rate)
                d1 = duck.gain(at: t0 + Double((k + 1) * Self.duckStep) / rate)
            }
            return d0 + (d1 - d0) * Float(f - k * Self.duckStep) / Float(Self.duckStep)
        }
        if interleaved {
            guard let data = buffers.first?.mData?.assumingMemoryBound(to: Float.self),
                  Int(buffers[0].mDataByteSize) >= frames * channels * 4 else { return }
            for f in 0..<frames {
                let g = gainAt(f, duckGain(f))
                for c in 0..<channels { data[f * channels + c] *= g }
            }
            limiter.process(frames: frames, stride: channels) { data + $0 }
        } else {
            guard buffers.count >= channels, channelData.count >= channels else { return }
            for c in 0..<channels {
                guard let d = buffers[c].mData?.assumingMemoryBound(to: Float.self), Int(buffers[c].mDataByteSize) >= frames * 4 else { return }
                channelData[c] = d
            }
            for f in 0..<frames {
                let g = gainAt(f, duckGain(f))
                for c in 0..<channels { channelData[c]![f] *= g }
            }
            limiter.process(frames: frames, stride: 1) { channelData[$0]! }
        }
        appliedGain = target
    }

    /// An audio processing tap running this processor. It keeps the processor alive until the tap is released.
    /// `forPlayback`: a post-effects tap, which AVPlayer starts on time with (measured: with a pre-effects tap
    /// `setRate(_:time:atHostTime:)` skipped the first ~0.37 s of audio and `play()` started ~0.3 s late).
    /// Export uses a pre-effects tap: `AVAssetReaderAudioMixOutput` stalls with a post-effects one (measured).
    /// Track volumes stay 1, so the order doesn't change the sound.
    func makeTap(forPlayback: Bool) -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<AudioTrackProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                Unmanaged<AudioTrackProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .prepare(format: format.pointee)
            },
            unprepare: { tap in
                Unmanaged<AudioTrackProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().unprepare()
            },
            process: { tap, frames, _, list, framesOut, flagsOut in
                var range = CMTimeRange.invalid
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, list, flagsOut, &range, framesOut) == noErr else { return }
                let processor = Unmanaged<AudioTrackProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                processor.noteSourceTime(range)
                processor.process(list, frames: Int(framesOut.pointee), time: range.start.isNumeric ? range.start.seconds : .nan)
            })
        var tap: MTAudioProcessingTap?
        let flags = forPlayback ? kMTAudioProcessingTapCreationFlag_PostEffects : kMTAudioProcessingTapCreationFlag_PreEffects
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, flags, &tap)
        guard status == noErr, let tap else {
            Unmanaged.passUnretained(self).release()
            return nil
        }
        return tap
    }

    /// Length of the fade around a stretch whose sound is left out (a speed over 2×), so it never clicks.
    static let silenceFade = 0.012

    /// Silent output ranges, sorted and merged where the fades between them would overlap (volume ramps must not).
    static func silenceRanges(_ ranges: [TimeRange]) -> [TimeRange] {
        var out: [TimeRange] = []
        for r in ranges.sorted(by: { $0.start < $1.start }) where r.duration > 0 {
            if let last = out.last, r.start - last.end < 2 * silenceFade + 0.001 {
                out[out.count - 1].end = max(last.end, r.end)
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// An audio mix that runs one processor per track. Track volumes stay at 1 (gain happens in the tap), except
    /// for short fades into and out of the `silent` output ranges.
    static func mix(_ tracks: [Lane], forPlayback: Bool, silent: [TimeRange] = []) -> (mix: AVAudioMix, processors: [AudioTrackProcessor]) {
        let mix = AVMutableAudioMix()
        var processors: [AudioTrackProcessor] = []
        mix.inputParameters = tracks.map { t in
            let p = AVMutableAudioMixInputParameters(track: t.track)
            let processor = AudioTrackProcessor(kind: t.kind, gain: t.gain, isOriginal: t.isOriginal)
            var level: Float = 1
            if let tap = processor.makeTap(forPlayback: forPlayback) {
                p.audioTapProcessor = tap
            } else {
                level = min(1, t.gain)
                p.setVolume(level, at: .zero)
            }
            processors.append(processor)
            for r in silenceRanges(silent) {
                let f = silenceFade
                if r.start > 0 {
                    p.setVolumeRamp(fromStartVolume: level, toEndVolume: 0,
                                    timeRange: CMTimeRange(start: MediaSources.time(max(0, r.start - f)), end: MediaSources.time(r.start)))
                } else {
                    p.setVolume(0, at: .zero)
                }
                p.setVolumeRamp(fromStartVolume: 0, toEndVolume: level,
                                timeRange: CMTimeRange(start: MediaSources.time(r.end), end: MediaSources.time(r.end + f)))
            }
            return p
        }
        return (mix, processors)
    }
}

/// The last stage of export audio: limits the summed mix (voice and system audio can add up past the
/// ceiling even though each is limited) and removes the look-ahead delays of the track processors and of
/// this limiter, so audio stays sample-aligned with video. Takes interleaved Float32 buffers in, hands
/// new ones out.
///
/// The output is exactly `length` frames from time zero, whatever the mix output delivers: each input buffer
/// is placed by its timestamp (gaps become silence, overlaps are dropped), the buffer that crosses the end is
/// cut at the exact frame, and `finish()` pads with silence if the input stopped short. The mix output can't do
/// this itself: it hands out whole 8192-frame buffers past `AVAssetReader.timeRange`, and where its last buffer
/// ends depends on how the time-pitch stretcher chunked the speed segments before it (measured: 0–170 ms over).
final class MixFinisher {
    let sampleRate: Double
    let channels: Int
    /// Frames the output has in all.
    let length: Int
    private let limiter: PeakLimiter
    /// Frames still to drop from the limiter's output (all look-ahead delays).
    private var skip: Int
    /// Input position (frames from zero) the next input frame belongs at.
    private var inputFrame = 0
    /// Frames handed out so far.
    private(set) var outputFrames = 0
    private var format: CMAudioFormatDescription?
    private var scratch: [Float] = []
    private static let chunk = 8192

    init(sampleRate: Double, channels: Int, length: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.length = max(0, length)
        limiter = PeakLimiter(channels: channels, sampleRate: sampleRate)
        skip = limiter.latency + AudioTrackProcessor.latency(sampleRate: sampleRate)
    }

    /// Output frames for a duration in seconds, rounded to the nearest frame.
    static func frames(_ seconds: Double, sampleRate: Double) -> Int { max(0, Int((seconds * sampleRate).rounded())) }

    /// Whether every output frame has been handed out.
    var isComplete: Bool { outputFrames >= length }

    /// Processes one buffer from the mix output. Returns the buffers to append (none, or a silent gap and the audio).
    func process(_ sb: CMSampleBuffer) -> [CMSampleBuffer] {
        guard !isComplete, let bb = CMSampleBufferGetDataBuffer(sb) else { return [] }
        if format == nil { format = CMSampleBufferGetFormatDescription(sb) }
        let frames = CMBlockBufferGetDataLength(bb) / (4 * channels)
        guard frames > 0 else { return [] }
        var out: [CMSampleBuffer] = []
        // Where this buffer belongs. Untimed buffers, and a frame's rounding either way, continue from the last.
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        var at = pts.isNumeric ? Int(CMTimeConvertScale(pts, timescale: CMTimeScale(sampleRate), method: .roundHalfAwayFromZero).value) : inputFrame
        if abs(at - inputFrame) <= 1 { at = inputFrame }
        if at > inputFrame { out += silence(at - inputFrame) }
        let drop = min(frames, max(0, inputFrame - at))
        let count = frames - drop
        guard count > 0, !isComplete else { return out }
        if scratch.count < count * channels { scratch = [Float](repeating: 0, count: count * channels) }
        let ok = scratch.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(bb, atOffset: drop * channels * 4, dataLength: count * channels * 4, destination: $0.baseAddress!) == noErr
        }
        guard ok else { return out }
        if let b = limitAndEmit(frames: count) { out.append(b) }
        return out
    }

    /// Pushes silence through until the output is `length` frames long: the limiters' delayed tails, then
    /// silence if the mix ended early. Call once at the end.
    func finish() -> [CMSampleBuffer] {
        silence(length - outputFrames + skip)
    }

    private func silence(_ frames: Int) -> [CMSampleBuffer] {
        var out: [CMSampleBuffer] = []
        var left = frames
        while left > 0, !isComplete {
            let n = min(left, Self.chunk)
            if scratch.count < n * channels { scratch = [Float](repeating: 0, count: n * channels) }
            for i in 0..<(n * channels) { scratch[i] = 0 }
            if let b = limitAndEmit(frames: n) { out.append(b) }
            left -= n
        }
        return out
    }

    /// Limits `frames` frames of `scratch` (input at `inputFrame`) and wraps what comes out, cut at `length`.
    private func limitAndEmit(frames: Int) -> CMSampleBuffer? {
        let ch = channels
        inputFrame += frames
        scratch.withUnsafeMutableBufferPointer { p in
            let base = p.baseAddress!
            limiter.process(frames: frames, stride: ch) { base + $0 }
        }
        let drop = min(skip, frames)
        skip -= drop
        let count = min(frames - drop, length - outputFrames)
        guard count > 0 else { return nil }
        let format = format ?? Self.makeFormat(sampleRate: sampleRate, channels: ch)
        guard let format else { return nil }
        let bytes = count * ch * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = scratch.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress! + drop * ch * 4, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) == noErr
        }
        guard copied else { return nil }
        var out: CMSampleBuffer?
        let pts = CMTime(value: CMTimeValue(outputFrames), timescale: CMTimeScale(sampleRate))
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                                                   sampleCount: count, presentationTimeStamp: pts,
                                                                   packetDescriptions: nil, sampleBufferOut: &out) == noErr else { return nil }
        outputFrames += count
        return out
    }

    /// Interleaved Float32 PCM, for silence written before any audio arrived (a mix that delivered nothing).
    private static func makeFormat(sampleRate: Double, channels: Int) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
                                               mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var fd: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        return fd
    }
}
