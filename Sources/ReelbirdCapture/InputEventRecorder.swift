import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import ReelbirdCore
import Synchronization
import UniformTypeIdentifiers

/// Records pointer samples (120 Hz), clicks, scrolls, cursor image changes, optional keystrokes and
/// pause markers into `events.jsonl`, all on the recording timeline (host time − origin).
///
/// Clicks and scrolls come from NSEvent monitors (no permission needed); keystrokes from a
/// listen-only event tap, only when Input Monitoring is granted.
final class InputEventRecorder: @unchecked Sendable {
    struct Configuration: Sendable {
        var captureKeystrokes = false
        /// Captured area in global display points, top-left origin.
        var capturedArea: @Sendable () -> CGRect?
        /// Synthetic pointer (tests). When set, the system pointer, clicks and cursor are not recorded.
        var simulatedPointer: (@Sendable (Double) -> NormPoint?)?
        /// For a window recording: the process that owns the window. Keystrokes are then logged only
        /// while that app is in front, so typing into other apps (a password manager, a chat) stays out
        /// of the project. `nil` (display and area recordings) logs every key, like the screen shows.
        var keystrokeOwnerPID: pid_t?
    }

    private let log: EventLogWriter
    private let cursors: CursorRecorder
    private let config: Configuration
    private let queue = DispatchQueue(label: "reelbird.events.pointer", qos: .userInitiated)
    private struct State {
        var origin = 0.0
        var running = false
        var lastPoint: NormPoint?
        var lastActivityHost = 0.0
        var paused: @Sendable (Double) -> Bool = { _ in false }
        var count = 0
    }
    private let state = Mutex(State())
    private var timer: (any DispatchSourceTimer)?
    private var keyTap: KeyTap?
    private let mainInput = Mutex<MainThreadInput?>(nil)

    init(log: EventLogWriter, bundle: ProjectBundle, configuration: Configuration) {
        self.log = log
        self.config = configuration
        cursors = CursorRecorder(directory: bundle.cursorsURL, indexURL: bundle.cursorIndexURL)
    }

    /// Host time of the last click, scroll or key press (for stall detection).
    var lastActivityHost: Double { state.withLock { $0.lastActivityHost } }
    var eventCount: Int { state.withLock { $0.count } }
    /// Whether the keystroke tap is running (needs Input Monitoring; see `Permission.inputMonitoring`).
    var keystrokesActive: Bool { keyTapRunning.withLock { $0 } }
    private let keyTapRunning = Mutex(false)
    /// The frontmost app's process (kept current from the main thread; 0 = not known yet).
    private let frontmostPID = Atomic<Int32>(0)

    func setFrontmost(_ pid: pid_t) { frontmostPID.store(pid, ordering: .relaxed) }

    /// Whether a key typed now belongs in the log (see `Configuration.keystrokeOwnerPID`).
    func keyBelongsToRecording() -> Bool {
        guard let owner = config.keystrokeOwnerPID else { return true }
        let front = frontmostPID.load(ordering: .relaxed)
        return front == 0 || front == owner
    }

