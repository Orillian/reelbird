import AVFoundation
import AppKit
import QuartzCore
import ReelbirdCapture
import ReelbirdCore
import SwiftUI

// MARK: Model

/// What the live camera bubble and its toolbar show. The controller animates it.
@MainActor @Observable final class CameraBubbleModel {
    var shape: CameraLayout.Shape
    var size: CameraBubbleSize
    /// The outline being drawn: springs between the shapes' corners.
    var corner: CameraBubbleCorner
    /// 0 hidden … 1 shown: the bubble scales and fades in and out.
    var presence: Double = 1
    /// Picked up for a drag: the shadow grows and the bubble rises a little.
    var lifted = false
    /// The pointer is over the bubble or over its toolbar.
    var hovering = false
    var toolbarHovering = false
    /// The toolbar is showing, and on which side of the bubble.
    var toolbarVisible = false
    var toolbarAbove = true

    init(shape: CameraLayout.Shape, size: CameraBubbleSize) {
        self.shape = shape
        self.size = size
        corner = CameraBubbleCorner(shape)
    }
}

// MARK: Motion

/// A damped spring on each of a few values (the bubble's x, y, width, height, corner radius and exponent),
/// stepped in fixed substeps so it behaves the same at 60 or 120 Hz and in frame dumps.
struct BubbleSpring {
    struct Style: Hashable {
        /// Seconds for one undamped oscillation; smaller is quicker.
        var response: Double
        /// 1 = no overshoot; below 1 overshoots a little.
        var damping: Double
    }
    /// S/M/L: a small overshoot, the "bob" (about 4%), visually there in ~300 ms.
    static let resize = Style(response: 0.4, damping: 0.7)
    /// Shape changes: smooth, barely overshooting, visually done in ~270 ms.
    static let morph = Style(response: 0.42, damping: 0.86)
    /// Back on screen after a drag left it partly off.
    static let settle = Style(response: 0.36, damping: 0.8)

    var value: [Double]
    var velocity: [Double]
    var target: [Double]
    var style = BubbleSpring.morph
    /// Per value: closer than this (and slower than 10× this per second) counts as arrived.
    let tolerance: [Double]

    init(value: [Double], tolerance: [Double]) {
        self.value = value
        velocity = Array(repeating: 0, count: value.count)
        target = value
        self.tolerance = tolerance
    }

    mutating func animate(to target: [Double], style: Style) {
        self.target = target
        self.style = style
    }

    mutating func step(_ dt: Double) {
        let k = pow(2 * .pi / style.response, 2), c = 4 * .pi * style.damping / style.response
        var left = min(max(0, dt), 0.1)
        while left > 1e-9 {
            let h = min(left, 1.0 / 480)
            left -= h
            for i in value.indices {
                velocity[i] += (-k * (value[i] - target[i]) - c * velocity[i]) * h
                value[i] += velocity[i] * h
            }
        }
    }

    var isSettled: Bool {
        value.indices.allSatisfy { abs(value[$0] - target[$0]) < tolerance[$0] && abs(velocity[$0]) < tolerance[$0] * 10 }
    }

    mutating func finish() {
        value = target
        velocity = Array(repeating: 0, count: value.count)
    }

    /// The values frame by frame at `fps` until the spring settles (at most `limit` frames), for design review.
    static func frames(from: [Double], to: [Double], style: Style, tolerance: [Double], fps: Double = 60, limit: Int = 90) -> [[Double]] {
        var s = BubbleSpring(value: from, tolerance: tolerance)
        s.animate(to: to, style: style)
        var out = [from]
        while out.count < limit, !s.isSettled {
            s.step(1 / fps)
            out.append(s.value)
        }
        return out
    }
}

/// Where the bubble may sit and how it grows. Rectangles are in screen points with AppKit's bottom-left origin.
enum BubbleLayout {
    /// The room the bubble keeps to on a screen: clear of the menu bar and of a Dock on the left or right. A Dock
    /// along the bottom may be overlapped, like the default spot (the editor's corner inset) does: the bubble
    /// floats above it.
    static func bounds(frame: CGRect, visible: CGRect) -> CGRect {
        CGRect(x: visible.minX, y: frame.minY, width: visible.width, height: max(0, visible.maxY - frame.minY))
    }

