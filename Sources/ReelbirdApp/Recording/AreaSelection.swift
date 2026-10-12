import AppKit
import SwiftUI

/// Full-screen overlays for picking a recording area: drag to draw, drag inside to move,
/// drag the handles to resize. Shows the size in pixels. Return records, Esc cancels.
@MainActor final class AreaSelectionController {
    enum Result { case cancelled; case selected(CGRect, displayID: UInt32, record: Bool) }

    private var windows: [AreaOverlayWindow] = []
    private let completion: (Result) -> Void
    private let initial: CGRect?
    private var finished = false

    init(initial: CGRect?, completion: @escaping (Result) -> Void) {
        self.initial = initial
        self.completion = completion
    }

    func present() {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for screen in NSScreen.screens {
            let w = AreaOverlayWindow(screen: screen)
            let view = AreaSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), screen: screen, primaryHeight: primaryHeight)
            view.onFinish = { [weak self] result in self?.finish(result) }
            view.onBegin = { [weak self, weak view] in
                self?.windows.forEach { if $0.contentView !== view { ($0.contentView as? AreaSelectionView)?.clearSelection() } }
            }
            w.contentView = view
            if let initial, let local = view.localRect(fromGlobal: initial), screen.frame.size.width >= local.maxX {
                view.selection = local
            }
            windows.append(w)
            w.orderFrontRegardless()
        }
        NSApp.activate()
        (windows.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? windows.first)?.makeKey()
        NSCursor.crosshair.push()
    }

    private func finish(_ result: Result) {
        guard !finished else { return }
        finished = true
        NSCursor.pop()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        completion(result)
    }
}

final class AreaOverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        sharingType = .none
    }
    override var canBecomeKey: Bool { true }
}

final class AreaSelectionView: NSView {
    var selection: CGRect? { didSet { needsDisplay = true; layoutBar() } }
    var onFinish: ((AreaSelectionController.Result) -> Void)?
    var onBegin: (() -> Void)?

    private let screen: NSScreen
    private let primaryHeight: CGFloat
    private enum Drag { case none, create(CGPoint), move(CGPoint, CGRect), resize(Int, CGRect) }
    private var drag: Drag = .none
    private var bar: NSHostingView<AreaBar>?
    private let handleSize: CGFloat = 10

    init(frame: NSRect, screen: NSScreen, primaryHeight: CGFloat) {
        self.screen = screen
        self.primaryHeight = primaryHeight
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func clearSelection() { selection = nil }

    func localRect(fromGlobal g: CGRect) -> CGRect? {
        let top = primaryHeight - screen.frame.maxY
        let r = CGRect(x: g.minX - screen.frame.minX, y: g.minY - top, width: g.width, height: g.height)
        return bounds.contains(r) ? r : nil
    }

    private func globalRect(_ r: CGRect) -> CGRect {
        let top = primaryHeight - screen.frame.maxY
        return CGRect(x: screen.frame.minX + r.minX, y: top + r.minY, width: r.width, height: r.height).integral
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.38).setFill()
        bounds.fill()
        guard let s = selection else {
            drawHint("Drag to select an area · Esc to cancel")
            return
        }
        NSGraphicsContext.current?.compositingOperation = .clear
        s.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        let border = NSBezierPath(rect: s.insetBy(dx: -0.75, dy: -0.75))
        border.lineWidth = 1.5
        NSColor.rbAccent.setStroke()
        border.stroke()
        for (i, h) in handles(for: s).enumerated() where i < 8 {
            let p = NSBezierPath(ovalIn: h)
            NSColor.white.setFill(); p.fill()
            NSColor.rbAccent.setStroke(); p.lineWidth = 1.5; p.stroke()
        }
    }

    private func drawHint(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white]
        let str = NSAttributedString(string: text, attributes: attrs)
        let sz = str.size()
        let box = NSRect(x: bounds.midX - sz.width / 2 - 16, y: bounds.midY - sz.height / 2 - 9, width: sz.width + 32, height: sz.height + 18)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        str.draw(at: NSPoint(x: box.minX + 16, y: box.minY + 9))
    }

    /// 8 handles: corners then edges (tl, tr, br, bl, t, r, b, l).
    private func handles(for r: CGRect) -> [CGRect] {
        let h = handleSize
        let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
                   CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
        return pts.map { CGRect(x: $0.x - h / 2, y: $0.y - h / 2, width: h, height: h) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let s = selection {
            if let i = handles(for: s).firstIndex(where: { $0.insetBy(dx: -6, dy: -6).contains(p) }) {
                drag = .resize(i, s); return
            }
            if s.contains(p) {
                if event.clickCount == 2 { confirm(record: true); return }
                drag = .move(p, s); return
            }
        }
        onBegin?()
        drag = .create(p)
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none: break
        case .create(let o):
            selection = CGRect(x: min(o.x, p.x), y: min(o.y, p.y), width: abs(p.x - o.x), height: abs(p.y - o.y)).intersection(bounds)
        case .move(let o, let start):
            var r = start.offsetBy(dx: p.x - o.x, dy: p.y - o.y)
            r.origin.x = min(max(0, r.origin.x), bounds.width - r.width)
            r.origin.y = min(max(0, r.origin.y), bounds.height - r.height)
            selection = r
        case .resize(let i, let s):
            var minX = s.minX, minY = s.minY, maxX = s.maxX, maxY = s.maxY
            if [0, 3, 7].contains(i) { minX = p.x }
            if [1, 2, 5].contains(i) { maxX = p.x }
            if [0, 1, 4].contains(i) { minY = p.y }
            if [2, 3, 6].contains(i) { maxY = p.y }
            selection = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY)).intersection(bounds)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .create = drag, let s = selection, s.width < 8 || s.height < 8 { selection = nil }
        drag = .none
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onFinish?(.cancelled)
        case 36, 76: if selection != nil { confirm(record: true) }
        default: super.keyDown(with: event)
        }
    }

    private func confirm(record: Bool) {
        guard let s = selection, s.width >= 8, s.height >= 8 else { return }
        onFinish?(.selected(globalRect(s), displayID: screen.displayID, record: record))
    }

    private func layoutBar() {
        guard let s = selection, s.width > 1 else { bar?.removeFromSuperview(); bar = nil; return }
        let scale = screen.backingScaleFactor
        let model = AreaBar(pixelSize: CGSize(width: (s.width * scale).rounded(), height: (s.height * scale).rounded()),
                            onCancel: { [weak self] in self?.onFinish?(.cancelled) },
                            onRecord: { [weak self] in self?.confirm(record: true) })
        if let bar { bar.rootView = model } else {
            let b = NSHostingView(rootView: model)
            addSubview(b)
            bar = b
        }
        guard let bar else { return }
        let size = bar.fittingSize
        var y = s.maxY + 12
        if y + size.height > bounds.height - 8 { y = s.minY - size.height - 12 }
        if y < 8 { y = s.maxY - size.height - 12 }
        let x = min(max(8, s.midX - size.width / 2), bounds.width - size.width - 8)
        bar.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// Size readout and actions shown next to the selected area.
struct AreaBar: View {
    let pixelSize: CGSize
    let onCancel: () -> Void
    let onRecord: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("\(Int(pixelSize.width)) × \(Int(pixelSize.height))")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.leading, 4)
            Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 16)
            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
            Button(action: onRecord) {
                HStack(spacing: 6) {
                    Circle().fill(Theme.onAccent).frame(width: 7, height: 7)
                    Text("Record")
                }
            }
            .buttonStyle(PrimaryButtonStyle(tint: Theme.recording))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.black.opacity(0.78)))
        .environment(\.colorScheme, .dark)
    }
}
