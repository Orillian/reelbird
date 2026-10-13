import AVFoundation
import CoreMedia
import Foundation

enum AudioPCM {
    static let sampleRate = 48_000

    static func floatFormat(channels: Int, rate: Double, interleaved: Bool) -> CMAudioFormatDescription? {
        var flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        if !interleaved { flags |= kAudioFormatFlagIsNonInterleaved }
        let bytesPerFrame = UInt32(interleaved ? 4 * channels : 4)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        var f: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: MemoryLayout<AudioChannelLayout>.size,
                                       layout: &layout, magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &f)
        return f
    }

    /// Converts a level in linear RMS to a 0...1 meter value (-60 dBFS ... 0 dBFS).
    static func meter(rms: Float) -> Double {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(Double(rms))
        return min(1, max(0, (db + 60) / 60))
    }
}

/// Builds interleaved Float32 LPCM sample buffers from a reusable memory pool (no malloc per buffer).
final class PCMBufferFactory: @unchecked Sendable {
    let channels: Int
    private let format: CMAudioFormatDescription
    private let pool = CMMemoryPoolCreate(options: nil)
    private let allocator: CFAllocator

    init(channels: Int) {
        self.channels = channels
        format = AudioPCM.floatFormat(channels: channels, rate: Double(AudioPCM.sampleRate), interleaved: true)!
        allocator = CMMemoryPoolGetAllocator(pool)
    }

    deinit { CMMemoryPoolInvalidate(pool) }

    /// `samples == nil` makes silence.
    func make(frame: Int64, samples: UnsafePointer<Float>?, frames: Int) -> CMSampleBuffer? {
        let bytes = frames * channels * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: allocator,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        var ptr: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &ptr)
        guard let ptr else { return nil }
        if let samples { UnsafeMutableRawPointer(ptr).copyMemory(from: samples, byteCount: bytes) } else { memset(ptr, 0, bytes) }
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: CMTime(value: frame, timescale: CMTimeScale(AudioPCM.sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }
}

/// Converts any LPCM sample buffer to interleaved Float32 at 48 kHz with a fixed channel count.
/// Float32/Int16/Int32 at 48 kHz take a copy loop; other rates go through `AVAudioConverter`.
final class PCMNormalizer: @unchecked Sendable {
    let channels: Int
    private(set) var output: UnsafeMutablePointer<Float>
    private var capacity: Int
    private var ablStorage: UnsafeMutableRawPointer
    private var ablSize = 512
    private var converter: AVAudioConverter?
    private var converterKey: [UInt32] = []

    init(channels: Int) {
        self.channels = channels
        capacity = 48_000 * channels
        output = .allocate(capacity: capacity)
        ablStorage = .allocate(byteCount: ablSize, alignment: 16)
    }

    deinit {
        output.deallocate()
        ablStorage.deallocate()
    }

    private func ensure(frames: Int) {
        let need = frames * channels
        if need > capacity {
            output.deallocate()
            capacity = need
            output = .allocate(capacity: capacity)
        }
    }

    /// Converts `sb` into `output`. Returns the number of frames and the RMS level, or nil for
    /// unsupported or empty buffers.
    func convert(_ sb: CMSampleBuffer) -> (frames: Int, rms: Float)? {
        guard let fd = sb.formatDescription, let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return nil }
        let asbd = asbdPtr.pointee
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0, asbd.mFormatID == kAudioFormatLinearPCM else { return nil }

