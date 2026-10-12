import Foundation
import ReelbirdCore

/// Deterministic sample data for mocks and snapshots.
enum MockData {
    /// A plausible pointer trail: glides between targets, clicks at each, a few key presses.
    static func events(duration: Double) -> [InputEvent] {
        let targets: [NormPoint] = [
            NormPoint(x: 0.30, y: 0.22), NormPoint(x: 0.62, y: 0.35), NormPoint(x: 0.86, y: 0.12),
            NormPoint(x: 0.45, y: 0.58), NormPoint(x: 0.70, y: 0.66), NormPoint(x: 0.20, y: 0.40),
            NormPoint(x: 0.55, y: 0.30), NormPoint(x: 0.82, y: 0.52),
        ]
        var out: [InputEvent] = []
        var t = 0.4
        var from = NormPoint(x: 0.5, y: 0.5)
        var i = 0
        while t < duration - 0.5 {
            let to = targets[i % targets.count]
            let travel = 0.7 + Double(i % 3) * 0.25
            let steps = Int(travel * 60)
            for s in 0...steps {
                let f = Double(s) / Double(steps)
                let e = f * f * (3 - 2 * f)
                let arc = sin(f * .pi) * 0.04
                out.append(.move(t + travel * f, NormPoint(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e - arc)))
            }
            t += travel + 0.15
            out.append(.down(t, to)); out.append(.up(t + 0.09, to))
            if i % 3 == 1 {
                for (k, ch) in ["R", "e", "e", "l"].enumerated() {
                    out.append(InputEvent(t: t + 0.4 + Double(k) * 0.16, type: .key, chars: ch))
                }
                out.append(InputEvent(t: t + 1.3, type: .key, chars: "S", mods: ["⌘"]))
            }
            t += 1.6 + Double((i * 7) % 5) * 0.45
            from = to
            i += 1
        }
        return out.sorted { $0.t < $1.t }
    }

    /// Simple click-cluster zoom planner standing in for `AutoZoomPlanner`.
    static func autoZoom(events: [InputEvent], duration: Double, intensity: Double) -> [ZoomRegion] {
        let clicks = events.filter { $0.type == .down }
        guard !clicks.isEmpty else { return [] }
        let hold = 2.2 + intensity * 1.2
        let minGap = 4.5 - intensity * 2.5
        var regions: [ZoomRegion] = []
        for c in clicks {
            let start = max(0, c.t - 0.6)
            if let last = regions.last, start - last.range.end < minGap {
                regions[regions.count - 1].range.end = min(duration, c.t + hold)
            } else {
                regions.append(ZoomRegion(range: TimeRange(start: start, end: min(duration, c.t + hold)),
                                          scale: 1.35 + intensity * 0.9, focus: nil, source: .auto))
            }
        }
        return regions
    }

    static let transcript = Transcript(segments: [
        .init(range: TimeRange(start: 0.5, end: 3.4), text: "Hey team, quick walkthrough of the new checkout flow."),
        .init(range: TimeRange(start: 3.6, end: 7.8), text: "First, the cart now remembers your shipping address."),
        .init(range: TimeRange(start: 8.2, end: 12.5), text: "Then we skip straight to payment with one click."),
        .init(range: TimeRange(start: 13.0, end: 18.4), text: "And here's the confirmation screen we talked about on Monday."),
        .init(range: TimeRange(start: 19.0, end: 24.0), text: "Let me know what you think in the thread."),
    ], locale: "en-US")

    /// A manifest for an in-memory demo project.
    static func manifest(title: String = "Checkout flow walkthrough", duration: Double = 46.5, camera: Bool = true,
                         share: ShareInfo? = nil, status: RecordingStatus = .complete, createdAt: Date = Date()) -> ProjectManifest {
        var tracks = [
            TrackInfo(kind: .screen, directory: "screen", file: "screen/screen.mp4", codec: "hvc1",
                      pixelSize: PixelSize(width: 3456, height: 2234), duration: duration),
            TrackInfo(kind: .microphone, directory: "microphone", file: "microphone/microphone.m4a", codec: "aac",
                      sampleRate: 48000, channels: 1, duration: duration),
            TrackInfo(kind: .systemAudio, directory: "systemAudio", file: "systemAudio/systemAudio.m4a", codec: "aac",
                      sampleRate: 48000, channels: 2, duration: duration),
        ]
        if camera {
            tracks.append(TrackInfo(kind: .camera, directory: "camera", file: "camera/camera.mp4", codec: "hvc1",
                                    pixelSize: PixelSize(width: 1920, height: 1080), duration: duration))
        }
        return ProjectManifest(createdAt: createdAt, title: title, appVersion: ReelbirdInfo.version, status: status,
                               capture: CaptureInfo(source: .display(id: 1, name: "Built-in Retina Display"),
                                                    pixelSize: PixelSize(width: 3456, height: 2234), scale: 2, frameRate: 60),
                               clock: ClockInfo(originHostTime: 0), tracks: tracks,
                               pauses: [TimeRange(start: 21.0, end: 23.2)], duration: duration, share: share)
    }

    /// Writes a demo bundle (manifest, events, edit) to `url` and returns it.
    @discardableResult
    static func writeDemoBundle(at url: URL, title: String, duration: Double, camera: Bool = true,
                                share: ShareInfo? = nil, status: RecordingStatus = .complete,
                                createdAt: Date = Date()) throws -> ProjectBundle {
        let b = try ProjectBundle.create(at: url)
        try b.writeManifest(manifest(title: title, duration: duration, camera: camera, share: share, status: status, createdAt: createdAt))
        let w = try EventLogWriter(url: b.eventsURL)
        for e in events(duration: duration) { w.append(e) }
        w.close()
        return b
    }
}