    /// `r` moved the least distance to lie inside `b` (centred on an axis where it can't fit).
    static func clamped(_ r: CGRect, in b: CGRect) -> CGRect {
        func axis(_ lo: CGFloat, _ len: CGFloat, _ bLo: CGFloat, _ bLen: CGFloat) -> CGFloat {
            len >= bLen ? bLo + (bLen - len) / 2 : min(max(lo, bLo), bLo + bLen - len)
        }
        return CGRect(x: axis(r.minX, r.width, b.minX, b.width), y: axis(r.minY, r.height, b.minY, b.height),
                      width: r.width, height: r.height)
    }

    /// `r` at a new size, growing away from the screen edges it is near: in the outer thirds of the room the
    /// near edge stays put, in the middle third the centre does. Then kept fully inside `b`.
    static func resized(_ r: CGRect, to size: CGSize, in b: CGRect) -> CGRect {
        func axis(_ lo: CGFloat, _ len: CGFloat, _ newLen: CGFloat, _ bLo: CGFloat, _ bLen: CGFloat) -> CGFloat {
            let f = bLen > 0 ? (lo + len / 2 - bLo) / bLen : 0.5
            if f < 1.0 / 3 { return lo }
            if f > 2.0 / 3 { return lo + len - newLen }
            return lo + (len - newLen) / 2
        }
        let moved = CGRect(x: axis(r.minX, r.width, size.width, b.minX, b.width),
                           y: axis(r.minY, r.height, size.height, b.minY, b.height),
                           width: size.width, height: size.height)
        return clamped(moved, in: b)
    }

    /// The lines a dropped bubble settles onto, as in the editor: against each edge at the editor's inset
    /// (`CameraLayout.inset` of the screen's shorter side; the left and right edges and the top are those of the
    /// visible frame, so a side Dock and the menu bar count as edges; the bottom is the screen's, like the default
    /// spot) and centred. An axis within `tolerance` of a line snaps to it, so live places land on clean
    /// placements: a corner, an edge's middle, the centre.
    static func snapped(_ r: CGRect, frame f: CGRect, visible v: CGRect, tolerance: CGFloat) -> CGRect {
        let m = CameraLayout().inset * min(f.width, f.height)
        func axis(_ lo: CGFloat, _ lines: [CGFloat]) -> CGFloat {
            lines.min(by: { abs($0 - lo) < abs($1 - lo) }).flatMap { abs($0 - lo) <= tolerance ? $0 : nil } ?? lo
        }
        let x = axis(r.minX, [max(f.minX, v.minX) + m, f.midX - r.width / 2, min(f.maxX, v.maxX) - m - r.width])
        let y = axis(r.minY, [f.minY + m, f.midY - r.height / 2, min(f.maxY, v.maxY) - m - r.height])
        return CGRect(x: x, y: y, width: r.width, height: r.height)
    }

    /// The toolbar's frame: centred over the bubble, above it when there is room below the menu bar, otherwise
    /// below it; kept on screen sideways.
    static func toolbar(for bubble: CGRect, size: CGSize, visible: CGRect, gap: CGFloat) -> (frame: CGRect, above: Bool) {
        let above = bubble.maxY + gap + size.height <= visible.maxY - 4
        let y = above ? bubble.maxY + gap : bubble.minY - gap - size.height
        let x = min(max(bubble.midX - size.width / 2, visible.minX + 4), visible.maxX - 4 - size.width)
        return (CGRect(x: x, y: y, width: size.width, height: size.height), above)
    }
}

/// Calls back once per display refresh while running (a timer in automated runs and off screen).
@MainActor private final class FrameDriver: NSObject {
    private var link: CADisplayLink?
    private var timer: Timer?
    private var last: CFTimeInterval?
    private let onFrame: (Double) -> Void

    init(onFrame: @escaping (Double) -> Void) { self.onFrame = onFrame }

    var isRunning: Bool { link != nil || timer != nil }

