@preconcurrency import AVFoundation
import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import ReelbirdCore
import UniformTypeIdentifiers

/// A realistic recording for judging motion and render quality by eye, built entirely from code.
///
/// The "screen" is a 1440×900 pt (2880×1800 px) Mac desktop with a task-manager window: menu bar, window
/// chrome, sidebar, a task list, a composer with a text field, a share popover. A scripted person uses it:
/// Fitts-law timed moves with minimum-jerk primary submovements, slight curvature, undershoot plus a
/// corrective submovement, hand tremor, 120 Hz sampling with timer jitter (like `InputEventRecorder`),
/// clicks with real press durations, typing bursts with human rhythm, trackpad scrolling with momentum,
/// and cursor image changes that lag by the recorder's 20 Hz poll. The screen video is variable frame rate
/// (frames only when pixels change, like ScreenCaptureKit). The microphone hears the room, mouse clicks and
/// keys at the moments they happen, so audio/video sync is audible.
enum DemoFixture {
    static let points = CGSize(width: 1440, height: 900)
    static let scale = 2
    static let fps = 60

    // MARK: Layout (points, top-left origin)

    enum Layout {
        static let menuBar: CGFloat = 25
        static let window = CGRect(x: 96, y: 58, width: 1248, height: 804)
        static let toolbarH: CGFloat = 54
        static let sidebarW: CGFloat = 236
        static var sidebar: CGRect { CGRect(x: window.minX, y: window.minY, width: sidebarW, height: window.height) }
        static var content: CGRect { CGRect(x: window.minX + sidebarW, y: window.minY, width: window.width - sidebarW, height: window.height) }
        static let sidebarItems = ["Inbox", "Today", "Upcoming", "Completed"]
        static let sidebarCounts = ["12", "5", "", ""]
        static let projects: [(String, (CGFloat, CGFloat, CGFloat))] = [
            ("Website relaunch", (0.96, 0.55, 0.20)), ("Mobile app", (0.25, 0.52, 0.96)),
            ("Q4 planning", (0.28, 0.72, 0.42)), ("Hiring", (0.62, 0.42, 0.88)),
        ]
        static func sidebarRow(_ i: Int) -> CGRect {
            CGRect(x: window.minX + 10, y: window.minY + 92 + CGFloat(i) * 30, width: sidebarW - 20, height: 28)
        }
        static func projectRow(_ i: Int) -> CGRect {
            CGRect(x: window.minX + 10, y: window.minY + 92 + 4 * 30 + 38 + CGFloat(i) * 30, width: sidebarW - 20, height: 28)
        }
        static var newTaskButton: CGRect { CGRect(x: window.maxX - 134, y: window.minY + 13, width: 118, height: 28) }
        static var shareButton: CGRect { CGRect(x: window.maxX - 222, y: window.minY + 13, width: 78, height: 28) }
        static var listTop: CGFloat { window.minY + toolbarH + 96 }
        static let rowH: CGFloat = 48
        static var composer: CGRect { CGRect(x: content.minX + 32, y: window.minY + toolbarH + 96, width: content.width - 64, height: 112) }
        static var composerField: CGRect { CGRect(x: composer.minX + 16, y: composer.minY + 14, width: composer.width - 32, height: 36) }
        static var composerSave: CGRect { CGRect(x: composer.maxX - 92, y: composer.maxY - 44, width: 76, height: 30) }
        static var composerCancel: CGRect { CGRect(x: composer.maxX - 180, y: composer.maxY - 44, width: 80, height: 30) }
        static var popover: CGRect { CGRect(x: shareButton.midX - 170, y: shareButton.maxY + 10, width: 340, height: 132) }
        static var copyButton: CGRect { CGRect(x: popover.maxX - 120, y: popover.maxY - 50, width: 104, height: 32) }
    }

    struct TodoItem: Hashable { var title: String; var tag: Int; var due: String }

    static let initialTasks: [TodoItem] = [
        TodoItem(title: "Review onboarding copy", tag: 0, due: "10:00"),
        TodoItem(title: "Fix flaky checkout test", tag: 1, due: "11:30"),
        TodoItem(title: "Draft Q4 roadmap one-pager", tag: 2, due: "13:00"),
        TodoItem(title: "Interview: product designer", tag: 3, due: "15:00"),
        TodoItem(title: "Send weekly update", tag: 2, due: "17:00"),
        TodoItem(title: "Update pricing page screenshots", tag: 0, due: "Tomorrow"),
        TodoItem(title: "Triage crash reports", tag: 1, due: "Tomorrow"),
        TodoItem(title: "Book offsite venue", tag: 2, due: "Fri"),
        TodoItem(title: "Reference checks", tag: 3, due: "Fri"),
        TodoItem(title: "Archive old experiments", tag: 1, due: "Next week"),
        TodoItem(title: "Plan launch livestream", tag: 0, due: "Next week"),
        TodoItem(title: "Renew design tool licences", tag: 2, due: "Oct 30"),
    ]

