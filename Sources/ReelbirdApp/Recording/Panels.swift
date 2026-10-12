import AppKit
import SwiftUI

/// A borderless floating panel that can take keyboard focus without activating the app.
class FloatingPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onReturn: (() -> Void)?

    init(size: NSSize, level: NSWindow.Level = .floating, activating: Bool = false) {
        var style: NSWindow.StyleMask = [.borderless, .fullSizeContentView]
        if !activating { style.insert(.nonactivatingPanel) }
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        self.level = level
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        // Keep Reelbird's own UI out of recordings. INTEGRATION: the capture module should also
        // exclude this app's windows in its SCContentFilter, since macOS 15+ may ignore this flag.
        sharingType = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }
        if event.keyCode == 36 || event.keyCode == 76, let onReturn { onReturn(); return }
        super.keyDown(with: event)
    }

    /// Hosts a SwiftUI view, sized to fit it.
    func host<V: View>(_ view: V, environment app: AppModel?) {
        let root = AnyView(view.environment(\.isSnapshot, false))
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = [.intrinsicContentSize]
        contentView = hosting
        setContentSize(hosting.fittingSize)
    }

    func fadeIn() {
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            animator().alphaValue = 1
        }
    }

    func fadeOut(then: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.orderOut(nil)
                self?.alphaValue = 1
                then?()
            }
        })
    }
}

extension NSScreen {
    /// The screen under the mouse pointer.
    static var withMouse: NSScreen {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main ?? screens[0]
    }

    var displayID: UInt32 {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

@MainActor final class SourcePickerPanel {
    private let panel: FloatingPanel
    private unowned let controller: RecordingController

    init(controller: RecordingController, app: AppModel) {
        self.controller = controller
        panel = FloatingPanel(size: NSSize(width: 452, height: 480), level: .floating)
        let view = SourcePickerView(model: controller.picker, controller: controller, prefs: app.prefs,
                                    onSetUpSharing: { [weak controller, weak app] in
                                        controller?.closePicker()
                                        app?.openSettings(.sharing)
                                    },
                                    onClose: { [weak controller] in controller?.closePicker() })
            .padding(24) // room for the shadow
        panel.host(view, environment: app)
        panel.onEscape = { [weak controller] in controller?.closePicker() }
        panel.onReturn = { [weak controller] in controller?.startFromPicker() }
    }

    func present() {
        let screen = NSScreen.withMouse.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.maxY - size.height - screen.height * 0.12))
        NSApp.activate()
        panel.fadeIn()
        panel.makeKey()
    }

    func dismiss() { panel.fadeOut() }
}
