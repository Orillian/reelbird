import AppKit
@preconcurrency import AVFoundation
import Metal
import QuartzCore
import ReelbirdCore

/// Plays the edited recording in the editor: hardware decode via `AVPlayer` (screen + mixed audio, plus a
/// muted, host-clock-synced player for the camera), composited by the same Metal compositor as export into a
/// `CAMetalLayer` at display refresh. The render loop runs on its own thread with a `CAMetalDisplayLink`, so a
/// busy main thread never drops preview frames; when paused and idle it sleeps.
///
/// Call everything from the main thread. `update(edit:)` re-plans and redraws immediately; when trim/cuts
/// change, the player items are rebuilt and the playhead keeps its place in the recording.
public final class PreviewPlayer: @unchecked Sendable {
    public let bundle: ProjectBundle
    public let manifest: ProjectManifest
    /// Called on the main actor about 30× a second while playing, and after seeks and edits.
    public var onTimeChange: (@MainActor (Double) -> Void)?
    /// Called once media is loaded and the first frame can show, or with the error that stopped it.
    public var onReady: (@MainActor ((any Error)?) -> Void)?

    private var events: [InputEvent] = []
    private let state: SharedState
    private let loop: RenderLoop
    private var sources: MediaSources?
    private var mainPlayer = AVPlayer()
    private var cameraPlayer: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: (any NSObjectProtocol)?
    private var seekInFlight = false
    private var pendingSeek: Double?
    private var loadTask: Task<Void, Never>?
    private var previewView: PreviewView?
    private var audioTracks: [(TrackKind, AVMutableCompositionTrack)] = []

