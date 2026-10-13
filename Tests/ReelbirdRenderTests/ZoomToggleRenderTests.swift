@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import Testing
import ReelbirdCore
@testable import ReelbirdRender

// Zooms turned off and instant zooms, as the renderer draws them (preview and export share this path).

private func flatEdit(_ manifest: ProjectManifest) -> EditDocument {
    var e = EditDocument.initial(for: manifest)
    e.background.kind = .solid
    e.background.colors = [RGBA(hex: "#2050A0")!]
    e.background.padding = 0.1
    e.background.cornerRadius = 0.05
    e.background.shadow = 0
    e.background.motionBlur = true
    e.zoom.mode = .manual
    e.cursor.visible = false
    e.camera.visible = false
    return e
}

private func darkWidth(_ px: Pixels) -> Int {
    var n = 0
    for x in 0..<px.width where px[x, 270].r < 40 && px[x, 270].g < 40 && px[x, 270].b < 40 { n += 1 }
    return n
}

@Test func zoomTurnedOffIsNotRenderedAndInstantZoomCuts() async throws {
    let bundle = try await Synthetic.makeBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    let sources = try await MediaSources.load(bundle: bundle, manifest: manifest)
    func width(_ e: EditDocument, at t: Double) async throws -> Int {
        let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: e)
        return darkWidth(Pixels(try await Thumbnailer.render(plan: plan, sources: sources, at: t, maxWidth: 960)))
    }
    let flat = try await width(flatEdit(manifest), at: 1.5)

    // Off: kept in the edit, left out of the plan, drawn at zoom 1.
    var off = flatEdit(manifest)
    off.zoom.regions = [ZoomRegion(id: "z", range: TimeRange(start: 0.5, end: 2.5), scale: 2, focus: .center, enabled: false)]
    let offPlan = try RenderPlan(bundle: bundle, manifest: manifest, edit: off)
    #expect(offPlan.regions.isEmpty && off.zoom.regions.count == 1)
    let offWidth = try await width(off, at: 1.5)
    #expect(abs(offWidth - flat) <= 1)

    // Auto mode: a zoom turned off isn't planned again.
    var autoOff = off
    autoOff.zoom.mode = .auto
    let autoPlan = try RenderPlan(bundle: bundle, manifest: manifest, edit: autoOff)
    #expect(!autoPlan.regions.contains { $0.range.overlaps(TimeRange(start: 0.5, end: 2.5)) }, "\(autoPlan.regions)")

    // Instant: fully zoomed one frame in, while the animated zoom is still easing in.
    var instant = flatEdit(manifest)
    instant.zoom.regions = [ZoomRegion(id: "z", range: TimeRange(start: 1, end: 2.5), scale: 2, focus: .center, instant: true)]
    var smooth = instant
    smooth.zoom.regions[0].instant = false
    let justIn = 1 + 1.0 / 30
    let a = try await width(instant, at: justIn), b = try await width(smooth, at: justIn)
    let instantRatio = Double(a) / Double(flat), smoothRatio = Double(b) / Double(flat)
    #expect(abs(instantRatio - 2) < 0.08, "instant zoom at \(justIn) s: \(a) vs \(flat)")
    #expect(smoothRatio < 1.8, "animated zoom is still easing in: \(b) vs \(flat)")
    let before: Int = try await width(instant, at: 1 - 1.0 / 30)
    #expect(abs(before - flat) <= 1, "nothing before the cut")
    let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: instant)
    let frame: Double = 1.0 / 60
    let cutNearStart = plan.camera.hasCut(after: 1 - frame, upTo: 1 + frame)
    #expect(cutNearStart)
}