    func start(origin: Double, isPaused: @escaping @Sendable (Double) -> Bool) {
        state.withLock { $0.origin = origin; $0.running = true; $0.paused = isPaused }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / 120, leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.samplePointer() }
        t.resume()
        timer = t
        guard config.simulatedPointer == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                let input = MainThreadInput(recorder: self)
                input.start()
                self.mainInput.withLock { $0 = input }
            }
        }
        if config.captureKeystrokes, Permissions.status(.inputMonitoring) == .granted {
            let tap = KeyTap { [weak self] chars, mods in self?.recordKey(chars: chars, mods: mods) }
            if tap.start() {
                keyTap = tap
                keyTapRunning.withLock { $0 = true }
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {}
        state.withLock { $0.running = false }
        keyTap?.stop()
        keyTap = nil
        keyTapRunning.withLock { $0 = false }
        if let input = mainInput.withLock({ m in defer { m = nil }; return m }) {
            DispatchQueue.main.async { MainActor.assumeIsolated { input.stop() } }
        }
        cursors.writeIndex()
    }

    /// Writes a pause or resume marker.
    func mark(_ kind: InputEvent.Kind, at t: Double) {
        write(InputEvent(t: t, type: kind))
    }

    // MARK: Recording

    /// Times and positions are rounded to 4 decimals to keep hour-long logs compact and fast to read.
    private func write(_ event: InputEvent) {
        var e = event
        let r4: (Double) -> Double = { ($0 * 10_000).rounded() / 10_000 }
        e.t = r4(e.t)
        e.x = e.x.map(r4)
        e.y = e.y.map(r4)
        e.dx = e.dx.map { ($0 * 100).rounded() / 100 }
        e.dy = e.dy.map { ($0 * 100).rounded() / 100 }
        log.append(e)
        state.withLock { $0.count += 1 }
    }

    private func timeline(_ host: Double) -> Double? {
        state.withLock { s -> Double? in
            guard s.running else { return nil }
            let t = host - s.origin
            return t >= 0 && !s.paused(t) ? t : nil
        }
    }

    func normalize(_ p: CGPoint) -> NormPoint? {
        guard let area = config.capturedArea(), area.width > 0, area.height > 0 else { return nil }
        return NormPoint(x: (p.x - area.minX) / area.width, y: (p.y - area.minY) / area.height)
    }

    private func samplePointer() {
        let host = HostClock.now()
        guard let t = timeline(host) else { return }
        let point: NormPoint?
        if let sim = config.simulatedPointer {
            point = sim(host)
        } else if let loc = CGEvent(source: nil)?.location {
            point = normalize(loc)
        } else {
            point = nil
        }
        guard let point else { return }
        let changed = state.withLock { s -> Bool in
            if let last = s.lastPoint, abs(last.x - point.x) < 5e-5, abs(last.y - point.y) < 5e-5 { return false }
            s.lastPoint = point
            return true
        }
        if changed { write(.move(t, point)) }
    }

    /// Mouse buttons and scroll from the NSEvent monitors (main thread).
    func record(type: NSEvent.EventType, location: CGPoint, timestamp: Double, button: Int, dx: Double, dy: Double) {
        let now = HostClock.now()
        let host = abs(timestamp - now) < 1 ? timestamp : now
        guard let t = timeline(host), let p = normalize(location) else { return }
        state.withLock { $0.lastActivityHost = now }
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: write(.down(t, p, button: button))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: write(.up(t, p, button: button))
        case .scrollWheel: write(InputEvent(t: t, type: .scroll, x: p.x, y: p.y, dx: dx, dy: dy))
        default: break
        }
    }

    func recordCursor(id: String) {
        guard let t = timeline(HostClock.now()) else { return }
        write(InputEvent(t: t, type: .cursor, image: id))
    }

    private func recordKey(chars: String, mods: [String]) {
        guard keyBelongsToRecording() else { return }
        let now = HostClock.now()
        guard let t = timeline(now) else { return }
        state.withLock { $0.lastActivityHost = now }
        write(InputEvent(t: t, type: .key, chars: chars, mods: mods.isEmpty ? nil : mods))
    }

    var cursorRecorder: CursorRecorder { cursors }
}

/// NSEvent monitors and cursor polling, which must live on the main thread.
@MainActor final class MainThreadInput {
    private weak var recorder: InputEventRecorder?
    private var monitors: [Any] = []
    private var cursorTimer: Timer?
    private var activationObserver: (any NSObjectProtocol)?
    private var lastImage: ObjectIdentifier?
    private var lastID: String?

    init(recorder: InputEventRecorder) { self.recorder = recorder }

    func start() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                           .otherMouseDown, .otherMouseUp, .scrollWheel]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return e
        }) { monitors.append(m) }
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { recorder?.setFrontmost(pid) }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { self?.recorder?.setFrontmost(pid) } }
        }
        pollCursor()
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollCursor() }
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        cursorTimer?.invalidate()
        cursorTimer = nil
    }

    private func handle(_ e: NSEvent) {
        guard let recorder else { return }
        let location = e.cgEvent?.location ?? CGEvent(source: nil)?.location ?? .zero
        let button: Int = switch e.type {
        case .rightMouseDown, .rightMouseUp: 1
        case .otherMouseDown, .otherMouseUp: 2
        default: 0
        }
        let dx = e.type == .scrollWheel ? Double(e.scrollingDeltaX) : 0
        let dy = e.type == .scrollWheel ? Double(e.scrollingDeltaY) : 0
        recorder.record(type: e.type, location: location, timestamp: e.timestamp, button: button, dx: dx, dy: dy)
    }

    private func pollCursor() {
        guard let recorder, let cursor = NSCursor.currentSystem else { return }
        let image = cursor.image
        let ident = ObjectIdentifier(image)
        guard ident != lastImage else { return }
        lastImage = ident
        guard let id = recorder.cursorRecorder.register(image: image, hotSpot: cursor.hotSpot) else { return }
        if id != lastID {
            lastID = id
            recorder.recordCursor(id: id)
        }
    }
}