        var needed = 0
        let flags = kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
                                                                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: flags, blockBufferOut: nil)
        if needed > ablSize {
            ablStorage.deallocate()
            ablSize = needed
            ablStorage = .allocate(byteCount: ablSize, alignment: 16)
        }
        let ablPtr = ablStorage.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: ablPtr, bufferListSize: needed,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: flags, blockBufferOut: &block) == noErr else { return nil }
        let abl = UnsafeMutableAudioBufferListPointer(ablPtr)

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = Int(asbd.mBitsPerChannel)
        let fastPath = Int(asbd.mSampleRate) == AudioPCM.sampleRate && ((isFloat && bits == 32) || (!isFloat && (bits == 16 || bits == 32)))
        let outFrames: Int
        if fastPath {
            ensure(frames: frames)
            copy(abl: abl, asbd: asbd, frames: frames, isFloat: isFloat, bits: bits)
            outFrames = frames
        } else {
            guard let n = convertWithConverter(abl: ablPtr, asbd: asbd, frames: frames) else { return nil }
            outFrames = n
        }
        var sum: Float = 0
        let total = outFrames * channels
        for i in 0..<total { let v = output[i]; sum += v * v }
        return (outFrames, total > 0 ? (sum / Float(total)).squareRoot() : 0)
    }

    private func copy(abl: UnsafeMutableAudioBufferListPointer, asbd: AudioStreamBasicDescription, frames: Int, isFloat: Bool, bits: Int) {
        let inCh = max(1, Int(asbd.mChannelsPerFrame))
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let outCh = channels
        @inline(__always) func sample(_ ch: Int, _ i: Int) -> Float {
            let (buf, idx) = interleaved ? (abl[0], i * inCh + ch) : (abl[min(ch, abl.count - 1)], i)
            guard let d = buf.mData else { return 0 }
            if isFloat { return d.assumingMemoryBound(to: Float.self)[idx] }
            if bits == 16 { return Float(d.assumingMemoryBound(to: Int16.self)[idx]) / 32_768 }
            return Float(d.assumingMemoryBound(to: Int32.self)[idx]) / 2_147_483_648
        }
        for i in 0..<frames {
            if outCh == 1 {
                output[i] = inCh == 1 ? sample(0, i) : (sample(0, i) + sample(1, i)) * 0.5
            } else {
                for c in 0..<outCh { output[i * outCh + c] = sample(c % inCh, i) }
            }
        }
    }

    private func convertWithConverter(abl: UnsafeMutablePointer<AudioBufferList>, asbd: AudioStreamBasicDescription, frames: Int) -> Int? {
        var inASBD = asbd
        let key = [UInt32(asbd.mSampleRate), asbd.mFormatFlags, asbd.mBitsPerChannel, asbd.mChannelsPerFrame]
        guard let inFormat = AVAudioFormat(streamDescription: &inASBD),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioPCM.sampleRate),
                                            channels: AVAudioChannelCount(channels), interleaved: true) else { return nil }
        if converter == nil || key != converterKey {
            converter = AVAudioConverter(from: inFormat, to: outFormat)
            converterKey = key
        }
        guard let converter,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, bufferListNoCopy: abl, deallocator: nil) else { return nil }
        let outCapacity = AVAudioFrameCount(Double(frames) * Double(AudioPCM.sampleRate) / asbd.mSampleRate + 64)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { return nil }
        nonisolated(unsafe) var fed = false
        nonisolated(unsafe) let input = inBuf
        var error: NSError?
        converter.convert(to: outBuf, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let data = outBuf.floatChannelData else { return nil }
        let n = Int(outBuf.frameLength)
        ensure(frames: n)
        output.update(from: data[0], count: n * channels)
        return n
    }
}