    struct UIState: Hashable {
        var sidebar = 1
        var tasks = DemoFixture.initialTasks
        var checked: Set<String> = []
        var composerOpen = false
        var text = ""
        var lastKey = -10.0
        var popover = false
        var copied = false
        var pressed: String?
    }

    // MARK: The person

    struct Recording {
        var events: [InputEvent]
        var duration: Double
        /// UI snapshots: state from `t` on.
        var states: [(t: Double, state: UIState)]
        /// Scroll animations of the task list (points).
        var scrolls: [(t0: Double, t1: Double, from: Double, to: Double)]
        /// Click times (down) and key times, for the microphone.
        var clickTimes: [Double]
        var upTimes: [Double]
        var keyTimes: [Double]

        func state(at t: Double) -> UIState {
            var lo = 0, hi = states.count
            while lo < hi { let m = (lo + hi) / 2; if states[m].t <= t { lo = m + 1 } else { hi = m } }
            return states[max(0, lo - 1)].state
        }

        func scroll(at t: Double) -> Double {
            var y = 0.0
            for s in scrolls {
                if t >= s.t1 { y = s.to } else if t > s.t0 {
                    let u = (t - s.t0) / (s.t1 - s.t0)
                    y = s.from + (s.to - s.from) * (1 - pow(1 - u, 3))
                } else { break }
            }
            return y
        }
    }

    /// Deterministic PRNG (SplitMix64).
    struct RNG {
        var s: UInt64
        mutating func next() -> Double {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
        mutating func gauss() -> Double { (next() + next() + next() + next() - 2) * 1.7 }
    }

    final class Person {
        var t = 0.0
        var pos: CGPoint
        var rng = RNG(s: 0x5EED_2026)
        var events: [InputEvent] = []
        var states: [(t: Double, state: UIState)] = [(0, UIState())]
        var scrolls: [(t0: Double, t1: Double, from: Double, to: Double)] = []
        var clicks: [Double] = [], ups: [Double] = [], keys: [Double] = []
        var cursor = "arrow"
        var scrollY = 0.0
        private var tremorX = 0.0, tremorY = 0.0
        private var nextSample = 0.0

        init(start: CGPoint) {
            pos = start
            events.append(InputEvent(t: 0, type: .cursor, image: "arrow"))
            sample(pos, at: 0)
        }

        var state: UIState { states[states.count - 1].state }
        func change(at time: Double, _ f: (inout UIState) -> Void) {
            var s = state
            f(&s)
            if let last = states.last, last.t == time { states[states.count - 1].state = s } else { states.append((time, s)) }
        }

        private func norm(_ p: CGPoint) -> NormPoint {
            func r4(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }
            return NormPoint(x: r4(p.x / points.width), y: r4(p.y / points.height))
        }

        private func sample(_ p: CGPoint, at time: Double) {
            let n = norm(p)
            if case .move = events.last?.type, let lx = events.last?.x, let ly = events.last?.y,
               abs(lx - n.x) < 5e-5, abs(ly - n.y) < 5e-5 { return }
            events.append(.move((time * 10_000).rounded() / 10_000, n))
        }

        /// Pointer samples at 120 Hz with ±1.5 ms timer jitter along a path p(u), u in 0...1 over `duration`.
        private func trace(duration: Double, _ path: (Double) -> CGPoint) {
            let t0 = t
            if nextSample < t0 { nextSample = t0 + 1.0 / 120 }
            while nextSample <= t0 + duration {
                let u = (nextSample - t0) / duration
                var p = path(u)
                // Tremor: a slow random walk of a fraction of a point.
                tremorX = tremorX * 0.9 + rng.gauss() * 0.06
                tremorY = tremorY * 0.9 + rng.gauss() * 0.06
                p.x += tremorX; p.y += tremorY
                sample(p, at: nextSample + rng.range(-0.0015, 0.0015))
                nextSample += 1.0 / 120
            }
            t = t0 + duration
            pos = path(1)
        }

        func wait(_ d: Double) { t += d; if nextSample < t { nextSample = t } }

