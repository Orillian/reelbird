import AppKit
import SwiftUI

/// A borderless floating panel over every Space and full-screen app, invisible to screen capture.
/// Panels that take keyboard input (picker, countdown) become key without activating Reelbird;
/// panels shown while recording (control bar, camera bubble, toasts) never become key, so the app
/// being recorded keeps its focus and keystrokes.
class FloatingPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onReturn: (() -> Void)?
    private let allowsKey: Bool

    init(size: NSSize, level: NSWindow.Level = .floating, activating: Bool = false, allowsKey: Bool = true) {
        self.allowsKey = allowsKey
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
        becomesKeyOnlyIfNeeded = !allowsKey
        // Keep Reelbird's own UI out of recordings. ScreenCaptureKit ignores this flag on macOS 15+,
        // so the capture filter also excludes every window of this app (CaptureSources.ownApps).
        sharingType = .none
    }

    override var canBecomeKey: Bool { allowsKey }
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
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.sizingOptions = [.intrinsicContentSize]
        contentView = hosting
        setContentSize(hosting.fittingSize)
    }

    func fadeIn() {
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            animator().alphaValue = 1
        }
    }

    func fadeOut(then: (@MainActor @Sendable () -> Void)? = nil) {
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

/// A hosting view that acts on the first click even when its window isn't key, so buttons in
/// non-key panels (control bar, camera bubble) respond without a focusing click.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
                                    onOpenLibrary: { [weak controller, weak app] in
                                        controller?.closePicker()
                                        app?.openLibrary()
                                    },
                                    onClose: { [weak controller] in controller?.closePicker() })
            .padding(24) // room for the shadow
        panel.host(view, environment: app)
        panel.onEscape = { [weak controller] in controller?.closePicker() }
        panel.onReturn = { [weak controller] in controller?.startFromPicker() }
    }

    /// Shows the panel on the screen with the pointer. The panel takes key focus without
    /// activating Reelbird, so the app you were in stays frontmost and ready to record.
    func present() {
        let screen = NSScreen.withMouse.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.maxY - size.height - screen.height * 0.12))
        panel.fadeIn()
        panel.makeKey()
    }

    func dismiss() { panel.fadeOut() }
}
