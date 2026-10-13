import AppKit
@preconcurrency import AVFoundation
import ReelbirdCapture
import ReelbirdCore
import Synchronization

/// Real input monitoring for the source picker: a microphone meter on the chosen device and a live
/// camera view. Neither prompts for permission; without it the meter stays at zero and the camera
/// view explains what is missing.
@MainActor final class LiveInputPreview: InputPreviewService {
    private var meter: MicrophoneMeter?

    func startMicrophoneMeter(deviceID: String, onLevel: @escaping @MainActor (Double) -> Void) {
        stopMicrophoneMeter()
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { onLevel(0); return }
        meter = MicrophoneMeter(deviceID: deviceID, onLevel: onLevel)
    }

    func stopMicrophoneMeter() {
        meter?.stop()
        meter = nil
    }

    func makeCameraView(deviceID: String) -> NSView {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            return CameraPlaceholderView(message: "Camera access is off")
        }
        do {
            return LiveCameraView(controller: try CameraPreview.makeView(deviceID: deviceID))
        } catch {
            return CameraPlaceholderView(message: "Camera unavailable")
        }
    }
}

/// A small capture session that reports the RMS level of one microphone about 20 times a second.
private final class MicrophoneMeter: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "reelbird.mic.meter", qos: .userInitiated)
    private let onLevel: @MainActor (Double) -> Void
    private let state = Mutex((peak: Float(0), lastSent: 0.0, smoothed: 0.0))

    init(deviceID: String, onLevel: @escaping @MainActor (Double) -> Void) {
        self.onLevel = onLevel
        super.init()
        let resolved = deviceID == MicPolicy.automaticID ? (Devices.resolveMicrophone(deviceID)?.id ?? "default") : deviceID
        let device = resolved == "default" ? AVCaptureDevice.default(for: .audio) : AVCaptureDevice(uniqueID: resolved)
        guard let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        session.addInput(input)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        let session = session
        queue.async { session.startRunning() }
    }

    func stop() {
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var ptr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr,
              let ptr, length >= 4 else { return }
        let count = length / 4
        var sum: Float = 0
        ptr.withMemoryRebound(to: Float.self, capacity: count) { s in
            for i in 0..<count { sum += s[i] * s[i] }
        }
        let rms = (sum / Float(count)).squareRoot()
        let now = CACurrentMediaTime()
        let send: Double? = state.withLock { st in
            st.peak = max(st.peak, rms)
            guard now - st.lastSent >= 0.05 else { return nil }
            let db = st.peak > 0 ? 20 * log10(Double(st.peak)) : -120
            let level = min(1, max(0, (db + 60) / 60))
            // Fast attack, slower release, like a hardware meter.
            st.smoothed = level > st.smoothed ? level : st.smoothed * 0.6 + level * 0.4
            st.peak = 0
            st.lastSent = now
            return st.smoothed
        }
        guard let send else { return }
        let onLevel = onLevel
        DispatchQueue.main.async { MainActor.assumeIsolated { onLevel(send) } }
    }
}

/// Hosts a `CameraPreviewController` and runs its session only while the view is in a window.
private final class LiveCameraView: NSView {
    private let controller: CameraPreviewController

    init(controller: CameraPreviewController) {
        self.controller = controller
        super.init(frame: .zero)
        let v = controller.view
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
            v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { controller.stop() } else { controller.start() }
    }
}

/// Shown in the camera bubble when there is no camera picture to show.
private final class CameraPlaceholderView: NSView {
    private let message: String

    init(message: String) {
        self.message = message
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let config = NSImage.SymbolConfiguration(pointSize: min(bounds.width, bounds.height) * 0.16, weight: .regular)
        let tint = NSColor(white: 1, alpha: 0.7)
        if let img = NSImage(systemSymbolName: "video.slash.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config.applying(.init(paletteColors: [tint]))) {
            let s = img.size
            img.draw(in: NSRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height, width: s.width, height: s.height))
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(10, min(bounds.width, bounds.height) * 0.065), weight: .medium),
            .foregroundColor: tint,
        ]
        let text = NSAttributedString(string: message, attributes: attrs)
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY + 6))
    }
}