    func start(on view: NSView) {
        guard !isRunning else { return }
        last = nil
        if AutomatedRun.isSilent || view.window?.screen == nil {
            let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.frame(at: CACurrentMediaTime()) }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            let l = view.displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
    }

    func stop() {
        link?.invalidate(); link = nil
        timer?.invalidate(); timer = nil
    }

    @objc private func tick(_ l: CADisplayLink) { frame(at: l.targetTimestamp) }

    private func frame(at t: CFTimeInterval) {
        let dt = last.map { t - $0 } ?? 1.0 / 60
        last = t
        onFrame(dt)
    }
}

// MARK: Controller

@MainActor final class CameraBubbleController {
    private var panel: FloatingPanel?
    private var toolbarPanel: FloatingPanel?
    private(set) var model: CameraBubbleModel?
    private var deviceID: String?
    private var builtWithAccess = false
    private let services: Services
    private let prefs: Preferences
    private var moveObserver: (any NSObjectProtocol)?
    private var settleTask: Task<Void, Never>?
    private var dragTask: Task<Void, Never>?
    private var toolbarTask: Task<Void, Never>?
    private var spring: BubbleSpring?
    private lazy var driver = FrameDriver { [weak self] dt in self?.frame(dt) }
    /// The toolbar stays up regardless of the pointer (self test, snapshots).
    var pinsToolbar = false { didSet { updateToolbar() } }
    /// Host time of the last window move (when the bubble got to where the drag left it).
    private var lastMoveHost: Double?
    /// Space around the visible bubble inside the panel: room for its shadow, also when lifted.
    static let padding: CGFloat = 28
    /// Space around the toolbar inside its panel (its shadow).
    static let toolbarPadding: CGFloat = 12
    /// Gap between the bubble and its toolbar.
    static let toolbarGap: CGFloat = 8
    /// A dropped bubble this close to an edge line or a centre line settles onto it.
    static let snapDistance: CGFloat = 24
    /// Self test: a stand-in screen (frame and visible frame) instead of the real ones.
    var screenOverride: (frame: CGRect, visible: CGRect)?

    /// Called with the bubble's visible frame (global points, top-left origin; `nil` when it hides), its shape
    /// and the host time it got there: when it appears and whenever a drag, resize or shape change ends.
    var onPlace: ((CGRect?, CameraLayout.Shape, Double?) -> Void)?

