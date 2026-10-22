import AppKit
import ReelbirdCore
import ReelbirdGuide
import ReelbirdRender

/// A keyboard shortcut: one key plus modifiers. Matches key events, feeds menu key equivalents, and draws
/// itself as keycaps, so the editor's key handler, the menus, the command menu and the shortcut sheet agree.
struct KeyShortcut: Hashable, Sendable {
    enum Key: Hashable, Sendable {
        /// A letter (lowercase), digit or symbol.
        case character(Character)
        case space, delete, escape, returnKey, left, right, home, end
    }

    struct Modifiers: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1)
        static let shift = Modifiers(rawValue: 2)
        static let option = Modifiers(rawValue: 4)
        static let control = Modifiers(rawValue: 8)
    }

    var key: Key
    var modifiers: Modifiers = []

    init(_ key: Key, _ modifiers: Modifiers = []) { self.key = key; self.modifiers = modifiers }
    init(_ c: Character, _ modifiers: Modifiers = []) { self.init(.character(Character(c.lowercased())), modifiers) }

    /// Whether ⌘, ⌥ or ⌃ is part of it (the menus handle those; plain keys go to the editor's key handler).
    var usesMenuModifiers: Bool { !modifiers.isDisjoint(with: [.command, .option, .control]) }

    /// Keycaps in macOS order: ⌃ ⌥ ⇧ ⌘, then the key.
    var keycaps: [String] {
        var out: [String] = []
        if modifiers.contains(.control) { out.append("⌃") }
        if modifiers.contains(.option) { out.append("⌥") }
        if modifiers.contains(.shift) { out.append("⇧") }
        if modifiers.contains(.command) { out.append("⌘") }
        out.append(keyName)
        return out
    }

    var keyName: String {
        switch key {
        case .character(let c): c == "-" ? "−" : String(c).uppercased()
        case .space: "Space"
        case .delete: "⌫"
        case .escape: "Esc"
        case .returnKey: "↩"
        case .left: "←"
        case .right: "→"
        case .home: "Home"
        case .end: "End"
        }
    }

    /// "⇧⌘E", for help tags.
    var display: String { keycaps.joined() }

    var menuKeyEquivalent: String {
        switch key {
        case .character(let c): String(c)
        case .space: " "
        case .delete: "\u{8}"
        case .escape: "\u{1b}"
        case .returnKey: "\r"
        case .left: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case .right: String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case .home: String(UnicodeScalar(NSHomeFunctionKey)!)
        case .end: String(UnicodeScalar(NSEndFunctionKey)!)
        }
    }

    var menuModifierMask: NSEvent.ModifierFlags {
        var m: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { m.insert(.command) }
        if modifiers.contains(.shift) { m.insert(.shift) }
        if modifiers.contains(.option) { m.insert(.option) }
        if modifiers.contains(.control) { m.insert(.control) }
        return m
    }

    /// The shortcut a key-down event is, if any.
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        var mods: Modifiers = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        switch event.keyCode {
        case 49: self.init(.space, mods)
        case 51, 117: self.init(.delete, mods)
        case 53: self.init(.escape, mods)
        case 36, 76: self.init(.returnKey, mods)
        case 123: self.init(.left, mods)
        case 124: self.init(.right, mods)
        case 115: self.init(.home, mods)
        case 119: self.init(.end, mods)
        default:
            guard let c = event.charactersIgnoringModifiers?.lowercased().first else { return nil }
            self.init(c, mods)
        }
    }
}

