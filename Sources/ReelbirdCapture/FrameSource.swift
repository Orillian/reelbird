import CoreGraphics
import CoreMedia
import ReelbirdCore

/// The kinds of media a frame source delivers.
public enum MediaKind: String, Sendable, Hashable, CaseIterable {
    case screen, camera, microphone, systemAudio
}

/// What a frame source will deliver, known after `prepare()`.
public struct FrameSourceFormat: Sendable, Hashable {
    public var source: CaptureSource
    /// Pixel size of screen frames.
    public var pixelSize: PixelSize
    /// Pixels per point of the captured display.
    public var scale: Double
    public var frameRate: Int
    public var hasMicrophone: Bool
    public var hasSystemAudio: Bool
    public var hasCamera: Bool
    /// `true`: timestamps are live host-clock times. `false`: virtual timestamps produced as fast as
    /// possible; the recorder then waits for the encoder instead of dropping frames.
    public var isRealTime: Bool

    public init(source: CaptureSource, pixelSize: PixelSize, scale: Double, frameRate: Int,
                hasMicrophone: Bool, hasSystemAudio: Bool, hasCamera: Bool, isRealTime: Bool = true) {
        self.source = source; self.pixelSize = pixelSize; self.scale = scale; self.frameRate = frameRate
        self.hasMicrophone = hasMicrophone; self.hasSystemAudio = hasSystemAudio; self.hasCamera = hasCamera
        self.isRealTime = isRealTime
    }
}

/// Receives media from a `FrameSource`. Called on the source's serial queues (one per media kind);
/// implementations must return quickly and never block capture.
public protocol FrameSourceOutput: AnyObject, Sendable {
    /// A sample buffer whose presentation time is on the host clock.
    /// Screen and camera buffers carry a `CVPixelBuffer`; audio buffers carry LPCM.
    func frameSource(didOutput sampleBuffer: CMSampleBuffer, of kind: MediaKind)
    /// The screen is unchanged (ScreenCaptureKit idle frame). Used for stall detection only.
    func frameSourceScreenIsIdle()
    /// The source stopped on its own (display unplugged, permission revoked, stream error).
    func frameSource(didStopWithError error: any Error)
}

/// Delivers screen frames, system audio, microphone and camera on the host clock.
///
/// `ScreenCaptureKitSource` is the real implementation; `SyntheticFrameSource` generates
/// frames and tones for tests and demos.
public protocol FrameSource: AnyObject, Sendable {
    /// Resolves the source and reports what will be delivered. Called once, before `start`.
    func prepare() async throws -> FrameSourceFormat
    /// Starts delivering to `output`. Returns once capture is running.
    func start(output: any FrameSourceOutput) async throws
    /// Stops delivering. No callbacks arrive after this returns.
    func stop() async
    /// The captured area in global display points (top-left origin), used to normalize pointer
    /// positions. Changes when a captured window moves. `nil` when not on a real display.
    func capturedArea() -> CGRect?
    /// A simulated pointer position (synthetic sources). Real sources return `nil` and the
    /// recorder samples the system pointer instead.
    func simulatedPointer(atHostTime t: Double) -> NormPoint?
}

extension FrameSource {
    public func capturedArea() -> CGRect? { nil }
    public func simulatedPointer(atHostTime t: Double) -> NormPoint? { nil }
}