    init(services: Services, prefs: Preferences) {
        self.services = services
        self.prefs = prefs
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func show(deviceID: String) {
        // Rebuild when camera access changed too: a bubble made before access was granted only holds a placeholder.
        let access = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        if panel != nil && self.deviceID == deviceID && builtWithAccess == access { return }
        let previous = bubbleFrame
        hide(report: false)
        self.deviceID = deviceID
        builtWithAccess = access
        let model = CameraBubbleModel(shape: prefs.cameraShape, size: prefs.cameraBubbleSize)
        self.model = model
        let size = prefs.cameraBubbleSize.size(prefs.cameraShape)
        let screen = screenFor(previous.map { CGPoint(x: $0.midX, y: $0.midY) })
        var rect: CGRect
        if let previous {
            rect = CGRect(x: previous.minX, y: previous.maxY - size.height, width: size.width, height: size.height)
        } else {
            let panelSize = NSSize(width: size.width + Self.padding * 2, height: size.height + Self.padding * 2)
            let o = Self.defaultOrigin(size: panelSize, frame: screen.frame, visible: screen.visible)
            rect = CGRect(x: o.x + Self.padding, y: o.y + Self.padding, width: size.width, height: size.height)
        }
        rect = BubbleLayout.clamped(rect, in: BubbleLayout.bounds(frame: screen.frame, visible: screen.visible))

        // Never key: dragging the bubble mustn't take focus from the app being recorded. It stays
        // out of the screen capture too: the camera is its own track, composited in the editor.
        let p = FloatingPanel(size: rect.insetBy(dx: -Self.padding, dy: -Self.padding).size, level: .statusBar, allowsKey: false)
        p.setFrame(rect.insetBy(dx: -Self.padding, dy: -Self.padding), display: false)
        let camera = services.inputs.makeCameraView(deviceID: deviceID)
        p.contentView = FirstMouseHostingView(rootView: CameraBubbleView(camera: camera, model: model, actions: actions))
        spring = BubbleSpring(value: Self.vector(rect, model.corner), tolerance: [0.2, 0.2, 0.2, 0.2, 0.002, 0.01])
        panel = p
        model.presence = 0
        p.fadeIn()
        withAnimation(reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.38, dampingFraction: 0.78)) { model.presence = 1 }
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelMoved() }
        }
        reportPlace()
    }

    /// Bottom right, the editor's default corner, with the same inset (`CameraLayout.inset` of the screen's shorter side).
    /// The bubble floats above a Dock along the bottom; a Dock on the right moves it in. `size` includes the padding.
    static func defaultOrigin(size: NSSize, screen: NSScreen) -> NSPoint {
        defaultOrigin(size: size, frame: screen.frame, visible: screen.visibleFrame)
    }

    static func defaultOrigin(size: NSSize, frame f: CGRect, visible v: CGRect) -> NSPoint {
        let inset = CameraLayout().inset * min(f.width, f.height)
        return NSPoint(x: min(f.maxX, v.maxX) - inset - size.width + padding, y: f.minY + inset - padding)
    }

    private var actions: CameraBubbleActions {
        CameraBubbleActions(
            shape: { [weak self] s in self?.setShape(s) },
            size: { [weak self] s in self?.resize(s) },
            hover: { [weak self] h in self?.model?.hovering = h; self?.updateToolbar() },
            toolbarHover: { [weak self] h in self?.model?.toolbarHovering = h; self?.updateToolbar() },
            press: { [weak self] in self?.dragBegan() })
    }

    // MARK: Shape and size

    func resize(_ size: CameraBubbleSize) {
        prefs.cameraBubbleSize = size
        model?.size = size
        relayout(style: BubbleSpring.resize)
    }

    func setShape(_ shape: CameraLayout.Shape) {
        prefs.cameraShape = shape
        model?.shape = shape
        relayout(style: BubbleSpring.morph)
    }

    /// Springs to the chosen size and shape, growing away from the nearest screen edges and staying on screen.
    private func relayout(style: BubbleSpring.Style) {
        guard let current = bubbleFrame else { return }
        let size = prefs.cameraBubbleSize.size(prefs.cameraShape)
        let screen = screenFor(CGPoint(x: current.midX, y: current.midY))
        // From where the bubble is headed, so quick clicks chain smoothly.
        let from = spring.map { Self.rect($0.target) } ?? current
        let target = BubbleLayout.resized(from, to: size, in: BubbleLayout.bounds(frame: screen.frame, visible: screen.visible))
        animate(to: target, corner: CameraBubbleCorner(prefs.cameraShape), style: style)
    }

    private func animate(to rect: CGRect, corner: CameraBubbleCorner, style: BubbleSpring.Style) {
        guard panel != nil, var s = spring else { return }
        s.animate(to: Self.vector(rect, corner), style: style)
        spring = s
        if reduceMotion {
            spring?.finish()
            apply()
            finished()
            return
        }
        if let view = panel?.contentView { driver.start(on: view) }
    }

    /// Whether a shape, size or settle animation is running.
    var isAnimating: Bool { driver.isRunning }

    private func frame(_ dt: Double) {
        guard spring != nil else { driver.stop(); return }
        spring?.step(dt)
        if spring?.isSettled == true {
            spring?.finish()
            apply()
            finished()
        } else {
            apply()
        }
    }

    private func finished() {
        driver.stop()
        reportPlace(at: RecordingSession.hostTime)
    }

    /// Puts the panel and the outline where the spring is now. The camera view is only resized, never rebuilt,
    /// so the feed keeps running through the animation.
    private func apply() {
        guard let p = panel, let v = spring?.value else { return }
        let r = Self.rect(v)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        p.setFrame(r.insetBy(dx: -Self.padding, dy: -Self.padding), display: true)
        CATransaction.commit()
        model?.corner = CameraBubbleCorner(radius: v[4], exponent: v[5])
        positionToolbar()
    }

    private static func vector(_ r: CGRect, _ c: CameraBubbleCorner) -> [Double] {
        [r.minX, r.minY, r.width, r.height, c.radius, c.exponent]
    }

    private static func rect(_ v: [Double]) -> CGRect { CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) }

    // MARK: Dragging

    private func dragBegan() {
        guard let model else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.8)) { model.lifted = true }
        updateToolbar()
        dragTask?.cancel()
        dragTask = Task { [weak self] in
            // The drag runs in AppKit; poll for the release.
            while NSEvent.pressedMouseButtons & 1 != 0 {
                try? await Task.sleep(for: .milliseconds(25))
                if Task.isCancelled { return }
            }
            self?.dragEnded()
        }
    }

    private func dragEnded() {
        guard let model else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.62)) { model.lifted = false }
        settleTask?.cancel()
        // The window is where the drag left it; keep the spring in step, then ease back on screen if it hangs off.
        if let current = bubbleFrame, var s = spring {
            s.value[0] = current.minX; s.value[1] = current.minY
            s.target[0] = current.minX; s.target[1] = current.minY
            spring = s
            let screen = screenFor(CGPoint(x: current.midX, y: current.midY))
            let inside = BubbleLayout.clamped(current, in: BubbleLayout.bounds(frame: screen.frame, visible: screen.visible))
            let snapped = BubbleLayout.snapped(inside, frame: screen.frame, visible: screen.visible, tolerance: Self.snapDistance)
            if abs(snapped.minX - current.minX) > 0.5 || abs(snapped.minY - current.minY) > 0.5 {
                animate(to: snapped, corner: model.corner, style: BubbleSpring.settle)
            } else {
                reportPlace(at: lastMoveHost)
            }
        }
        updateToolbar()
    }

    /// The window moved (dragged): report once the mouse is up and it has settled. Our own animation frames
    /// don't count: the place is reported when the animation ends.
    private func panelMoved() {
        guard !driver.isRunning else { return }
        lastMoveHost = RecordingSession.hostTime
        if model?.lifted == true { return } // dragEnded reports
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            repeat {
                try? await Task.sleep(for: .milliseconds(80))
                if Task.isCancelled { return }
            } while NSEvent.pressedMouseButtons != 0
            self?.reportPlace(at: self?.lastMoveHost)
        }
    }

    // MARK: Toolbar

    /// Shows the toolbar while the pointer is over the bubble or the toolbar (not while dragging); hides it a
    /// moment after the pointer leaves both, so crossing the gap between them doesn't flicker.
    private func updateToolbar() {
        guard let model else { return }
        let wanted = (pinsToolbar || model.hovering || model.toolbarHovering) && !model.lifted
        toolbarTask?.cancel()
        if wanted {
            showToolbar()
        } else {
            toolbarTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(model.lifted ? 0 : 280))
                if Task.isCancelled { return }
                self?.hideToolbar()
            }
        }
    }

    private func showToolbar() {
        guard let model, panel != nil else { return }
        let t = toolbarPanel ?? makeToolbarPanel(model: model)
        toolbarPanel = t
        positionToolbar()
        t.ignoresMouseEvents = false
        if !t.isVisible { t.orderFrontRegardless() }
        if !model.toolbarVisible {
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.26, dampingFraction: 0.82)) { model.toolbarVisible = true }
        }
    }

    private func hideToolbar() {
        guard let model, model.toolbarVisible else { return }
        toolbarPanel?.ignoresMouseEvents = true
        withAnimation(.easeIn(duration: 0.12)) { model.toolbarVisible = false }
        toolbarTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            if Task.isCancelled { return }
            if self?.model?.toolbarVisible == false { self?.toolbarPanel?.orderOut(nil) }
        }
    }

    private func makeToolbarPanel(model: CameraBubbleModel) -> FloatingPanel {
        let size = Self.toolbarPanelSize
        let t = FloatingPanel(size: size, level: .statusBar, allowsKey: false)
        t.isMovableByWindowBackground = false
        t.animationBehavior = .none
        let view = CameraBubbleToolbar(model: model, actions: actions).padding(Self.toolbarPadding)
        t.contentView = FirstMouseHostingView(rootView: view)
        t.setContentSize(size)
        return t
    }

    static var toolbarPanelSize: NSSize {
        NSSize(width: CameraBubbleToolbar.width + toolbarPadding * 2, height: CameraBubbleToolbar.height + toolbarPadding * 2)
    }

    private func positionToolbar() {
        guard let t = toolbarPanel, let model, let bubble = bubbleFrame else { return }
        let screen = screenFor(CGPoint(x: bubble.midX, y: bubble.midY))
        let size = CGSize(width: CameraBubbleToolbar.width, height: CameraBubbleToolbar.height)
        let (f, above) = BubbleLayout.toolbar(for: bubble, size: size, visible: screen.visible, gap: Self.toolbarGap)
        if model.toolbarAbove != above { model.toolbarAbove = above }
        t.setFrameOrigin(NSPoint(x: f.minX - Self.toolbarPadding, y: f.minY - Self.toolbarPadding))
    }

    // MARK: Place

    /// The visible bubble in screen points (AppKit's bottom-left origin).
    var bubbleFrame: CGRect? { panel.map { $0.frame.insetBy(dx: Self.padding, dy: Self.padding) } }

    /// Self test: the panels.
    var panelsForTesting: (bubble: NSPanel?, toolbar: NSPanel?) { (panel, toolbarPanel) }

    /// Self test: puts the bubble at `rect` (screen points) without animating.
    func placeForTesting(_ rect: CGRect) {
        guard let model else { return }
        spring = BubbleSpring(value: Self.vector(rect, model.corner), tolerance: [0.2, 0.2, 0.2, 0.2, 0.002, 0.01])
        apply()
    }

    /// The visible bubble in global points with a top-left origin (what the recorder normalizes against).
    var globalFrame: CGRect? {
        guard let f = bubbleFrame else { return nil }
        let top = screenOverride?.frame.maxY ?? NSScreen.screens.first?.frame.maxY ?? f.maxY
        return CGRect(x: f.minX, y: top - f.maxY, width: f.width, height: f.height)
    }

    /// Tells `onPlace` where the bubble is now.
    func reportPlace(at host: Double? = nil) {
        onPlace?(globalFrame, prefs.cameraShape, host)
    }

    private func screenFor(_ point: CGPoint?) -> (frame: CGRect, visible: CGRect) {
        if let screenOverride { return screenOverride }
        let s = point.flatMap { p in NSScreen.screens.first { $0.frame.contains(p) } } ?? NSScreen.withMouse
        return (s.frame, s.visibleFrame)
    }

    func hide() { hide(report: true) }

    private func hide(report: Bool) {
        settleTask?.cancel(); settleTask = nil
        dragTask?.cancel(); dragTask = nil
        toolbarTask?.cancel(); toolbarTask = nil
        driver.stop()
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        if let model {
            withAnimation(.easeIn(duration: 0.14)) { model.presence = 0; model.toolbarVisible = false }
        }
        panel?.fadeOut()
        toolbarPanel?.fadeOut()
        panel = nil
        toolbarPanel = nil
        model = nil
        spring = nil
        deviceID = nil
        if report { onPlace?(nil, prefs.cameraShape, nil) }
    }
}