/// Every editor shortcut, in one place. The registry, the editor's key handler and the main menu read these.
enum EditorKeys {
    static let playPause = KeyShortcut(.space)
    static let shuttleBack = KeyShortcut("j")
    static let shuttlePause = KeyShortcut("k")
    static let shuttlePlay = KeyShortcut("l")
    static let frameBack = KeyShortcut(.left)
    static let frameForward = KeyShortcut(.right)
    static let secondBack = KeyShortcut(.left, .shift)
    static let secondForward = KeyShortcut(.right, .shift)
    static let goToStart = KeyShortcut(.home)
    static let goToEnd = KeyShortcut(.end)
    static let split = KeyShortcut("s")
    static let addZoom = KeyShortcut("z")
    static let addLayout = KeyShortcut("c")
    static let addMarker = KeyShortcut("m")
    static let changeSpeed = KeyShortcut("r")
    static let addBlur = KeyShortcut("b")
    static let addArrow = KeyShortcut("a")
    static let addBox = KeyShortcut("x")
    static let addText = KeyShortcut("t")
    static let addHighlight = KeyShortcut("h")
    static let deleteSelection = KeyShortcut(.delete)
    static let clearSelection = KeyShortcut(.escape)
    static let zoomOnOff = KeyShortcut("0")
    static let zoomInstant = KeyShortcut("i")
    static func zoomDepth(_ n: Int) -> KeyShortcut { KeyShortcut(Character(String(n))) }
    static let copy = KeyShortcut("c", .command)
    static let paste = KeyShortcut("v", .command)
    static let selectAll = KeyShortcut("a", .command)
    static let undo = KeyShortcut("z", .command)
    static let redo = KeyShortcut("z", [.command, .shift])
    static let timelineZoomIn = KeyShortcut("=", .command)
    static let timelineZoomOut = KeyShortcut("-", .command)
    static func section(_ index: Int) -> KeyShortcut { KeyShortcut(Character(String(index + 1)), .command) }
    static let export = KeyShortcut("e", .command)
    static let share = KeyShortcut("e", [.command, .shift])
    static let showInFinder = KeyShortcut("r", [.command, .shift])
    static let moveToTrash = KeyShortcut(.delete, .command)
    static let library = KeyShortcut("l", [.command, .shift])
    static let commandMenu = KeyShortcut("k", .command)
    static let shortcuts = KeyShortcut("/", .command)
}

/// One thing the editor can do: a title to search, where it belongs, its shortcut, and the action.
struct EditorCommand: Identifiable {
    enum Area: Int, CaseIterable, Comparable {
        case playback, timeline, zooms, overlays, panels, look, audio, captions, file, recording, help
        var title: String {
            switch self {
            case .playback: "Playback"
            case .timeline: "Timeline"
            case .zooms: "Zooms"
            case .overlays: "Overlays"
            case .panels: "Panels"
            case .look: "Look"
            case .audio: "Audio"
            case .captions: "Captions"
            case .file: "Export and Share"
            case .recording: "While Recording"
            case .help: "Help"
            }
        }
        static func < (a: Area, b: Area) -> Bool { a.rawValue < b.rawValue }
    }

    /// Commands that share a row in the shortcut sheet (the 0–9 depth keys).
    struct SheetRow: Equatable {
        let id: String
        let title: String
        let keycaps: [String]
    }

    let id: String
    let title: String
    let area: Area
    var symbol: String
    var shortcut: KeyShortcut? = nil
    /// Other words that find it in the command menu.
    var keywords: [String] = []
    var isEnabled = true
    /// On or off, for settings that switch.
    var isOn: Bool? = nil
    /// The current choice among several (zoom mode, aspect ratio, depth): shown with a checkmark.
    var isCurrent = false
    var sheetRow: SheetRow? = nil
    /// A ⌘ shortcut the editor's key handler takes before the menus, only while the command can run (⌘C, ⌘V
    /// and ⌘A act on zooms, and otherwise keep their usual meaning).
    var takesMenuKey = false
    /// Hidden from the command menu (the command menu itself).
    var inPalette = true
    let action: @MainActor () -> Void
}

