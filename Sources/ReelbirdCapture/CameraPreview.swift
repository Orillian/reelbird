import AppKit
@preconcurrency import AVFoundation
import QuartzCore
import ReelbirdCore

/// Live camera preview for the floating camera bubble (before and during recording).
///
/// The bubble is UI only: it is excluded from the screen capture (our own app's windows are filtered
/// out) and the camera is recorded to its own track, so layout can change after recording.
public enum CameraPreview {
    /// A layer-backed view showing the camera, filling its bounds (aspect fill). Mirrored like the editor's and
    /// the export's default (`CameraLayout.mirror`), so the bubble shows what the video will.
    /// Keep the returned controller alive while the view is visible.
    @MainActor
    public static func makeView(deviceID: String = "default", mirrored: Bool = CameraLayout().mirror) throws -> CameraPreviewController {
        try CameraPreviewController(deviceID: deviceID, mirrored: mirrored)
    }
}

/// Owns the preview's capture session. Main actor; the session itself starts and stops on a
/// background queue so the UI never waits on the camera.
@MainActor
public final class CameraPreviewController {
    public let view: NSView
    public let previewLayer: AVCaptureVideoPreviewLayer
    private let session: AVCaptureSession
    private let queue = DispatchQueue(label: "reelbird.camera.preview")

    init(deviceID: String, mirrored: Bool) throws {
        guard let device = Devices.device(deviceID, type: .video) else { throw CaptureError.sourceNotFound("the camera") }
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .high
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.sourceNotFound("the camera") }
        session.addInput(input)
        session.commitConfiguration()
        self.session = session
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
        let view = NSView()
        view.wantsLayer = true
        view.layer = CALayer()
        previewLayer.frame = view.bounds
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        // Follow the bubble's own spring frame by frame: no implicit 0.25 s layer animation lagging behind it.
        previewLayer.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        view.layer?.addSublayer(previewLayer)
        self.view = view
    }

    public func start() {
        let session = session
        queue.async { if !session.isRunning { session.startRunning() } }
    }

    public func stop() {
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
    }
}
