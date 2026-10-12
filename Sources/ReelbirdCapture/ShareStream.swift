import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import Metal
import ReelbirdCore
import Synchronization

/// Hands share segments to the `ShareSegmentSink` strictly in order from one task:
/// `begin` → `initSegment` → `mediaSegment`* → `finish` (or `cancel`). Never blocks capture.
final class SharePump: @unchecked Sendable {
    private enum Event: Sendable {
        case segment(SegmentOutput)
        case finish(total: Double, timeout: Double)
    }

    let sink: any ShareSegmentSink
    private let continuation: AsyncStream<Event>.Continuation
    private let task: Task<Void, Never>

    init(sink: any ShareSegmentSink, recordingID: String, title: String,
         onBegin: @escaping @Sendable (Result<ShareInfo, any Error>) -> Void) {
        self.sink = sink
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        task = Task {
            var began = false
            do {
                let info = try await sink.begin(recordingID: recordingID, title: title)
                began = true
                onBegin(.success(info))
            } catch {
                onBegin(.failure(error))
            }
            for await event in stream {
                guard began, !Task.isCancelled else { continue }
                switch event {
                case .segment(let s):
                    if s.kind == .initialization {
                        await sink.initSegment(s.data)
                    } else {
                        await sink.mediaSegment(index: s.index, data: s.data, duration: s.duration)
                    }
                case .finish(let total, let timeout):
                    await sink.finish(totalDuration: total, timeout: timeout)
                    return
                }
            }
        }
    }

    func send(_ segment: SegmentOutput) { continuation.yield(.segment(segment)) }

    /// Queues `finish` after the last segment and waits for it, at most `timeout` + 0.5 s.
    func finish(totalDuration: Double, timeout: Double) async {
        continuation.yield(.finish(total: totalDuration, timeout: timeout))
        continuation.finish()
        await race(task, timeout: timeout + 0.5)
    }

    /// Discard: stops delivering and asks the sink to delete what it uploaded.
    func cancel() async {
        continuation.finish()
        task.cancel()
        await sink.cancel()
    }

    /// Crash simulation: stop delivering without telling the sink anything.
    func abandon() {
        continuation.finish()
        task.cancel()
    }

    private func race(_ task: Task<Void, Never>, timeout: Double) async {
        let done = Mutex(false)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resume: @Sendable () -> Void = {
                if done.withLock({ d in defer { d = true }; return !d }) { c.resume() }
            }
            Task { await task.value; resume() }
            Task { try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9)); resume() }
        }
    }
}

/// Composites the quick-share video: screen scaled to ≤1920 wide plus a circular camera bubble,
/// rendered with Core Image on a Metal-backed context into a pixel buffer pool, at 30 fps.
final class ShareComposer: @unchecked Sendable {
    let writer: SegmentedWriter
    let size: PixelSize
    let layout: CameraLayout
    private let context: CIContext
    private var pool: CVPixelBufferPool?
    private let queue = DispatchQueue(label: "reelbird.share.compose", qos: .userInitiated)
    private struct Latest { var screen: CVPixelBuffer?; var camera: CVPixelBuffer? }
    private let latest = Locked(Latest())
    private var timer: (any DispatchSourceTimer)?
    private var nextTime = 0.0
    private let interval = 1.0 / 30
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private(set) var framesRendered = 0
    private(set) var framesSkipped = 0