    /// Opens a bundle for preview. Media loads in the background (`onReady` fires when done).
    public init(bundle: ProjectBundle) throws {
        self.bundle = bundle
        manifest = try bundle.readManifest()
        // The plan starts without events (instant); the event log loads off the main thread below.
        let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: try bundle.readEdit(), events: [], reusing: nil)
        let ctx = try MetalContext.shared()
        state = SharedState(plan: plan)
        loop = try RenderLoop(context: ctx, state: state)
        mainPlayer.automaticallyWaitsToMinimizeStalling = false
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let manifest = self.manifest
                async let loadedEvents = Task.detached(priority: .userInitiated) { try bundle.readEvents() }.value
                let s = try await MediaSources.load(bundle: bundle, manifest: manifest)
                let ev = try await loadedEvents
                self.events = ev
                let current = self.state.plan
                self.state.plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: current.edit, events: ev, reusing: nil)
                guard s.screen != nil else { throw RenderError.missingScreenTrack }
                self.sources = s
                try self.rebuildItems(keepingSourceTime: nil)
                self.onReady?(nil)
            } catch {
                self.onReady?(error)
            }
        }
    }

    deinit {
        loadTask?.cancel()
        if let timeObserver { mainPlayer.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        mainPlayer.pause()
        cameraPlayer?.pause()
        loop.stop()
    }

    /// The preview surface (a layer-backed `NSView`). Host it in SwiftUI with an `NSViewRepresentable`.
    public var view: NSView {
        MainActor.assumeIsolated {
            if let v = previewView { return v }
            let v = PreviewView(loop: loop)
            previewView = v
            return v
        }
    }

    /// The plan currently drawn (useful for the editor's timeline: regions, duration, canvas size).
    public var plan: RenderPlan { state.plan }

    /// Output duration in seconds.
    public var duration: Double { state.plan.duration }

    /// Playhead in output seconds.
    public var currentTime: Double {
        state.isPlaying ? max(0, mainPlayer.currentTime().seconds.finiteOr(state.pausedTime)) : state.pausedTime
    }

    public var isPlaying: Bool { state.isPlaying }

    /// Applies a new edit: re-plans (cached paths are reused when their inputs didn't change) and redraws.
    @MainActor
    public func update(edit: EditDocument) {
        let old = state.plan
        guard let plan = try? RenderPlan(bundle: bundle, manifest: manifest, edit: edit, events: events, reusing: old) else { return }
        let sourceTime = old.timeline.sourceTime(forOutput: currentTime)
        state.plan = plan
        if plan.timeline != old.timeline || plan.showsCamera != old.showsCamera {
            try? rebuildItems(keepingSourceTime: sourceTime)
        } else if plan.edit.audio != old.edit.audio {
            mainPlayer.currentItem?.audioMix = audioMix(for: plan)
        }
        loop.wake()
        notifyTime()
    }

    @MainActor
    public func play() {
        guard !state.isPlaying, let item = mainPlayer.currentItem else { return }
        var start = state.pausedTime
        if start >= duration - 0.02 { start = 0; state.pausedTime = 0 }
        state.isPlaying = true
        let t = MediaSources.time(start)
        let cameraReady = cameraPlayer?.currentItem?.status ?? .readyToPlay
        if item.status == .readyToPlay, cameraReady == .readyToPlay {
            // Start both players on the same host time so camera and screen stay in sync.
            let host = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(value: 1, timescale: 30))
            mainPlayer.setRate(1, time: t, atHostTime: host)
            cameraPlayer?.setRate(1, time: t, atHostTime: host)
        } else {
            mainPlayer.play()
            cameraPlayer?.play()
        }
        loop.wake()
    }

    @MainActor
    public func pause() {
        guard state.isPlaying else { return }
        mainPlayer.pause()
        cameraPlayer?.pause()
        state.isPlaying = false
        let t = mainPlayer.currentTime().seconds.finiteOr(state.pausedTime)
        state.pausedTime = min(max(0, t), duration)
        cameraPlayer?.seek(to: MediaSources.time(state.pausedTime), toleranceBefore: .zero, toleranceAfter: .zero)
        loop.wake()
        notifyTime()
    }

    /// Moves the playhead (output seconds). Rapid calls (scrubbing) coalesce: only the latest target is decoded.
    @MainActor
    public func seek(to outputTime: Double) {
        let t = min(max(0, outputTime), duration)
        if state.isPlaying {
            mainPlayer.pause(); cameraPlayer?.pause()
            state.isPlaying = false
        }
        state.pausedTime = t
        chaseSeek(t)
        loop.wake()
        notifyTime()
    }

    // MARK: - Internals

    @MainActor
    private func chaseSeek(_ t: Double) {
        if seekInFlight { pendingSeek = t; return }
        seekInFlight = true
        let time = MediaSources.time(t)
        cameraPlayer?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        mainPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                MainActor.assumeIsolated {
                self.seekInFlight = false
                self.loop.wake()
                if let p = self.pendingSeek { self.pendingSeek = nil; self.chaseSeek(p) }
                }
            }
        }
    }

    @MainActor
    private func notifyTime() {
        onTimeChange?(currentTime)
    }

    @MainActor
    private func audioMix(for plan: RenderPlan) -> AVAudioMix? {
        guard !audioTracks.isEmpty else { return nil }
        let a = plan.edit.audio
        let mix = AVMutableAudioMix()
        mix.inputParameters = audioTracks.map { kind, track in
            let muted = kind == .microphone ? a.microphoneMuted : a.systemMuted
            let db = kind == .microphone ? a.microphoneGainDB : a.systemGainDB
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(muted ? 0 : Float(min(1, pow(10, db / 20))), at: .zero)
            return p
        }
        return mix
    }

    /// (Re)creates the player items for the current plan's timeline.
    @MainActor
    private func rebuildItems(keepingSourceTime: Double?) throws {
        guard let sources else { return }
        let plan = state.plan
        if state.isPlaying { mainPlayer.pause(); cameraPlayer?.pause(); state.isPlaying = false }
        let comp = try sources.composition(timeline: plan.timeline, camera: false, audio: AudioSettings())
        audioTracks = comp.audio.map { ($0.kind, $0.track) }
        let item = AVPlayerItem(asset: comp.asset)
        let attrs = MediaSources.decodeSettings
        let screenOut = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        screenOut.suppressesPlayerRendering = true
        item.add(screenOut)
        sources.applySDRConversion(kind: .screen, to: item, asset: comp.asset)
        mainPlayer.replaceCurrentItem(with: item)
        item.audioMix = audioMix(for: plan)

        var cameraOut: AVPlayerItemVideoOutput?
        if plan.showsCamera, sources.camera != nil {
            let cc = try sources.composition(timeline: plan.timeline, video: false, camera: true, audio: nil)
            let citem = AVPlayerItem(asset: cc.asset)
            let out = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
            out.suppressesPlayerRendering = true
            citem.add(out)
            sources.applySDRConversion(kind: .camera, to: citem, asset: cc.asset)
            let p = cameraPlayer ?? AVPlayer()
            p.automaticallyWaitsToMinimizeStalling = false
            p.isMuted = true
            p.replaceCurrentItem(with: citem)
            cameraPlayer = p
            cameraOut = out
        } else {
            cameraPlayer?.replaceCurrentItem(with: nil)
            cameraPlayer = nil
        }
        state.setOutputs(screen: screenOut, camera: cameraOut)

        if timeObserver == nil {
            timeObserver = mainPlayer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] _ in
                guard let self, self.state.isPlaying else { return }
                MainActor.assumeIsolated { self.notifyTime() }
            }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.state.isPlaying = false
                self.cameraPlayer?.pause()
                self.state.pausedTime = self.duration
                self.loop.wake()
                self.notifyTime()
            }
        }
        let target = keepingSourceTime.map { plan.timeline.outputTime(forSource: $0) ?? nearestOutput(plan, $0) } ?? state.pausedTime
        state.pausedTime = min(max(0, target), plan.duration)
        seekInFlight = false
        pendingSeek = nil
        chaseSeek(state.pausedTime)
    }

    private func nearestOutput(_ plan: RenderPlan, _ source: Double) -> Double {
        var acc = 0.0
        for r in plan.timeline.kept {
            if source < r.start { return acc }
            acc += r.duration
        }
        return plan.duration
    }

    /// Renders the frame the preview would show now into an image (tests, debugging).
    func snapshot(width: Int) -> CGImage? { loop.snapshot(width: width) }

    /// Frames presented on screen so far (diagnostics).
    var presentedFrames: Int { loop.presented.value }

    /// Whether a decoded screen frame is available for the current paused time.
    func hasFrame() -> Bool { loop.refreshFrames(hostTime: CACurrentMediaTime()); return state.lastScreen != nil }
}

