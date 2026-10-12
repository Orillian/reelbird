@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import Metal
import ReelbirdCore

/// Still frames of the edited recording (library posters, share posters).
public enum Thumbnailer {
    /// The fully composited frame at output time `t` (clamped to the edited duration), at most `maxWidth`
    /// pixels wide. Uses the bundle's saved edit.
    public static func poster(bundle: ProjectBundle, at t: Double, maxWidth: Int) async throws -> CGImage {
        let manifest = try bundle.readManifest()
        let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: try bundle.readEdit())
        let sources = try await MediaSources.load(bundle: bundle, manifest: manifest)
        return try render(plan: plan, sources: sources, at: t, maxWidth: maxWidth)
    }

    /// Renders one frame synchronously (blocks until the GPU finishes).
    static func render(plan: RenderPlan, sources: MediaSources, at time: Double, maxWidth: Int) throws -> CGImage {
        guard plan.duration > 0 else { throw RenderError.nothingToExport }
        let t = min(max(0, time), max(0, plan.duration - 0.001))
        let comp = try sources.composition(timeline: plan.timeline, camera: plan.showsCamera, audio: nil)
        guard let screenTrack = comp.screen else { throw RenderError.missingScreenTrack }

        func grab(_ track: AVAssetTrack) throws -> CMSampleBuffer? {
            let reader = try AVAssetReader(asset: comp.asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: MediaSources.decodeSettings)
            out.alwaysCopiesSampleData = false
            reader.timeRange = CMTimeRange(start: MediaSources.time(max(0, t - 2)), end: MediaSources.time(t + 0.5))
            reader.add(out)
            guard reader.startReading() else { throw RenderError.readerFailed(reader.error?.localizedDescription ?? "start failed") }
            defer { reader.cancelReading() }
            let steps = FrameStepper(out)
            _ = steps.frame(at: t, tolerance: 1e-3)
            return steps.current
        }
        let screenSB = try grab(screenTrack)
        let cameraSB = try comp.camera.flatMap { try grab($0) }

        let canvas = plan.canvasSize
        let w = min(max(16, maxWidth), canvas.width)
        let size = PixelSize(width: max(2, w / 2 * 2), height: max(2, Int((Double(w) * Double(canvas.height) / Double(canvas.width) / 2).rounded()) * 2))
        let ctx = try MetalContext.shared()
        guard let queue = ctx.device.makeCommandQueue(), let cb = queue.makeCommandBuffer() else { throw RenderError.metalUnavailable }
        let pool = try makePool(width: size.width, height: size.height)
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out)
        guard let out, let tex = ctx.texture(out, plane: 0, format: .bgra8Unorm, renderTarget: true),
              let target = CVMetalTextureGetTexture(tex) else { throw RenderError.writerFailed("frame") }
        let compositor = Compositor(context: ctx, queue: queue)
        let keep = compositor.encode(plan: plan, outputTime: t, screen: screenSB.flatMap(CMSampleBufferGetImageBuffer),
                                     camera: cameraSB.flatMap(CMSampleBufferGetImageBuffer), target: target,
                                     frameInterval: 1 / Double(plan.frameRate), commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        withExtendedLifetime((keep, tex, screenSB, cameraSB)) {}
        guard cb.status == .completed, let img = cgImage(from: out) else { throw RenderError.writerFailed("poster render failed") }
        return img
    }
}
