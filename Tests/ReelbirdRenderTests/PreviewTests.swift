@preconcurrency import AVFoundation
import AppKit
import Foundation
import Metal
import Testing
import ReelbirdCore
@testable import ReelbirdRender

@MainActor
private func waitFor(_ what: String, timeout: Double = 5, _ cond: () -> Bool) async throws {
    let start = Date()
    while !cond() {
        if Date().timeIntervalSince(start) > timeout { Issue.record("timed out waiting for \(what)"); return }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
@Test func previewPlayerLoadsSeeksPlaysAndUpdates() async throws {
    var o = Synthetic.Options()
    o.camera = true
    o.seconds = 3
    let bundle = try await Synthetic.makeBundle(o)
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let player = try PreviewPlayer(bundle: bundle)
    // Test runs are silent: the preview plays muted (its audio taps still run).
    #expect(AutomatedRun.isTestProcess && AutomatedRun.isSilent)
    #expect(player.isMuted)
    var ready = false
    var readyError: (any Error)?
    player.onReady = { e in ready = true; readyError = e }
    var times: [Double] = []
    player.onTimeChange = { times.append($0) }
    try await waitFor("ready") { ready }
    #expect(readyError == nil)
    #expect(abs(player.duration - 3) < 1e-6)

    let view = player.view
    view.setFrameSize(NSSize(width: 480, height: 270))
    #expect(view.layer is CAMetalLayer)

    player.seek(to: 1.0)
    #expect(player.currentTime == 1.0)
    try await waitFor("decoded frame") { player.hasFrame() }
    var edit = try bundle.readEdit()
    edit.background.kind = .solid
    edit.background.colors = [RGBA(1, 0, 0)]
    edit.zoom.mode = .off
    player.update(edit: edit)
    let img = try #require(player.snapshot(width: 640))
    let px = Pixels(img)
    #expect(px.near(2, 2, (255, 0, 0), tol: 6), "background \(px[2, 2])")
    #expect(px.near(320, 100, Synthetic.greyRGB, tol: 10), "screen \(px[320, 100])")

    // Cutting re-plans and keeps the playhead on the same recording moment where possible.
    edit.cuts = [TimeRange(start: 0.2, end: 0.6)]
    player.update(edit: edit)
    #expect(abs(player.duration - 2.6) < 1e-6)
    #expect(abs(player.currentTime - 0.6) < 1e-6)

    player.seek(to: 0)
    try await waitFor("seek to 0") { player.hasFrame() }
    player.play()
    #expect(player.isPlaying)
    // Playback advances (polled, so a busy machine that starts audio late doesn't fail the test).
    try await waitFor("playback advances", timeout: 5) { player.currentTime > 0.25 }
    let t = player.currentTime
    #expect(t < player.duration, "played to \(t)")
    player.pause()
    #expect(!player.isPlaying)
    #expect(times.count >= 3)
    // Playing to the end stops at the end.
    player.seek(to: 2.4)
    player.play()
    try await waitFor("end", timeout: 3) { !player.isPlaying }
    #expect(abs(player.currentTime - player.duration) < 0.05)
}

/// Preview cost: one 4K source frame composited into a 2880×1620 drawable. Prints CPU encode and GPU time.
@Test func previewRenderCost() async throws {
    guard ProcessInfo.processInfo.environment["RB_BENCH"] != nil else { return }
    var o = Synthetic.Options()
    o.width = 3840; o.height = 2160; o.fps = 60; o.seconds = 1; o.codec = .hevc; o.camera = true; o.captureScale = 2
    let bundle = try await Synthetic.makeBundle(o)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let manifest = try bundle.readManifest()
    var edit = try bundle.readEdit()
    edit.zoom.regions = [ZoomRegion(id: "z", range: TimeRange(start: 0.2, end: 0.9), scale: 2, focus: NormPoint(x: 0.3, y: 0.3))]
    edit.zoom.mode = .manual
    let plan = try RenderPlan(bundle: bundle, manifest: manifest, edit: edit)
    let sources = try await MediaSources.load(bundle: bundle, manifest: manifest)
    let comp = try sources.composition(timeline: plan.timeline, camera: true, audio: nil)
    let reader = try AVAssetReader(asset: comp.asset)
    let so = AVAssetReaderTrackOutput(track: comp.screen!, outputSettings: MediaSources.decodeSettings)
    let co = AVAssetReaderTrackOutput(track: comp.camera!, outputSettings: MediaSources.decodeSettings)
    reader.add(so); reader.add(co)
    reader.startReading()
    let screen = try #require(so.copyNextSampleBuffer().flatMap(CMSampleBufferGetImageBuffer))
    let camera = try #require(co.copyNextSampleBuffer().flatMap(CMSampleBufferGetImageBuffer))
    let ctx = try MetalContext.shared()
    let queue = try #require(ctx.device.makeCommandQueue())
    let compositor = Compositor(context: ctx, queue: queue)
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 2880, height: 1620, mipmapped: false)
    d.usage = [.renderTarget]
    d.storageMode = .private
    let target = try #require(ctx.device.makeTexture(descriptor: d))
    var cpu = 0.0, gpu = 0.0
    let n = 240
    for i in 0..<n {
        let cb = try #require(queue.makeCommandBuffer())
        let t0 = CACurrentMediaTime()
        compositor.encode(plan: plan, outputTime: Double(i % 60) / 60, screen: screen, camera: camera, target: target,
                          frameInterval: 1.0 / 60, commandBuffer: cb)
        cb.commit()
        cpu += CACurrentMediaTime() - t0
        await cb.completed()
        gpu += cb.gpuEndTime - cb.gpuStartTime
    }
    print(String(format: "BENCH preview frame (4K source → 2880x1620, zoom + blur + camera): CPU encode %.0f µs, GPU %.2f ms",
                 cpu / Double(n) * 1e6, gpu / Double(n) * 1e3))
    #expect(gpu / Double(n) < 1.0 / 60)
}

/// On-screen path: the display link presents frames while playing and sleeps when paused.
@MainActor
@Test func previewPresentsOnScreen() async throws {
    let bundle = try await Synthetic.makeBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    _ = NSApplication.shared
    let player = try PreviewPlayer(bundle: bundle)
    var ready = false
    player.onReady = { _ in ready = true }
    try await waitFor("ready") { ready }
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = player.view
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    try await Task.sleep(for: .milliseconds(200))
    guard window.occlusionState.contains(.visible) else {
        // Test runners without a visible desktop never un-occlude the window, so the display link stays idle.
        print("previewPresentsOnScreen: window occluded (no visible desktop); skipping frame-count checks")
        player.play(); try await Task.sleep(for: .milliseconds(300)); player.pause()
        return
    }
    player.seek(to: 0.5)
    try await Task.sleep(for: .milliseconds(500))
    let idle0 = player.presentedFrames
    #expect(idle0 >= 1, "seek should present a frame")
    try await Task.sleep(for: .milliseconds(700))
    let idle1 = player.presentedFrames
    #expect(idle1 - idle0 <= 2, "paused preview should sleep (\(idle1 - idle0) frames)")
    player.play()
    try await Task.sleep(for: .milliseconds(1000))
    let played = player.presentedFrames - idle1
    player.pause()
    print("previewPresentsOnScreen: \(played) frames presented in 1 s of playback")
    #expect(played >= 40)
}
