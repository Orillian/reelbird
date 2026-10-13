#if DEBUG
import AppKit
import ScreenCaptureKit

/// `--probe-thumbnails <dir>`: tries to capture every off-screen app window (other Spaces, minimized)
/// with ScreenCaptureKit and writes what it gets, to learn what macOS allows. Dev tool, debug builds only:
/// `swift run ReelbirdApp --probe-thumbnails /tmp/probe` (from a terminal with Screen Recording permission).
enum ThumbnailProbe {
    static func run(dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var log = ""
        func note(_ s: String) { log += s + "\n" }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let windows = content.windows.filter { $0.windowLayer == 0 && $0.frame.width >= 160 && $0.frame.height >= 100 && $0.owningApplication != nil }
            note("windows: \(windows.count) (off-screen: \(windows.filter { !$0.isOnScreen }.count))")
            for w in windows.prefix(40) {
                let app = w.owningApplication?.applicationName ?? "?"
                let config = SCStreamConfiguration()
                config.width = 640
                config.height = max(2, Int(640 * w.frame.height / max(1, w.frame.width)))
                config.showsCursor = false
                let filter = SCContentFilter(desktopIndependentWindow: w)
                let tag = "\(w.isOnScreen ? "on " : "off") \(app) — \(w.title ?? "") [\(Int(w.frame.width))×\(Int(w.frame.height))]"
                do {
                    let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    let stats = brightness(img)
                    let name = "\(w.windowID)-\(w.isOnScreen ? "on" : "off").png"
                    if let data = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
                        try? data.write(to: dir.appendingPathComponent(name))
                    }
                    note("\(tag): OK \(img.width)×\(img.height) mean=\(String(format: "%.3f", stats.mean)) opaque=\(String(format: "%.2f", stats.opaque)) → \(name)")
                } catch {
                    note("\(tag): FAIL \(error.localizedDescription)")
                }
            }
        } catch {
            note("SCShareableContent failed: \(error.localizedDescription)")
        }
        try? log.write(to: dir.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)
    }

    private static func brightness(_ img: CGImage) -> (mean: Double, opaque: Double) {
        let w = 64, h = 64
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0, 0) }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0, opaque = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            sum += Double(Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2])) / 765
            if px[i + 3] > 200 { opaque += 1 }
        }
        let n = Double(w * h)
        return (sum / n, opaque / n)
    }
}
#endif