/// The editor's command registry: the single list the command menu searches, the shortcut sheet shows, and the
/// key handler dispatches from. Rebuilt on demand (it is cheap), so titles and states are always current.
@MainActor enum EditorCommands {
    static func all(model m: EditorModel, app: AppModel?) -> [EditorCommand] {
        var c: [EditorCommand] = []
        let e = m.edit

        // Playback
        c.append(.init(id: "play", title: "Play or Pause", area: .playback, symbol: "playpause.fill", shortcut: EditorKeys.playPause,
                       keywords: ["start", "stop", "preview"]) { m.togglePlay() })
        c.append(.init(id: "shuttle-back", title: "Back 2 Seconds", area: .playback, symbol: "gobackward.5", shortcut: EditorKeys.shuttleBack,
                       keywords: ["rewind", "shuttle", "jkl"]) { m.shuttle("j") })
        c.append(.init(id: "shuttle-pause", title: "Pause", area: .playback, symbol: "pause.fill", shortcut: EditorKeys.shuttlePause,
                       keywords: ["shuttle", "jkl", "stop"]) { m.shuttle("k") })
        c.append(.init(id: "shuttle-play", title: "Play", area: .playback, symbol: "play.fill", shortcut: EditorKeys.shuttlePlay,
                       keywords: ["shuttle", "jkl"]) { m.shuttle("l") })
        c.append(.init(id: "frame-back", title: "Back One Frame", area: .playback, symbol: "chevron.left", shortcut: EditorKeys.frameBack,
                       keywords: ["step", "nudge"]) { m.step(-1.0 / 30) })
        c.append(.init(id: "frame-forward", title: "Forward One Frame", area: .playback, symbol: "chevron.right", shortcut: EditorKeys.frameForward,
                       keywords: ["step", "nudge"]) { m.step(1.0 / 30) })
        c.append(.init(id: "second-back", title: "Back One Second", area: .playback, symbol: "chevron.left.2", shortcut: EditorKeys.secondBack,
                       keywords: ["step"]) { m.step(-1) })
        c.append(.init(id: "second-forward", title: "Forward One Second", area: .playback, symbol: "chevron.right.2", shortcut: EditorKeys.secondForward,
                       keywords: ["step"]) { m.step(1) })
        c.append(.init(id: "go-start", title: "Go to Start", area: .playback, symbol: "backward.end.fill", shortcut: EditorKeys.goToStart,
                       keywords: ["beginning", "home", "jump"]) { m.seek(source: 0) })
        c.append(.init(id: "go-end", title: "Go to End", area: .playback, symbol: "forward.end.fill", shortcut: EditorKeys.goToEnd,
                       keywords: ["finish", "jump"]) { m.seek(source: m.duration) })

        // Timeline
        c.append(.init(id: "split", title: "Split at Playhead", area: .timeline, symbol: "scissors", shortcut: EditorKeys.split,
                       keywords: ["cut", "blade", "razor"]) { m.splitAtPlayhead() })
        let sel = m.selection
        c.append(.init(id: "delete-selection",
                       title: sel?.isCut == true ? "Restore Cut" : sel?.isZoom == true ? m.deleteZoomsTitle
                           : sel?.isLayout == true ? "Delete Layout" : sel?.isSpeed == true ? "Remove Speed" : sel?.isAnnotation == true ? "Delete Overlay" : "Cut Selection",
                       area: .timeline, symbol: sel?.isCut == true ? "arrow.uturn.backward" : "trash", shortcut: EditorKeys.deleteSelection,
                       keywords: ["delete", "remove"], isEnabled: sel != nil) { m.deleteSelection() })
        c.append(.init(id: "add-layout", title: "Change Camera Layout at Playhead", area: .timeline, symbol: "person.crop.rectangle",
                       shortcut: EditorKeys.addLayout, keywords: ["camera only", "split", "screen only", "layout"], isEnabled: m.hasCamera) {
            m.addLayoutAtPlayhead()
        })
        c.append(.init(id: "add-marker", title: "Add Marker at Playhead", area: .timeline, symbol: "flag", shortcut: EditorKeys.addMarker,
                       keywords: ["flag", "bookmark", "chapter"]) { m.addMarkerAtPlayhead() })
        speedCommands(m, into: &c)
        c.append(.init(id: "clear-selection", title: "Clear Selection", area: .timeline, symbol: "xmark", shortcut: EditorKeys.clearSelection,
                       keywords: ["deselect", "cancel"], isEnabled: sel != nil || m.overlays.tool != nil) { m.escape() })
        c.append(.init(id: "remove-silences", title: "Cut Long Silences", area: .timeline, symbol: "waveform.badge.minus",
                       keywords: ["pauses", "quiet", "dead air"], isEnabled: m.hasMicrophone) { m.removeSilences() })
        c.append(.init(id: "clear-trim", title: "Remove Trim", area: .timeline, symbol: "arrow.left.and.right",
                       keywords: ["untrim", "full length"], isEnabled: e.trim != nil) {
            m.change("Remove Trim") { $0.trim = nil }
        })
        let undoName = m.undoManager.undoActionName, redoName = m.undoManager.redoActionName
        c.append(.init(id: "undo", title: undoName.isEmpty ? "Undo" : "Undo \(undoName)", area: .timeline, symbol: "arrow.uturn.backward",
                       shortcut: EditorKeys.undo, isEnabled: m.undoManager.canUndo) { m.undoManager.undo() })
        c.append(.init(id: "redo", title: redoName.isEmpty ? "Redo" : "Redo \(redoName)", area: .timeline, symbol: "arrow.uturn.forward",
                       shortcut: EditorKeys.redo, isEnabled: m.undoManager.canRedo) { m.undoManager.redo() })
        c.append(.init(id: "timeline-in", title: "Zoom In Timeline", area: .timeline, symbol: "plus.magnifyingglass",
                       shortcut: EditorKeys.timelineZoomIn, keywords: ["magnify", "scale"]) { m.timelineZoom = min(16, m.timelineZoom * 1.5) })
        c.append(.init(id: "timeline-out", title: "Zoom Out Timeline", area: .timeline, symbol: "minus.magnifyingglass",
                       shortcut: EditorKeys.timelineZoomOut, keywords: ["magnify", "scale"]) { m.timelineZoom = max(1, m.timelineZoom / 1.5) })

        // Overlays: each tool arms drawing on the preview.
        let toolKeys: [Annotation.Kind: KeyShortcut] = [.blur: EditorKeys.addBlur, .arrow: EditorKeys.addArrow, .box: EditorKeys.addBox,
                                                        .text: EditorKeys.addText, .highlight: EditorKeys.addHighlight]
        for kind in Annotation.Kind.toolOrder {
            c.append(.init(id: "add-\(kind.rawValue)", title: kind == .blur ? "Blur an Area" : "Add \(kind.title)", area: .overlays,
                           symbol: kind.symbol, shortcut: toolKeys[kind],
                           keywords: kind == .blur ? ["redact", "hide", "pixelate", "privacy", "mask"] : ["annotate", "overlay", "draw"],
                           isEnabled: !m.isCropping) { m.beginOverlayTool(kind) })
        }
        c.append(.init(id: "find-sensitive-info", title: "Find Sensitive Info", area: .overlays, symbol: "text.viewfinder",
                       keywords: ["privacy", "redact", "secrets", "emails", "api keys", "passwords", "blur"], isEnabled: !m.overlays.isScanning) {
            m.section = .overlays
            m.findSensitiveInfo()
        })
        c.append(.init(id: "keep-all-sensitive", title: "Blur All Findings", area: .overlays, symbol: "eye.slash",
                       keywords: ["keep all", "redact", "sensitive"], isEnabled: !m.overlays.suggestions.isEmpty) { m.keepAllSuggestions() })

        // Zooms
        let targets = m.zoomKeyTargets
        let targetZooms = m.zooms(targets)
        let plural = targets.count > 1
        c.append(.init(id: "add-zoom", title: "Add Zoom at Playhead", area: .zooms, symbol: "plus.magnifyingglass", shortcut: EditorKeys.addZoom,
                       keywords: ["new", "punch in"]) { m.addZoomAtPlayhead() })
        c.append(.init(id: "copy-zooms", title: m.selectedZoomIDs.count > 1 ? "Copy Zooms" : "Copy Zoom", area: .zooms, symbol: "doc.on.doc",
                       shortcut: EditorKeys.copy, keywords: ["duplicate"], isEnabled: m.canCopyZooms, takesMenuKey: true) { m.copyZooms() })
        c.append(.init(id: "paste-zooms", title: ZoomClipboard.zooms.count > 1 ? "Paste Zooms at Playhead" : "Paste Zoom at Playhead",
                       area: .zooms, symbol: "doc.on.clipboard", shortcut: EditorKeys.paste, keywords: ["duplicate"],
                       isEnabled: m.canPasteZooms, takesMenuKey: true) { m.pasteZooms() })
        c.append(.init(id: "select-all-zooms", title: "Select All Zooms", area: .zooms, symbol: "checklist", shortcut: EditorKeys.selectAll,
                       isEnabled: !e.zoom.regions.isEmpty, takesMenuKey: true) { m.selectAllZooms() })
        let allOff = !targetZooms.isEmpty && targetZooms.allSatisfy { !$0.enabled }
        c.append(.init(id: "zoom-on-off", title: allOff ? (plural ? "Turn Zooms On" : "Turn Zoom On") : (plural ? "Turn Zooms Off" : "Turn Zoom Off"),
                       area: .zooms, symbol: allOff ? "eye" : "eye.slash", shortcut: EditorKeys.zoomOnOff,
                       keywords: ["disable", "enable", "hide", "skip", "mute"], isEnabled: !targets.isEmpty,
                       sheetRow: .init(id: "zoom-depth", title: "Zoom depth (0 turns it off)",
                                       keycaps: ["0", "–", "9"])) { m.toggleZoomsEnabled(targets) })
        c.append(.init(id: "zoom-instant", title: "Instant Zoom", area: .zooms, symbol: "bolt", shortcut: EditorKeys.zoomInstant,
                       keywords: ["cut", "no animation", "transition", "jump"], isEnabled: !targets.isEmpty,
                       isOn: targets.isEmpty ? nil : targetZooms.allSatisfy(\.instant)) { m.toggleZoomsInstant(targets) })
        for n in 1...9 {
            let d = ZoomEditing.digitDepths[n - 1]
            c.append(.init(id: "zoom-depth-\(n)", title: "Zoom Depth \(Self.depth(d))", area: .zooms, symbol: "plus.magnifyingglass",
                           shortcut: EditorKeys.zoomDepth(n), keywords: ["scale", "magnification", "level", "\(n)"],
                           isEnabled: !targets.isEmpty, isCurrent: !targets.isEmpty && targetZooms.allSatisfy { abs($0.scale - d) < 0.001 },
                           sheetRow: .init(id: "zoom-depth", title: "", keycaps: [])) { m.zoomDigit(n) })
        }
        c.append(.init(id: "zoom-depth-all", title: "Use This Depth for All Zooms", area: .zooms, symbol: "square.stack.3d.up",
                       keywords: ["apply", "same", "every"], isEnabled: m.selectedZoomIDs.count == 1 && e.zoom.regions.count > 1) {
            m.applyDepthToAllZooms()
        })
        for (mode, title) in [(ZoomSettings.Mode.auto, "Automatic Zooms"), (.manual, "Only Zooms You Add"), (.off, "No Zooms")] {
            c.append(.init(id: "zoom-mode-\(mode.rawValue)", title: title, area: .zooms, symbol: "plus.magnifyingglass",
                           keywords: ["zoom mode", mode.rawValue], isCurrent: e.zoom.mode == mode) { m.setZoomMode(mode) })
        }
        c.append(.init(id: "zoom-reset", title: "Reset Automatic Zooms", area: .zooms, symbol: "arrow.counterclockwise",
                       keywords: ["regenerate", "replan"], isEnabled: e.zoom.mode == .auto) { m.resetAutoZooms() })

        // Camera layouts of a kind, at the playhead (C adds the default, camera only).
        if m.hasCamera {
            for kind in [LayoutSegment.Kind.split, .screenOnly] {
                c.append(.init(id: "add-layout-\(kind.rawValue)", title: "\(kind.title) Layout at Playhead", area: .look,
                               symbol: "person.crop.rectangle", keywords: ["camera layout", "side by side", "hide camera"]) {
                    m.addLayoutAtPlayhead(kind)
                })
            }
        }

        // Panels
        for (i, s) in InspectorSection.allCases.enumerated() {
            c.append(.init(id: "panel-\(s.rawValue)", title: "\(s.title) Settings", area: .panels, symbol: s.symbol,
                           shortcut: EditorKeys.section(i), keywords: ["inspector", "panel", "show"]) { m.section = s })
        }

        // Look
        c.append(toggle("motion-blur", "Motion Blur", .look, "wind", e.background.motionBlur, ["smear"], m) { $0.background.motionBlur.toggle() })
        c.append(toggle("show-cursor", "Show Cursor", .look, "cursorarrow", e.cursor.visible, ["pointer", "mouse", "hide"], m) { $0.cursor.visible.toggle() })
        c.append(.init(id: "cursor-smoothing", title: "Cursor Smoothing", area: .look, symbol: "scribble.variable",
                       keywords: ["smooth", "glide", "jitter", "pointer"], isOn: e.cursor.smoothing > 0.001) {
            m.change("Smoothing") { $0.cursor.smoothing = $0.cursor.smoothing > 0.001 ? 0 : CursorSettings().smoothing }
        })
        c.append(toggle("keystrokes", "Show Keystrokes", .look, "keyboard", e.cursor.showKeystrokes, ["keys", "typing", "overlay"], m) {
            $0.cursor.showKeystrokes.toggle()
        })
        if m.hasCamera {
            c.append(toggle("show-camera", "Show Camera", .look, "person.crop.circle", e.camera.visible, ["webcam", "bubble", "face"], m) {
                $0.camera.visible.toggle()
            })
            c.append(toggle("mirror-camera", "Mirror Camera", .look, "arrow.left.and.right.righttriangle.left.righttriangle.right",
                            e.camera.mirror, ["flip", "webcam"], m) { $0.camera.mirror.toggle() })
            c.append(toggle("blur-camera", "Blur Camera Background", .look, "person.and.background.dotted", e.camera.blurBackground,
                            ["webcam", "portrait"], m) { $0.camera.blurBackground.toggle() })
            for corner in CameraLayout.Corner.allCases {
                c.append(.init(id: "camera-\(corner.rawValue)", title: "Camera \(Self.cornerName(corner))", area: .look,
                               symbol: "person.crop.circle", keywords: ["webcam", "bubble", "corner", "move"],
                               isCurrent: m.cameraCorner == corner) { m.setCameraCorner(corner) })
            }
        }
        for aspect in CanvasSettings.Aspect.allCases {
            let name = aspect == .source ? "Original" : aspect.rawValue
            c.append(.init(id: "aspect-\(aspect.rawValue)", title: "Aspect Ratio \(name)", area: .look, symbol: "aspectratio",
                           keywords: ["canvas", "size", "vertical", "square", "wide", "format"], isCurrent: e.canvas.aspect == aspect) {
                m.change("Aspect Ratio") { $0.canvas.aspect = aspect }
            })
        }
        c.append(.init(id: "crop", title: "Crop…", area: .look, symbol: "crop", keywords: ["trim edges", "frame"],
                       isEnabled: m.player != nil && !m.isCropping) { m.section = .canvas; m.beginCrop() })
        c.append(.init(id: "hide-toolbar", title: "Hide Browser Toolbar", area: .look, symbol: "macwindow",
                       keywords: ["crop", "tabs", "address bar", "chrome", "safari"],
                       isEnabled: m.toolbarCrop != nil && !m.isToolbarHidden) { m.hideBrowserToolbar() })
        c.append(.init(id: "reset-crop", title: "Show Whole Screen", area: .look, symbol: "arrow.up.left.and.arrow.down.right",
                       keywords: ["reset crop", "uncrop"], isEnabled: e.crop != nil) { m.resetCrop() })

        // Audio
        if m.hasMicrophone {
            c.append(toggle("enhance", "Enhance Voice", .audio, "wand.and.stars", e.audio.enhance, ["noise", "denoise", "clean", "mic"], m) {
                $0.audio.enhance.toggle()
            })
            c.append(toggle("auto-level", "Auto Level", .audio, "dial.medium", e.audio.autoLevel, ["loudness", "volume", "normalize", "lufs"], m) {
                $0.audio.autoLevel.toggle()
            })
            c.append(toggle("mute-mic", "Mute Microphone", .audio, "mic.slash", e.audio.microphoneMuted, ["voice", "silence"], m) {
                $0.audio.microphoneMuted.toggle()
            })
        }
        if m.hasSystemAudio {
            c.append(toggle("duck", "Lower System Audio Under Voice", .audio, "speaker.wave.1", e.audio.duckSystemAudio,
                            ["duck", "ducking", "music"], m) { $0.audio.duckSystemAudio.toggle() })
            c.append(toggle("mute-system", "Mute System Audio", .audio, "speaker.slash", e.audio.systemMuted, ["sound", "computer"], m) {
                $0.audio.systemMuted.toggle()
            })
        }

        // Captions
        let hasAudio = m.hasMicrophone || m.hasSystemAudio
        c.append(.init(id: "generate-captions", title: e.captions.file == nil ? "Generate Captions" : "Generate Captions Again", area: .captions,
                       symbol: "captions.bubble", keywords: ["transcribe", "subtitles", "transcript"],
                       isEnabled: hasAudio && m.transcriberAvailable && m.captionState != .working) {
            m.section = .captions
            m.generateCaptions()
        })
        c.append(toggle("burn-in", "Burn In Captions", .captions, "text.below.photo", e.captions.burnIn, ["subtitles", "export"], m,
                        enabled: e.captions.file != nil) { $0.captions.burnIn.toggle() })
        c.append(.init(id: "remove-captions", title: "Remove Captions", area: .captions, symbol: "trash", keywords: ["subtitles", "delete"],
                       isEnabled: e.captions.file != nil) { m.removeCaptions() })
        c.append(.init(id: "markers-to-chapters", title: "Use Markers as Chapters", area: .captions, symbol: "flag",
                       keywords: ["flags", "chapters", "share page"], isEnabled: !m.markers.isEmpty) {
            m.useMarkersAsChapters()
            m.section = .captions
        })
        c.append(.init(id: "suggest-story", title: "Suggest Title and Chapters", area: .captions, symbol: "sparkles",
                       keywords: ["apple intelligence", "chapters", "name"],
                       isEnabled: m.storySupported && m.transcript != nil && m.storyState != .working) {
            m.section = .captions
            m.suggestStory()
        })

        // Export and share
        c.append(.init(id: "export", title: "Export…", area: .file, symbol: "square.and.arrow.up", shortcut: EditorKeys.export,
                       keywords: ["render", "save", "file"], isEnabled: !m.isBusy) { m.showExport = true })
        for (format, name, words) in [(ExportOptions.Format.mp4H264, "MP4", ["h264", "video"]), (.mp4HEVC, "HEVC", ["h265", "smaller"]),
                                      (.proRes, "ProRes", ["mov", "editing", "master"]), (.gif, "GIF", ["animated", "image"])] {
            c.append(.init(id: "export-\(format.rawValue)", title: "Export as \(name)…", area: .file, symbol: "square.and.arrow.up",
                           keywords: ["render", "save"] + words, isEnabled: !m.isBusy) {
                m.pendingExportFormat = format
                m.showExport = true
            })
        }
        let shared = m.shareInfo != nil
        for (format, name, words) in [(GuideExport.Format.html, "Web Page", ["html", "click-through", "demo"]),
                                      (.markdown, "Markdown", ["md", "docs", "readme"]), (.skill, "Claude Skill", ["agent", "skill.md"])] {
            c.append(.init(id: "export-guide-\(format.rawValue)", title: "Export Guide as \(name)…", area: .file, symbol: "list.number",
                           keywords: ["steps", "guide", "how-to", "tutorial"] + words, isEnabled: !m.guidePanel.isExporting) {
                m.exportGuide(format)
            })
        }
        c.append(.init(id: "guide-refresh", title: "Read Guide Steps Again", area: .file, symbol: "arrow.clockwise",
                       keywords: ["steps", "guide", "rescan", "ocr"]) {
            m.section = .guide
            m.loadGuide(refresh: true)
        })
        c.append(.init(id: "share", title: shared ? "Sharing Options…" : "Share Link…", area: .file, symbol: "link", shortcut: EditorKeys.share,
                       keywords: ["upload", "publish", "url"]) { m.showShare = true })
        c.append(.init(id: "copy-link", title: "Copy Link", area: .file, symbol: "link", keywords: ["share", "url", "clipboard"],
                       isEnabled: shared) { m.copyLink() })
        c.append(.init(id: "update-link", title: "Update Link", area: .file, symbol: "arrow.triangle.2.circlepath",
                       keywords: ["share", "publish", "polished", "upload"],
                       isEnabled: shared && m.shareConfigured && !m.shareState.isWorking) { m.publish() })
        c.append(.init(id: "open-link", title: "Open Link in Browser", area: .file, symbol: "safari", keywords: ["share", "view"],
                       isEnabled: shared) { m.openLink() })
        c.append(.init(id: "show-in-finder", title: "Show in Finder", area: .file, symbol: "folder", shortcut: EditorKeys.showInFinder,
                       keywords: ["reveal", "files", "bundle"]) { Finder.reveal([m.bundle.url]) })
        if let app {
            c.append(.init(id: "library", title: "Library", area: .file, symbol: "square.grid.2x2", shortcut: EditorKeys.library,
                           keywords: ["recordings", "all"]) { app.openLibrary() })
            c.append(.init(id: "trash", title: "Move to Trash…", area: .file, symbol: "trash", shortcut: EditorKeys.moveToTrash,
                           keywords: ["delete", "remove recording"]) { app.moveToTrash(m.bundle) })
        }

        // While recording: global shortcuts (Settings → General), listed in the sheet only.
        let prefs = app?.prefs
        for (id, title, key) in [("hotkey-record", "New recording, or stop", prefs?.recordHotKey ?? .defaultRecord),
                                 ("hotkey-pause", "Pause or resume", prefs?.pauseHotKey ?? .defaultPause),
                                 ("hotkey-marker", "Add a marker", prefs?.markerHotKey ?? .defaultMarker),
                                 ("hotkey-layout", "Switch the camera layout", prefs?.layoutHotKey ?? .defaultLayout)] {
            c.append(.init(id: id, title: title, area: .recording, symbol: "record.circle", isEnabled: false,
                           sheetRow: .init(id: id, title: title, keycaps: Self.keycaps(key.display)), inPalette: false) {})
        }

        // Help
        c.append(.init(id: "command-menu", title: "Command Menu", area: .help, symbol: "command", shortcut: EditorKeys.commandMenu,
                       keywords: ["search", "palette"], inPalette: false) { m.showCommandPalette = true })
        c.append(.init(id: "keyboard-shortcuts", title: "Keyboard Shortcuts", area: .help, symbol: "keyboard", shortcut: EditorKeys.shortcuts,
                       keywords: ["keys", "help", "cheat sheet"]) { m.showShortcuts = true })
        return c
    }