/// Saves each distinct cursor image once as `cursors/<id>.png` (2x) and keeps `cursors.json` current.
final class CursorRecorder: @unchecked Sendable {
    private let directory: URL
    private let indexURL: URL
    private let infos = Mutex<[String: CursorImageInfo]>([:])

    init(directory: URL, indexURL: URL) {
        self.directory = directory
        self.indexURL = indexURL
    }

    /// PNG scale: 4× so cursors stay crisp when zoomed in on a 4K export, capped at `maxPixels` a side.
    static let scale = 4.0
    static let maxPixels = 512.0

    /// Pixel scale used for a cursor of `size` points.
    static func pixelScale(for size: NSSize) -> Double {
        let longest = max(size.width, size.height)
        guard longest > 0 else { return scale }
        return min(scale, maxPixels / longest)
    }

    /// Returns the image's ID (hash of its rendered pixels), saving it if new. Main thread (AppKit drawing).
    /// cursors.json keeps width/height in points and the hot spot in pixels of the PNG, so readers
    /// derive the scale as PNG width ÷ width.
    @MainActor func register(image: NSImage, hotSpot: NSPoint) -> String? {
        let size = image.size
        let k = Self.pixelScale(for: size)
        let w = Int((size.width * k).rounded()), h = Int((size.height * k).rounded())
        guard w > 0, h > 0, w <= Int(Self.maxPixels), h <= Int(Self.maxPixels),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: w * 4, bitsPerPixel: 32),
              let ctx = NSGraphicsContext(bitmapImageRep: rep), let bytes = rep.bitmapData else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        var hasher = SHA256()
        hasher.update(bufferPointer: UnsafeRawBufferPointer(start: bytes, count: w * h * 4))
        withUnsafeBytes(of: (hotSpot.x, hotSpot.y)) { hasher.update(bufferPointer: $0) }
        let id = hasher.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
        let isNew = infos.withLock { $0[id] == nil }
        if isNew {
            if let cg = rep.cgImage { save(cg, id: id) }
            let info = CursorImageInfo(id: id, hotX: hotSpot.x * Double(w) / size.width, hotY: hotSpot.y * Double(h) / size.height,
                                       width: size.width, height: size.height)
            infos.withLock { $0[id] = info }
            writeIndex()
        }
        return id
    }

    private func save(_ image: CGImage, id: String) {
        let url = directory.appendingPathComponent("\(id).png") as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    func writeIndex() {
        let list = infos.withLock { Array($0.values) }.sorted { $0.id < $1.id }
        guard !list.isEmpty else { return }
        try? JSONCoding.writeAtomically(list, to: indexURL)
    }
}

/// Listen-only keyboard event tap on its own run-loop thread. Needs Input Monitoring.
final class KeyTap: @unchecked Sendable {
    private let handler: @Sendable (String, [String]) -> Void
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    init(handler: @escaping @Sendable (String, [String]) -> Void) { self.handler = handler }

    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: keyTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.port = port
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self, let port = self.port, let src = CFMachPortCreateRunLoopSource(nil, port, 0) else { ready.signal(); return }
            self.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "reelbird.keytap"
        thread.qualityOfService = .userInitiated
        thread.start()
        self.thread = thread
        ready.wait()
        return true
    }

    func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let runLoop { CFRunLoopStop(runLoop) }
        port = nil
        runLoop = nil
        thread = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return
        }
        guard type == .keyDown else { return }
        let flags = event.flags
        var mods: [String] = []
        if flags.contains(.maskControl) { mods.append("⌃") }
        if flags.contains(.maskAlternate) { mods.append("⌥") }
        if flags.contains(.maskShift) { mods.append("⇧") }
        if flags.contains(.maskCommand) { mods.append("⌘") }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let special: [Int64: String] = [36: "⏎", 76: "⌤", 48: "⇥", 49: "␣", 51: "⌫", 117: "⌦", 53: "⎋",
                                         123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟"]
        var chars = special[code] ?? ""
        if chars.isEmpty {
            // Characters without modifiers applied, so ⌘S reads "S" rather than a control character.
            let copy = event.copy()
            copy?.flags = []
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 8)
            copy?.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &buffer)
            chars = String(utf16CodeUnits: buffer, count: length)
            if mods.contains(where: { $0 != "⇧" }) { chars = chars.uppercased() }
        }
        guard !chars.isEmpty else { return }
        handler(chars, mods)
    }
}

private let keyTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    if let refcon {
        Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