// MARK: Views

struct CameraBubbleActions {
    var shape: (CameraLayout.Shape) -> Void = { _ in }
    var size: (CameraBubbleSize) -> Void = { _ in }
    var hover: (Bool) -> Void = { _ in }
    var toolbarHover: (Bool) -> Void = { _ in }
    /// The bubble was pressed (a drag may follow).
    var press: () -> Void = {}
}

/// The live camera: the feed in the bubble's outline with a soft rim and shadow. It fills its panel (less the
/// padding), so the controller animates it by moving and resizing the panel.
struct CameraBubbleView: View {
    let camera: NSView
    @Bindable var model: CameraBubbleModel
    var actions = CameraBubbleActions()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let outline = CameraBubbleShape(corner: model.corner)
        let lifted = model.lifted
        ZStack {
            // CameraBubbleStyle, like the editor and the video: a soft shadow (from a solid copy of the outline: a
            // hosted layer casts none of its own), deeper while lifted.
            GeometryReader { geo in
                let w = geo.size.width
                outline.fill(Color.black)
                    .shadow(color: .black.opacity(CameraBubbleStyle.shadowOpacity + (lifted ? 0.06 : 0)),
                            radius: CameraBubbleStyle.shadowRadius(bubbleWidth: w) * (lifted ? 1.35 : 1),
                            y: CameraBubbleStyle.shadowOffset(bubbleWidth: w) * (lifted ? 2 : 1))
                    .opacity(min(1, max(0, model.presence)))
            }
            // Clicks pass through the camera preview (a layer-hosting view that would swallow them) to
            // the drag area behind it, so the bubble can be dragged.
            BubbleDragArea(onPress: actions.press)
                .clipShape(outline)
            ViewHost(view: camera, hitTestable: false)
                .clipShape(outline)
                .allowsHitTesting(false)
            // The hairline rim just inside the edge, a little brighter on hover.
            GeometryReader { geo in
                outline.stroke(Color.white.opacity(CameraBubbleStyle.rimOpacity + (model.hovering || lifted ? 0.14 : 0)),
                               lineWidth: CameraBubbleStyle.rimWidth(bubbleWidth: geo.size.width) * 2)
                    .clipShape(outline)
            }
            .allowsHitTesting(false)
        }
        // Appearing it grows from 86% (the panel fades in alongside), picked up it rises 2.5%.
        .scaleEffect(reduceMotion ? 1 : (0.86 + 0.14 * model.presence) * (lifted ? 1.025 : 1))
        .padding(CameraBubbleController.padding)
        .onHover { actions.hover($0) }
        .animation(.easeOut(duration: 0.15), value: model.hovering)
        .contextMenu {
            ForEach(CameraLayout.Shape.allCases, id: \.self) { s in
                Toggle(s.title, isOn: Binding(get: { model.shape == s }, set: { _ in actions.shape(s) }))
            }
            Divider()
            ForEach(CameraBubbleSize.allCases, id: \.self) { s in
                Toggle(s.title, isOn: Binding(get: { model.size == s }, set: { _ in actions.size(s) }))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Camera, \(model.shape.title.lowercased()), \(model.size.title.lowercased())")
    }
}

/// Shape and size controls in a small ink bar just outside the bubble (above it, or below near the top of the
/// screen). The chosen shape and size sit on a paper chip with an underline; the others are outlines.
struct CameraBubbleToolbar: View {
    @Bindable var model: CameraBubbleModel
    var actions = CameraBubbleActions()
    /// Snapshots: show this control (0...5) hovered or pressed.
    var hovered: Int? = nil
    var pressed: Int? = nil
    @Environment(\.isSnapshot) private var snapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var chips