    /// A setting that switches on and off, as one undo step.
    private static func toggle(_ id: String, _ title: String, _ area: EditorCommand.Area, _ symbol: String, _ isOn: Bool,
                               _ keywords: [String], _ m: EditorModel, enabled: Bool = true,
                               _ body: @escaping (inout EditDocument) -> Void) -> EditorCommand {
        EditorCommand(id: id, title: title, area: area, symbol: symbol, keywords: keywords, isEnabled: enabled, isOn: isOn) {
            m.change(title) { body(&$0) }
        }
    }

    /// "⌥⇧L" → ["⌥", "⇧", "L"].
    static func keycaps(_ display: String) -> [String] {
        let mods = display.prefix { "⌃⌥⇧⌘".contains($0) }
        return mods.map(String.init) + [String(display.dropFirst(mods.count))]
    }

    static func depth(_ d: Double) -> String {
        let s = String(format: "%.2f", d)
        let trimmed = s.hasSuffix("0") ? String(s.dropLast()) : s
        return (trimmed.hasSuffix(".0") ? String(trimmed.dropLast(2)) : trimmed) + "×"
    }

    static func cornerName(_ c: CameraLayout.Corner) -> String {
        switch c {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }

    /// The command a key press runs in the editor, if any: plain keys always (the key handler swallows them even
    /// when the command can't run, as before), ⌘ keys only for commands that take them from the menus while they can run.
    static func command(for event: NSEvent, in commands: [EditorCommand]) -> EditorCommand? {
        guard let key = KeyShortcut(event: event) else { return nil }
        return commands.first { c in
            guard c.shortcut == key else { return false }
            return key.usesMenuModifiers ? (c.takesMenuKey && c.isEnabled) : true
        }
    }

    /// Shortcut sheet rows: commands with shortcuts by area, the depth keys folded into one row.
    struct SheetSection: Identifiable {
        var id: EditorCommand.Area { area }
        let area: EditorCommand.Area
        var rows: [(id: String, title: String, keycaps: [String])]
    }

    static func sheet(_ commands: [EditorCommand]) -> [SheetSection] {
        var sections: [SheetSection] = []
        for area in EditorCommand.Area.allCases {
            var rows: [(id: String, title: String, keycaps: [String])] = []
            var seenRows: Set<String> = []
            for c in commands where c.area == area {
                guard c.shortcut != nil || c.sheetRow != nil else { continue }
                if let row = c.sheetRow {
                    guard seenRows.insert(row.id).inserted else { continue }
                    rows.append((row.id, row.title, row.keycaps))
                } else {
                    rows.append((c.id, sheetTitle(c), c.shortcut?.keycaps ?? []))
                }
            }
            if !rows.isEmpty { sections.append(SheetSection(area: area, rows: rows)) }
        }
        return sections
    }

    /// Speed: R (2× for the selected part, or the next speed of a selected segment), each preset, Speed Up Typing,
    /// and whether sound above 2× plays.
    private static func speedCommands(_ m: EditorModel, into c: inout [EditorCommand]) {
        let selected = m.selectedSpeed
        c.append(.init(id: "change-speed", title: selected == nil ? "Change Speed" : "Next Speed", area: .timeline,
                       symbol: "gauge.with.dots.needle.67percent", shortcut: EditorKeys.changeSpeed,
                       keywords: ["fast forward", "slow motion", "rate", "2x", "speed up", "retime"]) { m.speedKey() })
        for r in [0.25] + SpeedSegment.presets + [8] {
            let label = SpeedSegment.label(r)
            c.append(.init(id: "speed-\(label)", title: "Speed \(label)", area: .timeline,
                           symbol: r < 1 ? "tortoise" : "gauge.with.dots.needle.67percent",
                           keywords: ["rate", "fast", "slow", "retime", label.replacingOccurrences(of: "×", with: "x")],
                           isCurrent: selected.map { abs($0.rate - r) < 1e-9 } ?? false) { m.applySpeed(r) })
        }
        let suggestions = m.speedSuggestions
        c.append(.init(id: "speed-up-typing",
                       title: suggestions.isEmpty ? "Speed Up Typing" : EditorModel.speedSuggestionTitle(suggestions),
                       area: .timeline, symbol: "keyboard", keywords: ["typing", "idle", "waiting", "fast forward", "shorten", "speed"]) {
            m.applySpeedSuggestions()
        })
        c.append(.init(id: "keep-fast-audio", title: "Keep Sound Above 2×", area: .audio, symbol: "speaker.wave.2",
                       keywords: ["speed", "mute", "fast", "sound"], isOn: m.edit.speed.keepFastAudio) {
            m.setKeepFastAudio(!m.edit.speed.keepFastAudio)
        })
    }

    /// Stable titles for the sheet (the command menu's change with the selection).
    private static func sheetTitle(_ c: EditorCommand) -> String {
        switch c.id {
        case "delete-selection": "Cut or delete the selection"
        case "change-speed": "Change speed"
        case "speed-up-typing": "Speed up typing"
        case "copy-zooms": "Copy selected zooms"
        case "paste-zooms": "Paste zooms at the playhead"
        case "zoom-instant": "Instant zoom, no animation"
        case "undo": "Undo"
        case "redo": "Redo"
        case "share": "Share link"
        default: c.title.replacingOccurrences(of: "…", with: "")
        }
    }
}