/// State shared between the main thread and the render thread.
final class SharedState: @unchecked Sendable {
    private let lock = NSLock()
    private var _plan: RenderPlan
    private var _playing = false
    private var _paused = 0.0
    private var _dirty = true
    private var _screenOut: AVPlayerItemVideoOutput?
    private var _cameraOut: AVPlayerItemVideoOutput?
    /// Render-thread only.
    var lastScreen: CVPixelBuffer?
    var lastCamera: CVPixelBuffer?

    init(plan: RenderPlan) { _plan = plan }

    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }
    var plan: RenderPlan { get { locked { _plan } } set { locked { _plan = newValue; _dirty = true } } }
    var isPlaying: Bool { get { locked { _playing } } set { locked { _playing = newValue; _dirty = true } } }
    var pausedTime: Double { get { locked { _paused } } set { locked { _paused = newValue; _dirty = true } } }
    func takeDirty() -> Bool { locked { let d = _dirty; _dirty = false; return d } }
    func markDirty() { locked { _dirty = true } }
    func setOutputs(screen: AVPlayerItemVideoOutput?, camera: AVPlayerItemVideoOutput?) {
        locked { _screenOut = screen; _cameraOut = camera; _dirty = true }
    }
    var outputs: (AVPlayerItemVideoOutput?, AVPlayerItemVideoOutput?) { locked { (_screenOut, _cameraOut) } }
}

