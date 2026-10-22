import CoreGraphics
import Foundation
import ReelbirdAI
import ReelbirdCore
import ReelbirdRender
import ReelbirdShare

/// A take's guide for an edit: the steps as shown, one image per step and what places them.
public struct BuiltGuide: @unchecked Sendable {
    public var steps: [GuideStep]
    /// Same order as `steps`: the screen just before each action, without the click marked.
    public var images: [CGImage]
    public var crop: NormRect?
    public var timeline: EditTimeline

    public init(steps: [GuideStep], images: [CGImage], crop: NormRect?, timeline: EditTimeline) {
        self.steps = steps; self.images = images; self.crop = crop; self.timeline = timeline
    }

    /// What a link publishes: the page's steps and a JPEG per step (the page draws the click itself).
    public func shared(quality: Double = 0.82) -> SharedGuide {
        let jpegs = images.map { img in StepImages.jpeg(img, quality: quality).map { (jpeg: $0, width: img.width, height: img.height) } }
        return SharedGuide.make(steps, images: jpegs, timeline: timeline, crop: crop)
    }

    /// Images with the click drawn in, for exports that can't overlay it (Markdown, skills).
    public func markedJPEGs(quality: Double = 0.84) -> [Data?] {
        zip(steps, images).map { s, img in
            let place = GuideSteps.placement(s, crop: crop)
            return StepImages.jpeg(StepImages.marked(img, point: place.point, box: place.box), quality: quality)
        }
    }
}

public enum GuideBuilder {
    /// Scans the take's steps (or reads `steps.json`), applies `edit` and renders the step images.
    public static func build(bundle: ProjectBundle, edit: EditDocument, options: StepScanner.Options = StepScanner.Options(),
                             progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> BuiltGuide {
        let steps = try await StepScanner.steps(bundle: bundle, edit: edit, options: options) { progress($0 * 0.75) }
        return try await build(bundle: bundle, edit: edit, steps: steps) { progress(0.75 + $0 * 0.25) }
    }

    /// Renders the images for steps already resolved for `edit`.
    public static func build(bundle: ProjectBundle, edit: EditDocument, steps: [GuideStep],
                             progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> BuiltGuide {
        let manifest = try bundle.readManifest()
        let images = try await StepImages.render(bundle: bundle, edit: edit, steps: steps, progress: progress)
        return BuiltGuide(steps: steps, images: images, crop: edit.crop, timeline: EditTimeline(manifest: manifest, edit: edit))
    }

    /// What a publish of `video` (the edit rendered) does with the guide and the text layer, following
    /// `edit.guide`: the guide when `share` is on and the take has steps, the text layer when `copyText` is on
    /// and the video shows text. Anything that fails is left off the link rather than failing the publish.
    ///
    /// - Parameters:
    ///   - steps: steps already resolved for `edit` (scanned while the video rendered), or `nil` to scan now.
    ///   - workDir: where the text layer's JSON is written for the upload.
    public static func shareAssets(bundle: ProjectBundle, edit: EditDocument, video: URL, steps: [GuideStep]?, workDir: URL,
                                   progress: @escaping @Sendable (Double) -> Void = { _ in })
        async -> (guide: ShareAsset<SharedGuide>, text: ShareAsset<URL>) {
        async let guide: ShareAsset<SharedGuide> = {
            guard edit.guide.share else { return .remove }
            var found = steps
            if found == nil { found = try? await StepScanner.steps(bundle: bundle, edit: edit) }
            guard let found, !found.isEmpty,
                  let built = try? await build(bundle: bundle, edit: edit, steps: found, progress: { progress($0 * 0.5) }) else { return .remove }
            return .replace(built.shared())
        }()
        async let text: ShareAsset<URL> = {
            guard edit.guide.copyText, let layer = try? await ScreenText.read(video: video), !layer.isEmpty else { return .remove }
            let url = workDir.appendingPathComponent("text.json")
            guard let data = try? JSONEncoder().encode(layer), (try? data.write(to: url)) != nil else { return .remove }
            return .replace(url)
        }()
        let result = await (guide, text)
        progress(1)
        return result
    }
}