    static let button: CGFloat = 28
    static let spacing: CGFloat = 2
    static let inset: CGFloat = 4
    static let divider: CGFloat = 9
    static let height: CGFloat = button + inset * 2
    static let width: CGFloat = inset * 2 + button * 6 + spacing * 6 + divider

    /// Centre of control `i` (0–2 shapes, 3–5 sizes) in the toolbar, top-left origin.
    static func buttonCenter(_ i: Int) -> CGPoint {
        var x = inset + button / 2 + CGFloat(i) * (button + spacing)
        if i >= 3 { x += divider + spacing }
        return CGPoint(x: x, y: height / 2)
    }

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(Array(CameraLayout.Shape.allCases.enumerated()), id: \.element) { i, s in
                let on = model.shape == s
                Button { actions.shape(s) } label: {
                    CameraShapeGlyph(shape: s, filled: on, scale: 1.18)
                }
                .buttonStyle(BubbleToolStyle(selected: on, chip: "shape", namespace: chips,
                                             forceHover: hovered == i, forcePress: pressed == i))
                .help(s.title)
                .accessibilityLabel("\(s.title) camera")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Rectangle().fill(Color.white.opacity(0.16)).frame(width: 1, height: 16).frame(width: Self.divider)
                .accessibilityHidden(true)
            ForEach(Array(CameraBubbleSize.allCases.enumerated()), id: \.element) { i, s in
                let on = model.size == s
                Button { actions.size(s) } label: {
                    Text(String(s.title.prefix(1)))
                        .font(.system(size: 12, weight: on ? .bold : .medium, design: .rounded))
                }
                .buttonStyle(BubbleToolStyle(selected: on, chip: "size", namespace: chips,
                                             forceHover: hovered == i + 3, forcePress: pressed == i + 3))
                .help("\(s.title) camera")
                .accessibilityLabel("\(s.title) camera size")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(Self.inset)
        .frame(width: Self.width, height: Self.height)
        .background {
            let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
            ZStack {
                if !snapshot { shape.fill(.ultraThinMaterial) }
                shape.fill(Theme.inkFixed.opacity(snapshot ? 0.94 : 0.86))
                shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.3), radius: 9, y: 3)
        }
        .environment(\.colorScheme, .dark)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: model.shape)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: model.size)
        // Comes out of the bubble's side and settles.
        .opacity(model.toolbarVisible ? 1 : 0)
        .scaleEffect(model.toolbarVisible || reduceMotion ? 1 : 0.94, anchor: model.toolbarAbove ? .bottom : .top)
        .offset(y: model.toolbarVisible || reduceMotion ? 0 : (model.toolbarAbove ? 6 : -6))
        .onHover { actions.toolbarHover($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Camera shape and size")
    }
}

/// A toolbar control: a paper chip under the chosen one (sliding between choices) with a short ink underline,
/// a faint fill on hover, darker and slightly smaller while pressed.
private struct BubbleToolStyle: ButtonStyle {
    let selected: Bool
    let chip: String
    let namespace: Namespace.ID
    var forceHover = false
    var forcePress = false