/// The render thread: a run loop driving a `CAMetalDisplayLink`, plus on-demand redraws.
final class RenderLoop: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    let layer = CAMetalLayer()
    private let ctx: MetalContext
    private let state: SharedState
    private let queue: any MTLCommandQueue
    private let compositor: Compositor
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var link: CAMetalDisplayLink?
    private let started = DispatchSemaphore(value: 0)
    private var idleFrames = 0
    private let inflight = DispatchSemaphore(value: 3)
    private let sizeLock = NSLock()
    private var _drawableSize = CGSize.zero
    /// Frames presented by the display link (diagnostics).
    let presented = Counter()

    init(context: MetalContext, state: SharedState) throws {
        ctx = context
        self.state = state
        guard let q = context.device.makeCommandQueue() else { throw RenderError.metalUnavailable }
        queue = q
        compositor = Compositor(context: context, queue: q)
        super.init()
        layer.device = context.device
        layer.pixelFormat = MetalContext.pixelFormat
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.maximumDrawableCount = 3
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        let t = Thread { [weak self] in self?.threadMain() }
        t.name = "Reelbird preview render"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        started.wait()
    }

    var drawableSize: CGSize {
        get { sizeLock.lock(); defer { sizeLock.unlock() }; return _drawableSize }
        set { sizeLock.lock(); _drawableSize = newValue; sizeLock.unlock() }
    }

    private func threadMain() {
        runLoop = CFRunLoopGetCurrent()
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.delegate = self
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.preferredFrameLatency = 1
        link.add(to: .current, forMode: .default)
        self.link = link
        started.signal()
        // Keep the run loop alive even when the link is paused.
        let port = Port()
        RunLoop.current.add(port, forMode: .default)
        while !Thread.current.isCancelled { _ = RunLoop.current.run(mode: .default, before: .distantFuture) }
        link.invalidate()
    }

    func stop() {
        guard let rl = runLoop, let thread else { return }
        thread.cancel()
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) {}
        CFRunLoopWakeUp(rl)
        CFRunLoopStop(rl)
        self.thread = nil
    }

    /// Resumes the display link (after a seek, edit or play).
    func wake() {
        state.markDirty()
        guard let rl = runLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            guard let self else { return }
            self.idleFrames = 0
            self.link?.isPaused = false
        }
        CFRunLoopWakeUp(rl)
    }

    /// Pulls new decoded frames for the given host time. Returns whether anything changed.
    @discardableResult
    func refreshFrames(hostTime: CFTimeInterval) -> Bool {
        let (screenOut, cameraOut) = state.outputs
        var changed = false
        if let o = screenOut {
            let t = o.itemTime(forHostTime: hostTime)
            if o.hasNewPixelBuffer(forItemTime: t), let pb = o.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
                state.lastScreen = pb; changed = true
            }
        }
        if let o = cameraOut {
            let t = o.itemTime(forHostTime: hostTime)
            if o.hasNewPixelBuffer(forItemTime: t), let pb = o.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
                state.lastCamera = pb; changed = true
            }
        } else if state.lastCamera != nil {
            state.lastCamera = nil; changed = true
        }
        return changed
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        let host = update.targetPresentationTimestamp
        let newFrames = refreshFrames(hostTime: host)
        let dirty = state.takeDirty()
        let playing = state.isPlaying
        guard playing || newFrames || dirty else {
            idleFrames += 1
            // Paused and nothing changing: sleep until woken (keep polling briefly for late seek frames).
            if idleFrames > 30 { link.isPaused = true }
            return
        }
        idleFrames = 0
        let plan = state.plan
        var t = state.pausedTime
        if playing, let o = state.outputs.0 {
            let it = o.itemTime(forHostTime: host).seconds
            if it.isFinite { t = min(max(0, it), plan.duration) }
        }
        render(plan: plan, time: t, drawable: update.drawable)
    }

    private func render(plan: RenderPlan, time: Double, drawable: any CAMetalDrawable) {
        let target = drawable.texture
        guard target.width > 1, target.height > 1 else { return }
        inflight.wait()
        guard let cb = queue.makeCommandBuffer() else { inflight.signal(); return }
        // Letterbox the canvas inside the drawable.
        let canvas = plan.canvasSize
        let tw = Double(target.width), th = Double(target.height)
        let s = min(tw / Double(canvas.width), th / Double(canvas.height))
        let w = (Double(canvas.width) * s).rounded(), h = (Double(canvas.height) * s).rounded()
        let vp = CGRect(x: ((tw - w) / 2).rounded(), y: ((th - h) / 2).rounded(), width: w, height: h)
        let keep = compositor.encode(plan: plan, outputTime: time, screen: state.lastScreen, camera: state.lastCamera,
                                     target: target, viewport: vp, frameInterval: 1.0 / 60, commandBuffer: cb)
        let sema = inflight
        let held = Unchecked((keep, state.lastScreen, state.lastCamera))
        cb.addCompletedHandler { _ in _ = held; sema.signal() }
        cb.present(drawable)
        cb.commit()
        presented.increment()
    }

    /// Offscreen render of the current state (tests).
    func snapshot(width: Int) -> CGImage? {
        let plan = state.plan
        let canvas = plan.canvasSize
        let h = max(2, Int(Double(width) * Double(canvas.height) / Double(canvas.width)) / 2 * 2)
        guard let pool = try? makePool(width: width, height: h) else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out, let tex = ctx.texture(out, plane: 0, format: .bgra8Unorm, renderTarget: true),
              let target = CVMetalTextureGetTexture(tex), let cb = queue.makeCommandBuffer() else { return nil }
        let keep = compositor.encode(plan: plan, outputTime: state.pausedTime, screen: state.lastScreen, camera: state.lastCamera,
                                     target: target, frameInterval: 1.0 / 60, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        withExtendedLifetime((keep, tex)) {}
        return cgImage(from: out)
    }
}

/// The layer-hosting view. Keeps the drawable at the view's pixel size.
final class PreviewView: NSView {
    private let loop: RenderLoop

    init(loop: RenderLoop) {
        self.loop = loop
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer { loop.layer }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        loop.layer.contentsScale = scale
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        if loop.layer.drawableSize != size {
            loop.layer.drawableSize = size
            loop.drawableSize = size
            loop.wake()
        }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

extension Double {
    func finiteOr(_ fallback: Double) -> Double { isFinite ? self : fallback }
}
