import Foundation
import ReelbirdCore

/// A step guide to publish with a link: the steps as the page shows them and one JPEG per step, in the same
/// order (`nil` = no image). `ShareService.publish` uploads the images and names them in `ViewerMeta.guide`.
public struct SharedGuide: Sendable {
    /// Steps a link shows at most.
    public static let maxSteps = 200

    public var steps: [ViewerMeta.Guide.Step]
    public var images: [Data?]

    public init(steps: [ViewerMeta.Guide.Step], images: [Data?]) { self.steps = steps; self.images = images }

    /// The page's steps from the guide's steps (`GuideSteps.resolve`): output times for "Play from here", click
    /// points and label boxes on the step images, and each image's size.
    public static func make(_ steps: [GuideStep], images: [(jpeg: Data, width: Int, height: Int)?], timeline: EditTimeline,
                            crop: NormRect?) -> SharedGuide {
        var out: [ViewerMeta.Guide.Step] = []
        for (i, s) in steps.prefix(maxSteps).enumerated() {
            let place = GuideSteps.placement(s, crop: crop)
            let image = i < images.count ? images[i] : nil
            let t = timeline.outputTime(forSource: s.t) ?? timeline.nearestOutputTime(forSource: s.t)
            out.append(ViewerMeta.Guide.Step(id: s.id, n: i + 1, t: (t * 1000).rounded() / 1000, kind: s.kind.rawValue, text: s.text,
                                             note: s.narration, section: s.section, w: image?.width, h: image?.height,
                                             x: place.point?.x, y: place.point?.y, box: place.box, keys: s.keys))
        }
        return SharedGuide(steps: out, images: (0..<out.count).map { $0 < images.count ? images[$0]?.jpeg : nil })
    }
}