    init(writer: SegmentedWriter, size: PixelSize, layout: CameraLayout = CameraLayout()) {
        self.writer = writer
        self.size = size
        self.layout = layout
        let options: [CIContextOption: Any] = [.workingColorSpace: colorSpace, .cacheIntermediates: false, .name: "reelbird.share"]
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options)
        }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary, attrs as CFDictionary, &pool)
    }

    func update(screen pb: CVPixelBuffer) { latest.withLock { $0.screen = pb } }
    func update(camera pb: CVPixelBuffer) { latest.withLock { $0.camera = pb } }

    /// Real time: renders the first frame at t = 0 now, then every 1/30 s on a timer. Ticks inside
    /// paused ranges are skipped.
    func startTimer(origin: Double, isPaused: @escaping @Sendable (Double) -> Bool) {
        queue.async { self.render(at: 0) }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = HostClock.now() - origin
            guard !isPaused(now) else { return }
            self.render(at: now)
        }
        t.resume()
        timer = t
    }

    /// Offline: called with each screen frame time; renders when the next 30 fps slot is due.
    func tick(at t: Double) {
        guard t + 1e-6 >= nextTime else { return }
        queue.sync { render(at: t) }
    }

    /// Restarts the video right at a resume point (the timer's next tick could be up to 1/30 s later).
    func resume(at t: Double) { queue.async { self.render(at: t) } }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {}
    }

    private func render(at t: Double) {
        guard t + 1e-6 >= nextTime || t == 0 else { return }
        let (screen, camera) = latest.withLock { ($0.screen, $0.camera) }
        guard let screen, let pool else { return }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { framesSkipped += 1; return }
        let image = compose(screen: screen, camera: camera)
        context.render(image, to: out, bounds: CGRect(x: 0, y: 0, width: size.width, height: size.height), colorSpace: colorSpace)
        if writer.append(pixelBuffer: out, at: t) == .appended { framesRendered += 1 } else { framesSkipped += 1 }
        nextTime = max(nextTime + interval, t + interval * 0.5)
    }

    func compose(screen: CVPixelBuffer, camera: CVPixelBuffer?) -> CIImage {
        let W = Double(size.width), H = Double(size.height)
        var img = CIImage(cvPixelBuffer: screen)
        let ext = img.extent
        let s = min(W / ext.width, H / ext.height)
        if abs(s - 1) > 1e-3 {
            let f = CIFilter.lanczosScaleTransform()
            f.inputImage = img
            f.scale = Float(s)
            f.aspectRatio = 1
            img = f.outputImage ?? img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        let dx = (W - img.extent.width) / 2 - img.extent.minX, dy = (H - img.extent.height) / 2 - img.extent.minY
        img = img.transformed(by: CGAffineTransform(translationX: dx, y: dy))
            .composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: W, height: H)))
        guard let camera, layout.visible else { return img.cropped(to: CGRect(x: 0, y: 0, width: W, height: H)) }

        let d = layout.size * min(W, H)
        let inset = layout.inset * min(W, H)
        var cam = CIImage(cvPixelBuffer: camera)
        let ce = cam.extent
        let side = min(ce.width, ce.height)
        cam = cam.cropped(to: CGRect(x: ce.midX - side / 2, y: ce.midY - side / 2, width: side, height: side))
        var t = CGAffineTransform(translationX: -cam.extent.minX, y: -cam.extent.minY)
        if layout.mirror { t = t.concatenating(CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -side, y: 0)) }
        t = t.concatenating(CGAffineTransform(scaleX: d / side, y: d / side))
        // Core Image's origin is bottom-left.
        let x = (layout.corner == .topLeft || layout.corner == .bottomLeft) ? inset : W - inset - d
        let y = (layout.corner == .bottomLeft || layout.corner == .bottomRight) ? inset : H - inset - d
        t = t.concatenating(CGAffineTransform(translationX: x, y: y))
        cam = cam.transformed(by: t)
        let mask = CIFilter.radialGradient()
        mask.center = CGPoint(x: x + d / 2, y: y + d / 2)
        mask.radius0 = Float(d / 2 - 1.5)
        mask.radius1 = Float(d / 2)
        mask.color0 = .white
        mask.color1 = .clear
        let blend = CIFilter.blendWithAlphaMask()
        blend.inputImage = cam
        blend.backgroundImage = img
        blend.maskImage = mask.outputImage
        return (blend.outputImage ?? img).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
    }
}
