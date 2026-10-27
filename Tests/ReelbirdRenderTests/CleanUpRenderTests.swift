import Foundation
import Testing
import ReelbirdCore
@testable import ReelbirdRender

/// Across a cut where the pointer jumped, the cursor glides over 0.2 s instead of teleporting; a small jump
/// is left as it is.
@Test func cursorGlidesAcrossACutWhereItJumped() async throws {
    var o = Synthetic.Options()
    o.seconds = 4
    // Left side until 1.8 s, then far right; the cut 1.5–2.5 hides the move.
    o.events = stride(from: 0.0, to: 4.0, by: 0.05).map { t in InputEvent.move(t, NormPoint(x: t < 1.8 ? 0.1 : 0.9, y: 0.5)) }
    let bundle = try await Synthetic.makeBundle(o)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    var edit = EditDocument()
    edit.cursor.smoothing = 0
    edit.cuts = [TimeRange(start: 1.5, end: 2.5)]
    let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: edit)
    let join = try #require(plan.timeline.joins.first)
    #expect(abs(join - 1.5) < 1e-6)
    func x(_ out: Double) -> Double { plan.cursorPosition(output: out, source: plan.timeline.sourceTime(forOutput: out))?.x ?? -1 }
    let before = try #require(plan.cursor.position(at: 1.5)).x, after = try #require(plan.cursor.position(at: 2.6)).x
    #expect(abs(x(join) - before) < 0.02, "starts where it was: \(x(join)) vs \(before)")
    let mid = x(join + 0.1)
    #expect(mid > before + 0.2 && mid < after - 0.2, "half way: \(mid)")
    #expect(abs(x(join + 0.25) - after) < 0.02, "arrived: \(x(join + 0.25))")
    // Without a cut there is nothing to glide over.
    edit.cuts = []
    let plain = try RenderPlan(bundle: bundle, manifest: manifest, edit: edit)
    #expect(plain.cursorPosition(output: 2.6, source: 2.6)?.x == plain.cursor.position(at: 2.6)?.x)
}