        /// A human reach: Fitts-law duration, minimum-jerk primary move that bends slightly and lands short,
        /// then a short corrective move onto the target.
        func move(to target: CGPoint, width: Double = 24, speed: Double = 1) {
            let a = pos
            let dx = target.x - a.x, dy = target.y - a.y
            let d = hypot(dx, dy)
            guard d > 0.5 else { return }
            let total = (0.16 + 0.11 * log2(d / width + 1)) / speed
            let primary = total * 0.82
            let reach = 1 - min(0.06, 6 / d) - rng.range(0, 0.025)
            let lateral = rng.range(-0.012, 0.012) * d
            let nx = -dy / d, ny = dx / d
            let bend = (rng.next() < 0.5 ? -1.0 : 1.0) * rng.range(0.03, 0.07) * d
            let mid = CGPoint(x: a.x + dx * reach + nx * lateral, y: a.y + dy * reach + ny * lateral)
            func minJerk(_ u: Double) -> Double { u * u * u * (10 - 15 * u + 6 * u * u) }
            trace(duration: primary) { u in
                let s = minJerk(u)
                let b = sin(.pi * s) * bend
                return CGPoint(x: a.x + (mid.x - a.x) * s + nx * b, y: a.y + (mid.y - a.y) * s + ny * b)
            }
            let start = pos
            trace(duration: total - primary) { u in
                let s = minJerk(u)
                return CGPoint(x: start.x + (target.x - start.x) * s, y: start.y + (target.y - start.y) * s)
            }
            sample(target, at: t)
        }

        /// Sets the cursor image; the recorder notices on its next 20 Hz poll.
        func setCursor(_ id: String) {
            guard id != cursor else { return }
            cursor = id
            let poll = (floor(t * 20) + 1) / 20 + 0.002
            events.append(InputEvent(t: (poll * 10_000).rounded() / 10_000, type: .cursor, image: id))
            events.sort { $0.t < $1.t }
        }

        /// Press and release; `pressed` shows the button down; `action` runs on release (like AppKit).
        func click(_ pressed: String? = nil, action: ((inout UIState) -> Void)? = nil) {
            let p = norm(pos)
            events.append(.down(t, p))
            clicks.append(t)
            if let pressed { change(at: t) { $0.pressed = pressed } }
            let hold = rng.range(0.075, 0.115)
            wait(hold)
            events.append(.up(t, p))
            ups.append(t)
            change(at: t) { s in s.pressed = nil; action?(&s) }
        }

        /// Types with human rhythm: ~8 characters a second, slower after spaces, a thinking pause or two.
        func type(_ s: String, pauseAfter: Set<Int> = []) {
            for (i, ch) in s.enumerated() {
                events.append(InputEvent(t: (t * 10_000).rounded() / 10_000, type: .key, chars: String(ch)))
                keys.append(t)
                let time = t
                change(at: time) { $0.text.append(ch); $0.lastKey = time }
                var gap = max(0.045, rng.range(0.07, 0.16))
                if ch == " " { gap += rng.range(0.03, 0.1) }
                if pauseAfter.contains(i) { gap += rng.range(0.45, 0.7) }
                wait(gap)
            }
        }

        /// Two-finger trackpad scroll: deltas at 60 Hz that decay, then momentum the app animates.
        func scroll(by total: Double, duration: Double = 0.7) {
            let steps = Int(duration * 60)
            let p = norm(pos)
            var weights = (0..<steps).map { i in exp(-Double(i) / Double(steps) * 3) }
            let sum = weights.reduce(0, +)
            weights = weights.map { $0 / sum }
            let t0 = t
            let from = scrollY
            for w in weights {
                let dy = -total * w
                events.append(InputEvent(t: (t * 10_000).rounded() / 10_000, type: .scroll, x: p.x, y: p.y, dx: 0, dy: (dy * 100).rounded() / 100))
                wait(1.0 / 60)
            }
            scrollY += total
            scrolls.append((t0, t0 + duration + 0.25, from, scrollY))
        }

        func finish(duration: Double) -> Recording {
            events.sort { $0.t < $1.t }
            return Recording(events: events, duration: duration, states: states, scrolls: scrolls,
                             clickTimes: clicks, upTimes: ups, keyTimes: keys)
        }
    }