/// Feeds one audio track: normalizes buffers, keeps the track continuous on the timeline (silence
/// for gaps, trimming overlaps) and writes silence while paused. AAC in fMP4 can't represent gaps:
/// the writer would close them up and shift everything after, so audio must never have holes.
final class AudioTrackFeed: @unchecked Sendable {
    let writer: SegmentedWriter
    private let normalizer: PCMNormalizer
    private let factory: PCMBufferFactory
    private let lock = NSLock()
    private var nextFrame: Int64 = 0
    private var started = false
    /// Frames of silence inserted or audio dropped to stay aligned (dropouts, clock drift).
    private(set) var correctionFrames: Int64 = 0
    /// Called with every chunk written (timeline frame, interleaved samples, frames, channels). Used by the share mixer.
    var tap: (@Sendable (Int64, UnsafePointer<Float>, Int, Int) -> Void)?
    private let tolerance: Int64 = 480       // 10 ms of jitter is absorbed without correction
    private let maxChunk = 4_800
    /// Gaps longer than this are the source going quiet (ScreenCaptureKit sends no system audio
    /// while nothing plays), not a dropout, and don't count as a correction.
    private let dropoutLimit: Int64 = 24_000
    private var lastIngestHost = 0.0
    private var idlePadded = false

    /// Analyses the raw input (microphone track only), before pause muting.
    let monitor: MicrophoneMonitor?

    init(writer: SegmentedWriter, channels: Int, monitor: MicrophoneMonitor? = nil) {
        self.writer = writer
        self.monitor = monitor
        normalizer = PCMNormalizer(channels: channels)
        factory = PCMBufferFactory(channels: channels)
    }

    var channels: Int { normalizer.channels }
    var writtenSeconds: Double { lock.withLock { Double(nextFrame) / Double(AudioPCM.sampleRate) } }
    var correctionSeconds: Double { lock.withLock { Double(correctionFrames) / Double(AudioPCM.sampleRate) } }

    /// Ingests a host-clock buffer. `origin` = host time of timeline zero. `muted` writes silence (pause).
    /// Returns the input RMS.
    @discardableResult
    func ingest(_ sb: CMSampleBuffer, origin: Double, muted: Bool) -> Float? {
        lock.lock(); defer { lock.unlock() }
        guard let (frames, rms) = normalizer.convert(sb) else { return nil }
        lastIngestHost = HostClock.now()
        monitor?.ingest(normalizer.output, frames: frames, channels: normalizer.channels,
                        at: sb.presentationTimeStamp.seconds, paused: muted)
        let afterIdle = idlePadded
        idlePadded = false
        let rate = Double(AudioPCM.sampleRate)
        var chunkStart = Int64(((sb.presentationTimeStamp.seconds - origin) * rate).rounded())
        var offset = 0
        if chunkStart + Int64(frames) <= 0 { return rms }
        if chunkStart < 0 { offset = Int(-chunkStart); chunkStart = 0 }
        if !started {
            started = true
            writeSilence(frames: chunkStart)   // the track starts at timeline zero like every other track
        }
        let delta = chunkStart - nextFrame
        if delta > tolerance {
            writeSilence(frames: delta)
            if !afterIdle && delta < dropoutLimit { correctionFrames += delta }
        } else if delta < -tolerance {
            offset += Int(-delta)
            correctionFrames += -delta
            if offset >= frames { return rms }
        }
        let n = frames - offset
        let ch = normalizer.channels
        let base = normalizer.output + offset * ch
        if muted { base.update(repeating: 0, count: n * ch) }
        var written = 0
        while written < n {
            let k = min(maxChunk, n - written)
            emit(frame: nextFrame, samples: base + written * ch, frames: k)
            nextFrame += Int64(k)
            written += k
        }
        return rms
    }

    /// Keeps the track growing while the source delivers nothing (system audio while nothing plays,
    /// an unplugged microphone): pads silence up to `time` once no buffer has arrived for `idle`
    /// seconds. Called a few times a second, so silence goes in small steady pieces instead of one
    /// burst on the capture queue when audio comes back, and segments keep closing every 2 s.
    func padIfIdle(upTo time: Double, idle: Double, now: Double) {
        lock.lock(); defer { lock.unlock() }
        guard now - lastIngestHost >= idle else { return }
        let target = Int64(time * Double(AudioPCM.sampleRate))
        guard target > nextFrame else { return }
        writeSilence(frames: target - nextFrame)
        started = true
        idlePadded = true
    }

