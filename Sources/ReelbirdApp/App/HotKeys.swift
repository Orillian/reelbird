import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut: a virtual key code plus Carbon modifier flags.
struct HotKey: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let defaultRecord = HotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | shiftKey))
    static let defaultPause = HotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(optionKey | shiftKey))
    /// Registered only while recording, so ⌥⇧M types its character in other apps the rest of the time.
    static let defaultMarker = HotKey(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(optionKey | shiftKey))
    /// Switches the camera layout while recording (registered only then, so it doesn't take ⌥⇧L from other apps).
    static let defaultLayout = HotKey(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(optionKey | shiftKey))

    init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.isEmpty, !flags.isSubset(of: [.shift]) else { return nil } // need a real modifier
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: m)
    }

    /// e.g. "⌥⇧R", in the order macOS menus use (⌃⌥⇧⌘).
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    var menuModifiers: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        return f
    }

    var menuKeyEquivalent: String { Self.keyName(keyCode).lowercased() }

    static func keyName(_ code: UInt32) -> String {
        let special: [Int: String] = [
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        ]
        if let s = special[Int(code)] { return s }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        guard status == noErr, len > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: len).uppercased()
    }
}

/// Registers global hot keys with Carbon `RegisterEventHotKey`, which needs no permission.
@MainActor final class HotKeyCenter {
    enum Action: UInt32, CaseIterable { case record = 1, pause = 2, layout = 3, marker = 4 }

    static let shared = HotKeyCenter()
    private var refs: [Action: EventHotKeyRef] = [:]
    private var handlers: [Action: @MainActor () -> Void] = [:]
    private var installed = false

    func register(_ action: Action, _ key: HotKey, handler: @escaping @MainActor () -> Void) {
        installIfNeeded()
        unregister(action)
        handlers[action] = handler
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5242_4952), id: action.rawValue) // 'RBIR'
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs[action] = ref; keys[action] = key }
    }

    func unregister(_ action: Action) {
        if let r = refs.removeValue(forKey: action) { UnregisterEventHotKey(r) }
        keys[action] = nil
    }

    func isRegistered(_ action: Action) -> Bool { refs[action] != nil }

    /// Whether another app already holds `key` as a global shortcut (macOS refuses a second registration).
    /// Keys Reelbird itself has registered count as free.
    func isTakenByAnotherApp(_ key: HotKey) -> Bool {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5242_4952), id: 99)
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if let ref { UnregisterEventHotKey(ref) }
        return status == OSStatus(eventHotKeyExistsErr) && !keys.values.contains(key)
    }

    /// The key each registered action is on.
    private var keys: [Action: HotKey] = [:]

    /// Temporarily disables all hot keys (while the user records a new shortcut).
    func suspend(_ suspended: Bool) {
        if suspended { for (_, r) in refs { UnregisterEventHotKey(r) }; refs.removeAll(); keys.removeAll() }
    }

    fileprivate func fire(_ id: UInt32) {
        guard let a = Action(rawValue: id) else { return }
        handlers[a]?()
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