    func makeBody(configuration: Configuration) -> some View {
        BubbleToolButton(label: configuration.label, isPressed: configuration.isPressed || forcePress, selected: selected,
                         chip: chip, namespace: namespace, forceHover: forceHover)
    }
}

private struct BubbleToolButton<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let selected: Bool
    let chip: String
    let namespace: Namespace.ID
    let forceHover: Bool
    @ViewState private var hovering = false

    var body: some View {
        let hot = hovering || forceHover
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        label
            .foregroundStyle(selected ? Theme.inkFixed : Color.white.opacity(hot ? 0.95 : 0.72))
            .offset(y: selected ? -1.5 : 0)
            .frame(width: CameraBubbleToolbar.button, height: CameraBubbleToolbar.button)
            .background {
                if selected {
                    shape.fill(Theme.paper.opacity(isPressed ? 0.8 : 1))
                        .overlay(alignment: .bottom) {
                            Capsule().fill(Theme.inkFixed.opacity(0.75)).frame(width: 10, height: 2).padding(.bottom, 4)
                        }
                        .matchedGeometryEffect(id: chip, in: namespace)
                } else if hot || isPressed {
                    shape.fill(Color.white.opacity(isPressed ? 0.2 : 0.1))
                }
            }
            .scaleEffect(isPressed ? 0.92 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.spring(response: 0.2, dampingFraction: 0.75), value: isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Drags the bubble's window. Reports the press first, so the bubble can lift before AppKit takes over the drag.
private struct BubbleDragArea: NSViewRepresentable {
    var onPress: () -> Void
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ v: DragView, context: Context) { v.onPress = onPress }

    final class DragView: NSView {
        var onPress: (() -> Void)?
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) {
            onPress?()
            NSCursor.closedHand.push()
            window?.performDrag(with: event)
            NSCursor.pop()
        }
    }
}

/// Hosts an existing NSView in SwiftUI.
struct ViewHost: NSViewRepresentable {
    let view: NSView
    /// false: mouse events go to whatever is behind the view instead of the view itself.
    var hitTestable = true
    func makeNSView(context: Context) -> NSView {
        guard !hitTestable else { return view }
        let box = PassThroughView()
        view.frame = box.bounds
        view.autoresizingMask = [.width, .height]
        box.addSubview(view)
        return box
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