    /// The scripted session (about 26 s).
    static func script() -> Recording {
        typealias L = Layout
        let p = Person(start: CGPoint(x: 820, y: 560))
        func c(_ r: CGRect, dx: Double = 0, dy: Double = 0) -> CGPoint { CGPoint(x: r.midX + dx, y: r.midY + dy) }

        p.wait(1.3)
        // 1. Pick "Inbox" in the sidebar.
        p.move(to: c(L.sidebarRow(0), dx: -30, dy: 1), width: 120)
        p.wait(0.25)
        p.click { $0.sidebar = 0 }
        p.wait(1.1)
        // 2. New task.
        p.move(to: c(L.newTaskButton, dx: 6, dy: -1), width: 110)
        p.wait(0.2)
        p.click("new") { $0.composerOpen = true; $0.text = "" }
        p.wait(0.5)
        // 3. Into the field and type.
        p.move(to: CGPoint(x: L.composerField.minX + 120, y: L.composerField.midY + 1), width: 300, speed: 1.1)
        p.setCursor("ibeam")
        p.wait(0.15)
        p.click()
        p.wait(0.45)
        p.type("Record the launch demo", pauseAfter: [9])
        p.wait(0.5)
        p.type(" for Friday")
        p.wait(0.7)
        // 4. Save.
        p.move(to: c(L.composerSave, dx: 2), width: 70)
        p.setCursor("arrow")
        p.wait(0.2)
        p.click("save") { s in
            s.tasks.insert(TodoItem(title: s.text, tag: 0, due: "Fri"), at: 0)
            s.composerOpen = false
        }
        p.wait(1.2)
        // 5. Look down the list.
        p.move(to: CGPoint(x: L.content.midX + 60, y: L.listTop + 300), width: 200)
        p.wait(0.4)
        p.scroll(by: 150)
        p.wait(1.0)
        p.scroll(by: -150, duration: 0.6)
        p.wait(0.8)
        // 6. Tick off a task.
        let row = 2.0
        p.move(to: CGPoint(x: L.content.minX + 46, y: L.listTop + CGFloat(row) * L.rowH + L.rowH / 2), width: 20)
        p.wait(0.3)
        p.click { s in s.checked.insert(s.tasks[Int(row)].title) }
        p.wait(1.4)
        // 7. Share the list.
        p.move(to: c(L.shareButton), width: 70)
        p.wait(0.25)
        p.click("share") { $0.popover = true }
        p.wait(0.7)
        p.move(to: c(L.copyButton, dx: -4), width: 90)
        p.wait(0.3)
        p.click("copy") { $0.copied = true }
        p.wait(1.2)
        // 8. Wander off and rest.
        p.move(to: CGPoint(x: 900, y: 620), width: 200, speed: 0.8)
        p.click { $0.popover = false; $0.copied = false }
        p.wait(2.5)
        return p.finish(duration: (p.t * 10).rounded(.up) / 10)
    }

    // MARK: Drawing

    static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
    static func gray(_ v: CGFloat, _ a: CGFloat = 1) -> CGColor { color(v, v, v, a) }
    static let accent = color(0.18, 0.44, 0.92)
    static let ink = color(0.11, 0.11, 0.13)
    static let secondary = color(0.42, 0.42, 0.46)

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> CTFont { NSFont.systemFont(ofSize: size, weight: weight) as CTFont }

    enum Align { case left, center, right }

