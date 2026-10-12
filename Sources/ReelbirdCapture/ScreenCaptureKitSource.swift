import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ReelbirdCore
import ScreenCaptureKit
import Synchronization

/// The real frame source: one `SCStream` delivering the screen (420v, native pixels, cursor hidden,
/// our own windows excluded), system audio and the microphone on the host clock, plus an
/// `AVCaptureSession` for the camera when one is selected.
public final class ScreenCaptureKitSource: NSObject, FrameSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let options: RecordingOptions
    private let videoQueue = DispatchQueue(label: "reelbird.sck.screen", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "reelbird.sck.audio", qos: .userInteractive)
    private let micQueue = DispatchQueue(label: "reelbird.sck.mic", qos: .userInteractive)

    private struct State {
        var filter: SCContentFilter?
        var config: SCStreamConfiguration?
        var stream: SCStream?
        var output: (any FrameSourceOutput)?
        var area: CGRect?
        var windowID: CGWindowID?
        var windowFrameCheckedAt = 0.0
        var displayID: CGDirectDisplayID?
        var areaOffset: CGRect?
    }
    private let state = Locked(State())
    private var camera: CameraCapture?

    public init(options: RecordingOptions) {
        self.options = options
        super.init()
    }

    public func prepare() async throws -> FrameSourceFormat {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.permissionDenied(.screen)
        }
        let config = SCStreamConfiguration()
        let filter: SCContentFilter
        var area: CGRect
        var windowID: CGWindowID?
        var displayID: CGDirectDisplayID?
        var areaOffset: CGRect?
        switch options.source {
        case .display(let id, let name):
            guard let d = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.sourceNotFound(name) }
            filter = SCContentFilter(display: d, excludingApplications: CaptureSources.ownApps(content), exceptingWindows: [])
            area = CGDisplayBounds(id)
            displayID = id
        case .window(let id, let app, let title):
            guard let w = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.sourceNotFound("the \(app) window “\(title)”") }
            filter = SCContentFilter(desktopIndependentWindow: w)
            area = w.frame
            windowID = id
            config.ignoreShadowsSingleWindow = true
        case .area(let id, let x, let y, let w, let h):
            guard let d = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.sourceNotFound("the display") }
            filter = SCContentFilter(display: d, excludingApplications: CaptureSources.ownApps(content), exceptingWindows: [])
            let bounds = CGDisplayBounds(id)
            area = CGRect(x: x, y: y, width: w, height: h)
            // sourceRect is in the display's own point space (top-left origin).
            let local = CGRect(x: x - bounds.minX, y: y - bounds.minY, width: w, height: h)
                .intersection(CGRect(origin: .zero, size: bounds.size))
            guard !local.isEmpty else { throw CaptureError.sourceNotFound("the selected area on that display") }
            config.sourceRect = local
            area = local.offsetBy(dx: bounds.minX, dy: bounds.minY)
            areaOffset = local
            displayID = id
        case .synthetic:
            throw CaptureError.unsupportedSource
        }

        let scale = Double(filter.pointPixelScale)
        let size = PixelSize(width: even(area.width * scale), height: even(area.height * scale))
        config.width = size.width
        config.height = size.height
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, options.frameRate)))
        config.queueDepth = 6
        config.showsCursor = false
        config.captureResolution = .best
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.capturesAudio = options.captureSystemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        var hasMic = false
        if let mic = options.microphoneID {
            guard Permissions.status(.microphone) == .granted else { throw CaptureError.permissionDenied(.microphone) }
            config.captureMicrophone = true
            if mic != "default" { config.microphoneCaptureDeviceID = mic }
            hasMic = true
        }
        if let cameraID = options.cameraID {
            guard Permissions.status(.camera) == .granted else { throw CaptureError.permissionDenied(.camera) }
            camera = try CameraCapture(deviceID: cameraID)
        }
        state.withLock { s in
            s.filter = filter; s.config = config; s.area = area; s.windowID = windowID
            s.displayID = displayID; s.areaOffset = areaOffset
        }
        return FrameSourceFormat(source: options.source, pixelSize: size, scale: scale, frameRate: options.frameRate,
                                 hasMicrophone: hasMic, hasSystemAudio: options.captureSystemAudio,
                                 hasCamera: camera != nil, isRealTime: true)
    }

    public func start(output: any FrameSourceOutput) async throws {
        guard let (filter, config) = state.withLock({ s in s.filter.flatMap { f in s.config.map { (f, $0) } } }) else {
            throw CaptureError.notRecording
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if config.capturesAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
        if config.captureMicrophone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue) }
        state.withLock { $0.stream = stream; $0.output = output }
        do {
            try await stream.startCapture()
        } catch {
            state.withLock { $0.stream = nil; $0.output = nil }
            throw error
        }
        camera?.start(output: output)
    }

    public func stop() async {
        let stream = state.withLock { s -> SCStream? in defer { s.stream = nil }; return s.stream }
        try? await stream?.stopCapture()
        camera?.stop()
        state.withLock { $0.output = nil }
        for q in [videoQueue, audioQueue, micQueue] { await withCheckedContinuation { c in q.async { c.resume() } } }
    }

    public func capturedArea() -> CGRect? {
        let now = HostClock.now()
        return state.withLock { s -> CGRect? in
            if let id = s.displayID {
                // Re-read every time: display arrangement and modes can change mid-recording.
                let bounds = CGDisplayBounds(id)
                if let local = s.areaOffset { return local.offsetBy(dx: bounds.minX, dy: bounds.minY) }
                return bounds
            }
            if let id = s.windowID, now - s.windowFrameCheckedAt > 0.25 {
                s.windowFrameCheckedAt = now
                if let list = CGWindowListCreateDescriptionFromArray([NSNumber(value: id)] as CFArray) as? [[String: Any]],
                   let b = list.first?[kCGWindowBounds as String] as! CFDictionary?,
                   let rect = CGRect(dictionaryRepresentation: b) {
                    s.area = rect
                }
            }
            return s.area
        }
    }

    // MARK: SCStreamOutput / SCStreamDelegate

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, let output = state.withLock({ $0.output }) else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
            switch status {
            case .complete: output.frameSource(didOutput: sampleBuffer, of: .screen)
            case .idle: output.frameSourceScreenIsIdle()
            default: break
            }
        case .audio:
            output.frameSource(didOutput: sampleBuffer, of: .systemAudio)
        case .microphone:
            output.frameSource(didOutput: sampleBuffer, of: .microphone)
        @unknown default:
            break
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let output = state.withLock { s -> (any FrameSourceOutput)? in defer { s.output = nil }; return s.output }
        output?.frameSource(didStopWithError: error)
    }
}