    /// Pads the track with silence up to `time` (stop while the source delivered nothing).
    func pad(to time: Double) {
        lock.lock(); defer { lock.unlock() }
        let target = Int64(time * Double(AudioPCM.sampleRate))
        if target > nextFrame { writeSilence(frames: target - nextFrame) }
        started = true
    }

    private func writeSilence(frames: Int64) {
        var left = frames
        while left > 0 {
            let k = Int(min(Int64(maxChunk), left))
            emit(frame: nextFrame, samples: nil, frames: k)
            nextFrame += Int64(k)
            left -= Int64(k)
        }
    }

    private func emit(frame: Int64, samples: UnsafePointer<Float>?, frames: Int) {
        guard let sb = factory.make(frame: frame, samples: samples, frames: frames) else { return }
        writer.append(audio: sb)
        if let tap {
            if let samples {
                tap(frame, samples, frames, normalizer.channels)
            } else {
                // Silence still advances the mixer.
                withUnsafeTemporaryAllocation(of: Float.self, capacity: frames * normalizer.channels) { buf in
                    buf.initialize(repeating: 0)
                    tap(frame, UnsafePointer(buf.baseAddress!), frames, normalizer.channels)
                }
            }
        }
    }
}

/// Mixes the microphone and system audio onto one stereo stream aligned by timeline position.
/// Output is emitted once every input has delivered up to a point, or when one input lags more than
/// 0.3 s (it is treated as silent so the share stream keeps flowing).
final class AudioMixer: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity = 1 << 18       // ~5.5 s ring
    private var mask: Int64 { Int64(capacity - 1) }
    private let ring: UnsafeMutablePointer<Float>
    private var high: [Int64]
    private var emitted: Int64 = 0
    private let lag: Int64 = 14_400
    private let scratch: UnsafeMutablePointer<Float>
    private let maxOut = 4_800
    private let output: @Sendable (Int64, UnsafePointer<Float>, Int) -> Void

    init(inputs: Int, output: @escaping @Sendable (Int64, UnsafePointer<Float>, Int) -> Void) {
        ring = .allocate(capacity: capacity * 2)
        ring.initialize(repeating: 0, count: capacity * 2)
        scratch = .allocate(capacity: maxOut * 2)
        high = Array(repeating: 0, count: max(1, inputs))
        self.output = output
    }

    deinit {
        ring.deallocate()
        scratch.deallocate()
    }

    func add(input: Int, frame: Int64, samples: UnsafePointer<Float>, frames: Int, channels: Int) {
        lock.lock(); defer { lock.unlock() }
        guard input < high.count else { return }
        for k in 0..<frames {
            let f = frame + Int64(k)
            if f < emitted { continue }
            if f >= emitted + Int64(capacity) { break }
            let idx = Int(f & mask) * 2
            let l = samples[k * channels]
            let r = channels > 1 ? samples[k * channels + 1] : l
            ring[idx] += l
            ring[idx + 1] += r
        }
        high[input] = max(high[input], frame + Int64(frames))
        let minHigh = high.min() ?? 0, maxHigh = high.max() ?? 0
        emit(upTo: max(minHigh, maxHigh - lag))
    }

    /// Emits everything delivered so far (stop).
    func flush() {
        lock.lock(); defer { lock.unlock() }
        emit(upTo: high.max() ?? 0)
    }

    private func emit(upTo target: Int64) {
        while emitted < target {
            let n = Int(min(Int64(maxOut), target - emitted))
            for k in 0..<n {
                let idx = Int((emitted + Int64(k)) & mask) * 2
                scratch[k * 2] = min(1, max(-1, ring[idx]))
                scratch[k * 2 + 1] = min(1, max(-1, ring[idx + 1]))
                ring[idx] = 0
                ring[idx + 1] = 0
            }
            output(emitted, scratch, n)
            emitted += Int64(n)
        }
    }
}