    /// Draws one line of text with its baseline centred vertically in `rect` (flipped context).
    @discardableResult
    static func text(_ ctx: CGContext, _ s: String, _ rect: CGRect, size: CGFloat, weight: NSFont.Weight = .regular,
                     color: CGColor = ink, align: Align = .left, strike: Bool = false) -> CGFloat {
        let f = font(size, weight)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): f,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let x: CGFloat = switch align { case .left: rect.minX; case .center: rect.midX - w / 2; case .right: rect.maxX - w }
        let baseline = rect.midY + (ascent - descent) / 2
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        if strike {
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: x, y: baseline - ascent * 0.36, width: w, height: 1.2))
        }
        return w
    }

    static func fill(_ ctx: CGContext, _ r: CGRect, radius: CGFloat, _ c: CGColor) {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(c)
        ctx.fillPath()
    }

    static func stroke(_ ctx: CGContext, _ r: CGRect, radius: CGFloat, _ c: CGColor, width: CGFloat = 1) {
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: width / 2, dy: width / 2), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setStrokeColor(c)
        ctx.setLineWidth(width)
        ctx.strokePath()
    }

    /// Draws the whole screen for a UI state into a flipped (top-left origin) point-space context.
    static func draw(_ ctx: CGContext, state s: UIState, scroll: Double, caret: Bool) {
        typealias L = Layout
        let W = points.width, H = points.height
        // Wallpaper: a soft dusk gradient with two blurred hills.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let g = CGGradient(colorsSpace: space, colors: [color(0.35, 0.47, 0.66), color(0.62, 0.55, 0.66), color(0.93, 0.70, 0.58)] as CFArray,
                           locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: H), options: [])
        ctx.setFillColor(color(0.27, 0.32, 0.45, 0.55))
        ctx.addEllipse(in: CGRect(x: -200, y: H * 0.72, width: 1100, height: 600)); ctx.fillPath()
        ctx.setFillColor(color(0.36, 0.33, 0.48, 0.5))
        ctx.addEllipse(in: CGRect(x: 700, y: H * 0.78, width: 1200, height: 600)); ctx.fillPath()

        // Menu bar.
        ctx.setFillColor(gray(0.97, 0.78))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: L.menuBar))
        var x: CGFloat = 20
        for (i, m) in ["Tasks", "File", "Edit", "View", "Window", "Help"].enumerated() {
            x += text(ctx, m, CGRect(x: x, y: 0, width: 200, height: L.menuBar), size: 13, weight: i == 0 ? .bold : .regular) + 20
        }
        text(ctx, "Mon 12 Oct  9:41", CGRect(x: W - 220, y: 0, width: 200, height: L.menuBar), size: 13, align: .right)

        // Window shadow and body.
        let win = L.window
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 22), blur: 60, color: gray(0, 0.35))
        fill(ctx, win, radius: 12, gray(1))
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: win, cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.clip()
        ctx.setFillColor(gray(1)); ctx.fill(win)

        // Sidebar.
        let sb = L.sidebar
        ctx.setFillColor(color(0.955, 0.950, 0.944)); ctx.fill(sb)
        ctx.setFillColor(gray(0.86)); ctx.fill(CGRect(x: sb.maxX - 1, y: sb.minY, width: 1, height: sb.height))
        for (i, c) in [color(1, 0.37, 0.34), color(1, 0.74, 0.18), color(0.16, 0.79, 0.25)].enumerated() {
            ctx.setFillColor(c)
            ctx.addEllipse(in: CGRect(x: win.minX + 18 + CGFloat(i) * 20, y: win.minY + 21, width: 12, height: 12)); ctx.fillPath()
        }
        // Search field.
        let search = CGRect(x: sb.minX + 12, y: sb.minY + 52, width: sb.width - 24, height: 28)
        fill(ctx, search, radius: 7, gray(0, 0.06))
        text(ctx, "Search", search.insetBy(dx: 30, dy: 0), size: 13, color: secondary)
        ctx.setStrokeColor(secondary); ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: CGRect(x: search.minX + 10, y: search.midY - 6, width: 10, height: 10))
        ctx.move(to: CGPoint(x: search.minX + 18.5, y: search.midY + 2.5)); ctx.addLine(to: CGPoint(x: search.minX + 22, y: search.midY + 6)); ctx.strokePath()

        for (i, item) in L.sidebarItems.enumerated() {
            let r = L.sidebarRow(i)
            let selected = s.sidebar == i
            if selected { fill(ctx, r, radius: 7, color(0.18, 0.44, 0.92, 0.14)) }
            let ic = CGRect(x: r.minX + 10, y: r.midY - 7, width: 14, height: 14)
            ctx.setStrokeColor(selected ? accent : secondary); ctx.setLineWidth(1.6)
            ctx.addPath(CGPath(roundedRect: ic, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)); ctx.strokePath()
            text(ctx, item, CGRect(x: r.minX + 34, y: r.minY, width: 140, height: r.height), size: 13.5,
                 weight: selected ? .semibold : .regular, color: selected ? accent : ink)
            text(ctx, L.sidebarCounts[i], r.insetBy(dx: 12, dy: 0), size: 12.5, color: secondary, align: .right)
        }
        text(ctx, "PROJECTS", CGRect(x: sb.minX + 22, y: L.projectRow(0).minY - 30, width: 150, height: 24), size: 11, weight: .semibold, color: secondary)
        for (i, pr) in L.projects.enumerated() {
            let r = L.projectRow(i)
            ctx.setFillColor(color(pr.1.0, pr.1.1, pr.1.2))
            ctx.addEllipse(in: CGRect(x: r.minX + 13, y: r.midY - 4.5, width: 9, height: 9)); ctx.fillPath()
            text(ctx, pr.0, CGRect(x: r.minX + 34, y: r.minY, width: 170, height: r.height), size: 13.5)
        }
        // Account row at the bottom.
        let acct = CGRect(x: sb.minX + 14, y: sb.maxY - 46, width: sb.width - 28, height: 32)
        ctx.setFillColor(color(0.93, 0.62, 0.42))
        ctx.addEllipse(in: CGRect(x: acct.minX, y: acct.midY - 13, width: 26, height: 26)); ctx.fillPath()
        text(ctx, "MR", CGRect(x: acct.minX, y: acct.minY, width: 26, height: acct.height), size: 10.5, weight: .bold, color: gray(1), align: .center)
        text(ctx, "Maya Rivera", CGRect(x: acct.minX + 36, y: acct.minY, width: 160, height: acct.height), size: 13, weight: .medium)

        // Toolbar.
        let content = L.content
        ctx.setFillColor(gray(0.88)); ctx.fill(CGRect(x: content.minX, y: win.minY + L.toolbarH - 1, width: content.width, height: 1))
        let title = s.sidebar == 0 ? "Inbox" : (s.sidebar == 1 ? "Today" : L.sidebarItems[s.sidebar])
        text(ctx, title, CGRect(x: content.minX + 24, y: win.minY, width: 300, height: L.toolbarH), size: 15, weight: .semibold)
        let nb = L.newTaskButton
        fill(ctx, nb, radius: 7, s.pressed == "new" ? color(0.12, 0.34, 0.78) : accent)
        text(ctx, "+  New Task", nb, size: 13, weight: .semibold, color: gray(1), align: .center)
        let shb = L.shareButton
        fill(ctx, shb, radius: 7, s.pressed == "share" || s.popover ? gray(0, 0.13) : gray(0, 0.06))
        text(ctx, "Share", shb, size: 13, weight: .medium, align: .center)

        // Header.
        let header = CGRect(x: content.minX + 32, y: win.minY + L.toolbarH + 22, width: 500, height: 36)
        text(ctx, title, header, size: 26, weight: .bold)
        let open = s.tasks.filter { !s.checked.contains($0.title) }.count
        text(ctx, "Monday, 12 October  ·  \(open) open", CGRect(x: header.minX, y: header.maxY + 2, width: 400, height: 22), size: 13, color: secondary)

        // Task list (scrolls under the header).
        let listClip = CGRect(x: content.minX, y: L.listTop - 6, width: content.width, height: win.maxY - L.listTop + 6)
        ctx.saveGState()
        ctx.clip(to: listClip)
        let offset: CGFloat = s.composerOpen ? L.composer.height + 16 : 0
        let tagNames = ["Website", "Mobile", "Planning", "Hiring"]
        for (i, task) in s.tasks.enumerated() {
            let y = L.listTop + offset + CGFloat(i) * L.rowH - CGFloat(scroll)
            if y > win.maxY || y + L.rowH < listClip.minY { continue }
            let r = CGRect(x: content.minX + 32, y: y, width: content.width - 64, height: L.rowH)
            let done = s.checked.contains(task.title)
            let box = CGRect(x: r.minX + 4, y: r.midY - 10, width: 20, height: 20)
            if done {
                ctx.setFillColor(accent); ctx.addEllipse(in: box); ctx.fillPath()
                ctx.setStrokeColor(gray(1)); ctx.setLineWidth(2.2); ctx.setLineCap(.round); ctx.setLineJoin(.round)
                ctx.move(to: CGPoint(x: box.minX + 5.5, y: box.midY + 0.5))
                ctx.addLine(to: CGPoint(x: box.minX + 8.8, y: box.midY + 3.8))
                ctx.addLine(to: CGPoint(x: box.maxX - 5, y: box.midY - 3.5)); ctx.strokePath()
            } else {
                ctx.setStrokeColor(gray(0.62)); ctx.setLineWidth(1.6)
                ctx.strokeEllipse(in: box.insetBy(dx: 0.8, dy: 0.8))
            }
            text(ctx, task.title, CGRect(x: r.minX + 40, y: r.minY, width: 520, height: r.height), size: 14.5,
                 color: done ? secondary : ink, strike: done)
            let pc = L.projects[task.tag].1
            let tagW: CGFloat = 78
            let tag = CGRect(x: r.maxX - 210, y: r.midY - 11, width: tagW, height: 22)
            fill(ctx, tag, radius: 11, color(pc.0, pc.1, pc.2, 0.15))
            text(ctx, tagNames[task.tag], tag, size: 12, weight: .medium, color: color(pc.0 * 0.75, pc.1 * 0.75, pc.2 * 0.75), align: .center)
            text(ctx, task.due, CGRect(x: r.maxX - 120, y: r.minY, width: 112, height: r.height), size: 13, color: secondary, align: .right)
            ctx.setFillColor(gray(0.92)); ctx.fill(CGRect(x: r.minX + 40, y: r.maxY - 0.5, width: r.width - 40, height: 1))
        }
        ctx.restoreGState()

        // Composer.
        if s.composerOpen {
            let cp = L.composer
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 18, color: gray(0, 0.14))
            fill(ctx, cp, radius: 12, gray(1))
            ctx.restoreGState()
            stroke(ctx, cp, radius: 12, gray(0.85))
            let f = L.composerField
            fill(ctx, f, radius: 8, gray(0.975))
            stroke(ctx, f, radius: 8, color(0.18, 0.44, 0.92, 0.85), width: 2)
            let tr = f.insetBy(dx: 12, dy: 0)
            if s.text.isEmpty {
                text(ctx, "Task name", tr, size: 15, color: gray(0.62))
                if caret { ctx.setFillColor(accent); ctx.fill(CGRect(x: tr.minX, y: f.midY - 9, width: 2, height: 18)) }
            } else {
                let w = text(ctx, s.text, tr, size: 15)
                if caret { ctx.setFillColor(accent); ctx.fill(CGRect(x: tr.minX + w + 1, y: f.midY - 9, width: 2, height: 18)) }
            }
            let row = CGRect(x: cp.minX + 16, y: cp.maxY - 44, width: 300, height: 30)
            ctx.setFillColor(color(0.96, 0.55, 0.20))
            ctx.addEllipse(in: CGRect(x: row.minX + 2, y: row.midY - 4.5, width: 9, height: 9)); ctx.fillPath()
            text(ctx, "Website relaunch  ·  Due Friday", row.offsetBy(dx: 20, dy: 0), size: 13, color: secondary)
            fill(ctx, L.composerCancel, radius: 7, gray(0, 0.06))
            text(ctx, "Cancel", L.composerCancel, size: 13, weight: .medium, align: .center)
            fill(ctx, L.composerSave, radius: 7, s.pressed == "save" ? color(0.12, 0.34, 0.78) : accent)
            text(ctx, "Save", L.composerSave, size: 13, weight: .semibold, color: gray(1), align: .center)
        }
        ctx.restoreGState()  // window clip

        // Share popover.
        if s.popover {
            let pop = L.popover
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: gray(0, 0.22))
            fill(ctx, pop, radius: 12, gray(1))
            ctx.restoreGState()
            stroke(ctx, pop, radius: 12, gray(0.84))
            text(ctx, "Share “Today”", CGRect(x: pop.minX + 18, y: pop.minY + 12, width: 300, height: 24), size: 14, weight: .semibold)
            text(ctx, "Anyone with the link can view", CGRect(x: pop.minX + 18, y: pop.minY + 36, width: 300, height: 20), size: 12.5, color: secondary)
            let url = CGRect(x: pop.minX + 18, y: pop.maxY - 50, width: pop.width - 150, height: 32)
            fill(ctx, url, radius: 7, gray(0, 0.05))
            text(ctx, "tasks.app/s/7Hk2pQx9", url.insetBy(dx: 10, dy: 0), size: 13)
            let cb = L.copyButton
            fill(ctx, cb, radius: 7, s.pressed == "copy" ? color(0.12, 0.34, 0.78) : (s.copied ? color(0.16, 0.62, 0.32) : accent))
            text(ctx, s.copied ? "✓ Copied" : "Copy link", cb, size: 13, weight: .semibold, color: gray(1), align: .center)
        }
    }

    // MARK: Cursor images (2x PNG + metadata, exactly like `CursorRecorder`)

    static func cursorImage(_ id: String) -> (CGImage, CursorImageInfo) {
        let pt: CGSize, hot: CGPoint
        switch id {
        case "ibeam": pt = CGSize(width: 12, height: 22); hot = CGPoint(x: 6, y: 11)
        default: pt = CGSize(width: 20, height: 26); hot = CGPoint(x: 4, y: 4)
        }
        let w = Int(pt.width) * 2, h = Int(pt.height) * 2
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 2, y: -2)
        ctx.setLineJoin(.round); ctx.setLineCap(.round)
        if id == "ibeam" {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 3, y: 2)); path.addQuadCurve(to: CGPoint(x: 6, y: 4), control: CGPoint(x: 6, y: 2))
            path.addQuadCurve(to: CGPoint(x: 9, y: 2), control: CGPoint(x: 6, y: 2))
            path.move(to: CGPoint(x: 6, y: 4)); path.addLine(to: CGPoint(x: 6, y: 18))
            path.move(to: CGPoint(x: 3, y: 20)); path.addQuadCurve(to: CGPoint(x: 6, y: 18), control: CGPoint(x: 6, y: 20))
            path.addQuadCurve(to: CGPoint(x: 9, y: 20), control: CGPoint(x: 6, y: 20))
            ctx.addPath(path); ctx.setStrokeColor(gray(1)); ctx.setLineWidth(3.2); ctx.strokePath()
            ctx.addPath(path); ctx.setStrokeColor(gray(0)); ctx.setLineWidth(1.4); ctx.strokePath()
        } else {
            let pts: [CGPoint] = [CGPoint(x: 4, y: 4), CGPoint(x: 4, y: 20.5), CGPoint(x: 8, y: 16.8), CGPoint(x: 10.8, y: 23.2),
                                  CGPoint(x: 13.6, y: 22.1), CGPoint(x: 10.9, y: 15.8), CGPoint(x: 16.2, y: 15.8)]
            let path = CGMutablePath(); path.addLines(between: pts); path.closeSubpath()
            ctx.addPath(path); ctx.setStrokeColor(gray(1)); ctx.setLineWidth(2.4); ctx.strokePath()
            ctx.addPath(path); ctx.setFillColor(gray(0)); ctx.fillPath()
        }
        return (ctx.makeImage()!, CursorImageInfo(id: id, hotX: hot.x * 2, hotY: hot.y * 2, width: pt.width, height: pt.height))
    }

    // MARK: Microphone

    /// Room tone, mouse clicks (press and release) and keys, 48 kHz mono.
    static func microphone(_ r: Recording) -> [Float] {
        let rate = 48_000.0
        let n = Int(r.duration * rate)
        var out = [Float](repeating: 0, count: n)
        var rng = RNG(s: 77)
        // Room tone: pink-ish noise around -52 dBFS.
        var b0 = 0.0, b1 = 0.0, b2 = 0.0
        for i in 0..<n {
            let w = rng.next() * 2 - 1
            b0 = 0.99765 * b0 + w * 0.0990460; b1 = 0.96300 * b1 + w * 0.2965164; b2 = 0.57000 * b2 + w * 1.0526913
            out[i] = Float((b0 + b1 + b2 + w * 0.1848) * 0.0007)
        }
        func burst(at t: Double, freq: Double, decay: Double, gain: Double) {
            let start = Int(t * rate)
            let len = Int(decay * 8 * rate)
            var nrng = RNG(s: UInt64(t * 1e6))
            for k in 0..<len where start + k >= 0 && start + k < n {
                let tt = Double(k) / rate
                let env = exp(-tt / decay)
                let v = (sin(2 * .pi * freq * tt) * 0.6 + (nrng.next() * 2 - 1) * 0.4) * env * gain
                out[start + k] += Float(v)
            }
        }
        for t in r.clickTimes { burst(at: t, freq: 2600, decay: 0.0035, gain: 0.55) }
        for t in r.upTimes { burst(at: t, freq: 3200, decay: 0.0025, gain: 0.3) }
        for (i, t) in r.keyTimes.enumerated() { burst(at: t, freq: 1400 + Double(i % 5) * 140, decay: 0.006, gain: 0.22) }
        return out
    }

    // MARK: Bundle

    /// Writes a complete bundle (screen HEVC 2880×1800 VFR, microphone AAC, events, cursors) at `url`.
    static func makeBundle(at url: URL) async throws -> ProjectBundle {
        try? FileManager.default.removeItem(at: url)
        let bundle = try ProjectBundle.create(at: url)
        let fm = FileManager.default
        for k in [TrackKind.screen, .microphone] { try fm.createDirectory(at: bundle.directory(for: k), withIntermediateDirectories: true) }
        let rec = script()
        let pw = Int(points.width) * scale, ph = Int(points.height) * scale
        try await writeScreen(url: bundle.directory(for: .screen).appendingPathComponent("screen.mp4"), recording: rec, width: pw, height: ph)
        try await writePCM(url: bundle.directory(for: .microphone).appendingPathComponent("microphone.m4a"), samples: microphone(rec))

        let tracks = [
            TrackInfo(kind: .screen, directory: "screen", file: "screen/screen.mp4", codec: "hevc",
                      pixelSize: PixelSize(width: pw, height: ph), duration: rec.duration),
            TrackInfo(kind: .microphone, directory: "microphone", file: "microphone/microphone.m4a", codec: "aac",
                      sampleRate: 48_000, channels: 1, duration: rec.duration),
        ]
        let manifest = ProjectManifest(title: "Tasks demo", appVersion: "demo", status: .complete,
                                       capture: CaptureInfo(source: .display(id: 1, name: "Built-in Retina Display"),
                                                            pixelSize: PixelSize(width: pw, height: ph), scale: Double(scale), frameRate: fps),
                                       clock: ClockInfo(originHostTime: 0), tracks: tracks, duration: rec.duration)
        try bundle.writeManifest(manifest)
        let log = try EventLogWriter(url: bundle.eventsURL)
        for e in rec.events { log.append(e) }
        log.close()
        var infos: [CursorImageInfo] = []
        for id in ["arrow", "ibeam"] {
            let (img, info) = cursorImage(id)
            let dest = CGImageDestinationCreateWithURL(bundle.cursorsURL.appendingPathComponent("\(id).png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
            infos.append(info)
        }
        try JSONCoding.writeAtomically(infos, to: bundle.cursorIndexURL)
        return bundle
    }

    /// Variable-frame-rate screen video: a frame is written only when the picture changes.
    static func writeScreen(url: URL, recording rec: Recording, width: Int, height: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 24_000_000, AVVideoAllowFrameReorderingKey: false,
                                              AVVideoExpectedSourceFrameRateKey: fps],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let frames = Int(rec.duration * Double(fps))
        struct Key: Hashable { var state: UIState; var scroll: Int; var caret: Bool }
        var last: Key?
        for n in 0..<frames {
            let t = Double(n) / Double(fps)
            let s = rec.state(at: t)
            let typingRecently = t - s.lastKey < 0.5
            let caret = s.composerOpen && (typingRecently || Int((t - s.lastKey) / 0.53) % 2 == 0)
            let scroll = rec.scroll(at: t)
            let key = Key(state: s, scroll: Int((scroll * 4).rounded()), caret: caret)
            if key == last, n != frames - 1 { continue }
            last = key
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            guard let pb else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
            draw(ctx, state: s, scroll: scroll, caret: caret)
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: Int64(n), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// Encodes mono float samples at 48 kHz to AAC.
    static func writePCM(url: URL, samples: [Float]) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
                                               mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &fmt)
        let chunk = 4800
        var pos = 0
        while pos < samples.count {
            let n = min(chunk, samples.count - pos)
            var bb: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n * 4, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: n * 4, flags: 0, blockBufferOut: &bb)
            samples[pos..<(pos + n)].withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb!, offsetIntoDestination: 0, dataLength: n * 4) }
            var sb: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: bb!, formatDescription: fmt!, sampleCount: n,
                                                                 presentationTimeStamp: CMTime(value: Int64(pos), timescale: 48_000),
                                                                 packetDescriptions: nil, sampleBufferOut: &sb)
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            input.append(sb!)
            pos += n
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