/// Camera frames from an `AVCaptureSession`, retimed onto the host clock.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "reelbird.camera", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let output = Mutex<(any FrameSourceOutput)?>(nil)

    init(deviceID: String) throws {
        guard let device = Devices.device(deviceID, type: .video) else { throw CaptureError.sourceNotFound("the camera") }
        let input = try AVCaptureDeviceInput(device: device)
        super.init()
        session.beginConfiguration()
        session.sessionPreset = .high
        guard session.canAddInput(input) else { throw CaptureError.sourceNotFound("the camera") }
        session.addInput(input)
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(videoOutput) else { throw CaptureError.sourceNotFound("the camera output") }
        session.addOutput(videoOutput)
        session.commitConfiguration()
    }

    func start(output: any FrameSourceOutput) {
        self.output.withLock { $0 = output }
        queue.async { self.session.startRunning() }
    }

    func stop() {
        output.withLock { $0 = nil }
        queue.sync { session.stopRunning() }
    }

    func captureOutput(_ captureOutput: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let out = output.withLock({ $0 }) else { return }
        let clock = session.synchronizationClock ?? HostClock.clock
        if CFEqual(clock, HostClock.clock) {
            out.frameSource(didOutput: sampleBuffer, of: .camera)
            return
        }
        let host = CMSyncConvertTime(sampleBuffer.presentationTimeStamp, from: clock, to: HostClock.clock)
        var timing = CMSampleTimingInfo(duration: sampleBuffer.duration, presentationTimeStamp: host, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sampleBuffer, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &copy)
        if let copy { out.frameSource(didOutput: copy, of: .camera) }
    }
}
