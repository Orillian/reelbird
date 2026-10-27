import Foundation

/// `edit.json`: every editing decision. Media files are never modified by editing.
/// Unknown keys are ignored and missing keys take defaults, so older and newer files both load.
public struct EditDocument: Codable, Hashable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int = EditDocument.currentFormatVersion
    /// Kept part of the timeline. `nil` = whole recording.
    public var trim: TimeRange?
    /// Ranges removed from the output (pauses are added here automatically).
    public var cuts: [TimeRange] = []
    /// Split points on the recording timeline, sorted: where the editor divides the video into parts to select,
    /// trim or cut. They change nothing in the output on their own. Older files have none.
    public var splits: [Double] = []
    /// Stretches played faster or slower (recording time). Older files have none.
    public var speed = SpeedSettings()
    /// Extra clips appended after this recording, in order (other `.reelbird` bundles, relative or absolute paths).
    public var appended: [String] = []
    /// The visible part of the screen video, normalized to it (top-left origin). `nil` = the whole screen.
    /// Events, annotation rects and zoom focus points stay in full-screen coordinates; see `CropSpace`.
    public var crop: NormRect?
    public var zoom = ZoomSettings()
    public var cursor = CursorSettings()
    public var background = BackgroundSettings()
    public var camera = CameraLayout()
    /// How the screen and camera share the frame over time (recording timeline, sorted, no overlaps). Outside
    /// every segment the camera is the overlay bubble. Empty = the overlay throughout.
    public var layouts: [LayoutSegment] = []
    public var canvas = CanvasSettings()
    public var audio = AudioSettings()
    public var captions = CaptionSettings()
    public var annotations: [Annotation] = []
    public var chapters: [Chapter] = []
    /// Markers on the recording timeline, once renamed, deleted or added in the editor. `nil` = the ones
    /// logged while recording (`marker` events); read them with `Markers.resolve(edit:events:)`.
    public var markers: [Marker]?
    public var title: String?
    /// The step guide: what the share page gets and the steps changed by hand. Older files have none.
    public var guide = GuideSettings()
    /// What Clean Up applied, suggested and was told to leave alone. Older files have none.
    public var cleanUp = CleanUpRecord()

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EditDocument()
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? d.formatVersion
        trim = try c.decodeIfPresent(TimeRange.self, forKey: .trim)
        cuts = try c.decodeIfPresent([TimeRange].self, forKey: .cuts) ?? d.cuts
        splits = (((try? c.decodeIfPresent([Double].self, forKey: .splits)) ?? nil) ?? d.splits).filter { $0.isFinite && $0 > 0 }.sorted()
        // A speed block this version can't read leaves the edit at normal speed instead of failing to open.
        speed = (try? c.decodeIfPresent(SpeedSettings.self, forKey: .speed)) ?? d.speed
        appended = try c.decodeIfPresent([String].self, forKey: .appended) ?? d.appended
        crop = (try? c.decodeIfPresent(LenientCrop.self, forKey: .crop))??.rect
        zoom = try c.decodeIfPresent(ZoomSettings.self, forKey: .zoom) ?? d.zoom
        cursor = try c.decodeIfPresent(CursorSettings.self, forKey: .cursor) ?? d.cursor
        background = try c.decodeIfPresent(BackgroundSettings.self, forKey: .background) ?? d.background
        camera = try c.decodeIfPresent(CameraLayout.self, forKey: .camera) ?? d.camera
        // A segment this version can't read (a newer layout kind) is skipped, not the whole document.
        layouts = LayoutSegment.normalized((try? c.decodeIfPresent([Lenient<LayoutSegment>].self, forKey: .layouts))??
            .compactMap(\.value) ?? d.layouts)
        canvas = try c.decodeIfPresent(CanvasSettings.self, forKey: .canvas) ?? d.canvas
        audio = try c.decodeIfPresent(AudioSettings.self, forKey: .audio) ?? d.audio
        captions = try c.decodeIfPresent(CaptionSettings.self, forKey: .captions) ?? d.captions
        annotations = try c.decodeIfPresent([Annotation].self, forKey: .annotations) ?? d.annotations
        chapters = try c.decodeIfPresent([Chapter].self, forKey: .chapters) ?? d.chapters
        markers = try? c.decodeIfPresent([Marker].self, forKey: .markers)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        guide = (try? c.decodeIfPresent(GuideSettings.self, forKey: .guide)) ?? d.guide
        cleanUp = (try? c.decodeIfPresent(CleanUpRecord.self, forKey: .cleanUp)) ?? d.cleanUp
    }

    /// The default edit for a fresh recording: pauses cut, everything else at defaults.
    public static func initial(for manifest: ProjectManifest) -> EditDocument {
        var e = EditDocument()
        e.cuts = manifest.pauses
        e.camera.visible = manifest.track(.camera) != nil
        return e
    }

    /// The initial edit with the camera placed where the live bubble was during the recording (the `camera`
    /// events: its first place, then a glide for each later move), in its shape and at its size relative to the
    /// captured screen (scaled to the padded screen card, so it matches what was on screen).
    public static func initial(for manifest: ProjectManifest, events: [InputEvent]) -> EditDocument {
        var e = initial(for: manifest)
        if manifest.track(.camera) != nil {
            let screen = manifest.track(.screen)?.pixelSize ?? manifest.capture.pixelSize
            CameraPlacement.apply(events: events, screen: screen, crop: e.crop, duration: manifest.duration,
                                  sizeScale: CameraPlacement.cardScale(source: screen, background: e.background), to: &e.camera)
            // Layouts switched with the layout shortcut while recording.
            e.layouts = LayoutSegment.segments(fromLive: events, duration: manifest.duration)
        }
        return e
    }
}

public struct ZoomSettings: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Hashable, Sendable { case auto, manual, off }
    public var mode: Mode = .auto
    /// One slider for how strong auto-zoom feels: 0 = subtle, 1 = punchy. Scales depth and frequency.
    public var intensity: Double = 0.5
    /// Explicit zoom regions. In `.auto` mode, regions with `source == .auto` are regenerated
    /// from events whenever settings change; `.user` regions are always kept.
    public var regions: [ZoomRegion] = []

    public init() {}
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .auto
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity) ?? 0.5
        regions = try c.decodeIfPresent([ZoomRegion].self, forKey: .regions) ?? []
    }
}

public struct ZoomRegion: Codable, Hashable, Sendable, Identifiable {
    public enum Source: String, Codable, Hashable, Sendable { case auto, user }
    public var id: String
    public var range: TimeRange
    /// Magnification, 1 = none. Typical 1.25...3.
    public var scale: Double
    /// Fixed focus point. `nil` = follow the (smoothed) cursor.
    public var focus: NormPoint?
    public var source: Source
    /// `false` = turned off: kept in the edit (dimmed on the timeline) but never rendered. Absent in older files = on.
    public var enabled: Bool
    /// `true` = cut straight in and out (no zoom animation). Absent in older files = animated.
    public var instant: Bool
    public init(id: String = ShortID.make(length: 6), range: TimeRange, scale: Double,
                focus: NormPoint? = nil, source: Source = .user, enabled: Bool = true, instant: Bool = false) {
        self.id = id; self.range = range; self.scale = scale; self.focus = focus; self.source = source
        self.enabled = enabled; self.instant = instant
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ShortID.make(length: 6)
        range = try c.decode(TimeRange.self, forKey: .range)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1.8
        focus = try c.decodeIfPresent(NormPoint.self, forKey: .focus)
        // An unknown source (from a newer version) reads as a zoom you made, so it is never replanned away.
        source = (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? .user
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        instant = try c.decodeIfPresent(Bool.self, forKey: .instant) ?? false
    }
}

public struct CursorSettings: Codable, Hashable, Sendable {
    public enum ClickEffect: String, Codable, Hashable, Sendable { case none, ripple, ring, press }
    public var visible = true
    /// Cursor size multiplier (1 = system size).
    public var size: Double = 1.5
    /// 0 = raw movement, 1 = very smooth.
    public var smoothing: Double = 0.6
    public var clickEffect: ClickEffect = .ripple
    /// Hide the cursor after this many seconds without movement (0 = never).
    public var hideWhenIdleAfter: Double = 0
    /// Show a keystroke overlay (needs key events in the log).
    public var showKeystrokes = false
    /// Also show plain typing in the keystroke overlay, not only shortcuts (⌘/⌃/⌥ held) and special keys
    /// (Return, Esc, Tab, arrows). Off by default, since typing can include passwords. Absent in older files
    /// = what they showed then (every key, when the overlay was on).
    public var showTypedText = false

    public init() {}
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CursorSettings()
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? d.visible
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        smoothing = try c.decodeIfPresent(Double.self, forKey: .smoothing) ?? d.smoothing
        clickEffect = try c.decodeIfPresent(ClickEffect.self, forKey: .clickEffect) ?? d.clickEffect
        hideWhenIdleAfter = try c.decodeIfPresent(Double.self, forKey: .hideWhenIdleAfter) ?? d.hideWhenIdleAfter
        showKeystrokes = try c.decodeIfPresent(Bool.self, forKey: .showKeystrokes) ?? d.showKeystrokes
        showTypedText = try c.decodeIfPresent(Bool.self, forKey: .showTypedText) ?? showKeystrokes
    }
}

public struct BackgroundSettings: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable { case none, solid, gradient, image }
    public var kind: Kind = .gradient
    /// Solid uses the first colour; gradient uses all (top-left → bottom-right).
    public var colors: [RGBA] = [RGBA(hex: "#F6C68B")!, RGBA(hex: "#E2795C")!]
    /// Absolute or bundle-relative path for `.image`.
    public var imagePath: String?
    /// Padding around the screen video as a fraction of the shorter output side.
    public var padding: Double = 0.08
    /// Corner radius of the screen video as a fraction of the shorter output side.
    public var cornerRadius: Double = 0.018
    /// Shadow strength 0...1.
    public var shadow: Double = 0.5
    /// Add subtle motion blur during zooms and fast cursor moves.
    public var motionBlur = true

    public init() {}
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BackgroundSettings()
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? d.kind
        colors = try c.decodeIfPresent([RGBA].self, forKey: .colors) ?? d.colors
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath)
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? d.padding
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? d.cornerRadius
        shadow = try c.decodeIfPresent(Double.self, forKey: .shadow) ?? d.shadow
        motionBlur = try c.decodeIfPresent(Bool.self, forKey: .motionBlur) ?? d.motionBlur
    }
}

public struct CameraLayout: Codable, Hashable, Sendable {
    public enum Shape: String, Codable, Hashable, Sendable, CaseIterable {
        /// A circle (the default).
        case circle
        /// A square with continuous ("squircle") corners, like a macOS app icon.
        case roundedSquare
        /// A 3:4 tile with the same continuous corners, sized for a face.
        case portrait

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            // "roundedRect" is the name older versions wrote for the rounded shape.
            if raw == "roundedRect" { self = .roundedSquare; return }
            guard let s = Shape(rawValue: raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown camera shape '\(raw)'."))
            }
            self = s
        }
    }
    public enum Corner: String, Codable, Hashable, Sendable, CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    /// A recorded (or added) change of place: from recording time `t` the bubble glides to (`x`, `y`) over
    /// `CameraPlacement.glideDuration`. `x` and `y` work like `CameraLayout.x` and `y`.
    public struct Move: Codable, Hashable, Sendable {
        public var t: Double
        public var x: Double
        public var y: Double
        public init(t: Double, x: Double, y: Double) { self.t = t; self.x = x; self.y = y }
        public var position: NormPoint { NormPoint(x: x, y: y) }
    }

    public var visible = true
    public var shape: Shape = .circle
    /// Diameter / width as a fraction of the shorter output side (`portrait`: see `CameraPlacement.bubbleSize`).
    public var size: Double = 0.22
    /// Preset place, used for whichever of `x` / `y` is `nil`.
    public var corner: Corner = .bottomRight
    /// Gap between the bubble and the canvas edge it is against, as a fraction of the shorter output side.
    public var inset: Double = 0.025
    /// Where the bubble sits, 0...1 across the room it can move in on the canvas: 0 = against the left (top)
    /// edge at `inset`, 1 = against the right (bottom) edge, 0.5 = centred. `nil` = from `corner`. Stays put
    /// relative to the frame when the aspect, padding, crop or zoom change, and never leaves the canvas.
    public var x: Double?
    public var y: Double?
    /// Changes of place over time (recording timeline, sorted by `t`). Empty = the bubble stays in one place.
    public var moves: [Move] = []
    public var mirror = true
    /// Blur the camera background (Vision person segmentation).
    public var blurBackground = false
    /// While the screen is zoomed in, the bubble shrinks to `sizeWhileZoomed` of its size, on the zoom's own curve.
    public var shrinkWhenZoomed = true
    /// The bubble's size during a zoom, as a share of `size` (`CameraPlacement.zoomedSizeRange`).
    public var sizeWhileZoomed: Double = 0.7
    /// During a zoom, the bubble glides to the nearest free corner when the cursor or the zoom's focus would pass
    /// under it, and back after the zoom.
    public var smartFraming = true

    public init() {}
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CameraLayout()
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? d.visible
        shape = try c.decodeIfPresent(Shape.self, forKey: .shape) ?? d.shape
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        corner = try c.decodeIfPresent(Corner.self, forKey: .corner) ?? d.corner
        inset = try c.decodeIfPresent(Double.self, forKey: .inset) ?? d.inset
        x = try c.decodeIfPresent(Double.self, forKey: .x).map(CameraPlacement.clampUnit)
        y = try c.decodeIfPresent(Double.self, forKey: .y).map(CameraPlacement.clampUnit)
        moves = CameraPlacement.normalized(try c.decodeIfPresent([Move].self, forKey: .moves) ?? d.moves)
        mirror = try c.decodeIfPresent(Bool.self, forKey: .mirror) ?? d.mirror
        blurBackground = try c.decodeIfPresent(Bool.self, forKey: .blurBackground) ?? d.blurBackground
        shrinkWhenZoomed = try c.decodeIfPresent(Bool.self, forKey: .shrinkWhenZoomed) ?? d.shrinkWhenZoomed
        let zoomed = try c.decodeIfPresent(Double.self, forKey: .sizeWhileZoomed) ?? d.sizeWhileZoomed
        let r = CameraPlacement.zoomedSizeRange
        sizeWhileZoomed = zoomed.isFinite ? min(r.upperBound, max(r.lowerBound, zoomed)) : d.sizeWhileZoomed
        smartFraming = try c.decodeIfPresent(Bool.self, forKey: .smartFraming) ?? d.smartFraming
    }

    /// Where the bubble starts (before any move).
    public var position: NormPoint {
        get {
            let c = corner.position
            return NormPoint(x: x ?? c.x, y: y ?? c.y)
        }
        set { x = CameraPlacement.clampUnit(newValue.x); y = CameraPlacement.clampUnit(newValue.y) }
    }

    /// Puts the bubble at a preset corner for the whole video (moves dropped).
    public mutating func pin(to corner: Corner) {
        self.corner = corner
        x = nil
        y = nil
        moves = []
    }
}

extension CameraLayout.Corner {
    /// The corner as a `CameraLayout.x` / `y` position.
    public var position: NormPoint {
        switch self {
        case .topLeft: NormPoint(x: 0, y: 0)
        case .topRight: NormPoint(x: 1, y: 0)
        case .bottomLeft: NormPoint(x: 0, y: 1)
        case .bottomRight: NormPoint(x: 1, y: 1)
        }
    }
}

public struct CanvasSettings: Codable, Hashable, Sendable {
    public enum Aspect: String, Codable, Hashable, Sendable, CaseIterable {
        case source, wide = "16:9", vertical = "9:16", square = "1:1", classic = "4:3"
    }
    public var aspect: Aspect = .source
    /// Output height in pixels; `nil` = match the source.
    public var outputHeight: Int?
    public var frameRate: Int?

    public init() {}
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aspect = try c.decodeIfPresent(Aspect.self, forKey: .aspect) ?? .source
        outputHeight = try c.decodeIfPresent(Int.self, forKey: .outputHeight)
        frameRate = try c.decodeIfPresent(Int.self, forKey: .frameRate)
    }
}

public struct AudioSettings: Codable, Hashable, Sendable {
    /// The user's boost for the voice in dB, on top of auto level.
    public var microphoneGainDB: Double = 0
    public var systemGainDB: Double = 0
    public var microphoneMuted = false
    public var systemMuted = false
    /// Bring the voice to a steady loudness (−16 LUFS) from its measured level (`analysis.json`).
    public var autoLevel = true
    /// Clean up the voice: high-pass, noise removal, gentle expander, compressor, de-esser and presence EQ,
    /// rendered once into the voice stem (`voice/`). The raw microphone track is never changed.
    public var enhance = true
    /// How much background noise enhance may remove.
    public var enhanceStrength: EnhanceStrength = .medium
    /// Blend of the enhanced voice with the original: 0 = original, 1 = fully enhanced.
    public var enhanceMix: Double = 1
    /// Lower system audio by about 12 dB while the voice is speaking.
    public var duckSystemAudio = true

    public init() {}
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AudioSettings()
        microphoneGainDB = try c.decodeIfPresent(Double.self, forKey: .microphoneGainDB) ?? d.microphoneGainDB
        systemGainDB = try c.decodeIfPresent(Double.self, forKey: .systemGainDB) ?? d.systemGainDB
        microphoneMuted = try c.decodeIfPresent(Bool.self, forKey: .microphoneMuted) ?? d.microphoneMuted
        systemMuted = try c.decodeIfPresent(Bool.self, forKey: .systemMuted) ?? d.systemMuted
        autoLevel = try c.decodeIfPresent(Bool.self, forKey: .autoLevel) ?? d.autoLevel
        enhance = try c.decodeIfPresent(Bool.self, forKey: .enhance) ?? d.enhance
        // An unknown strength (from a newer version) falls back to the default instead of failing the document.
        enhanceStrength = (try? c.decodeIfPresent(EnhanceStrength.self, forKey: .enhanceStrength)) ?? d.enhanceStrength
        enhanceMix = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .enhanceMix) ?? d.enhanceMix))
        duckSystemAudio = try c.decodeIfPresent(Bool.self, forKey: .duckSystemAudio) ?? d.duckSystemAudio
    }
}

/// How much background noise "Enhance voice" may remove. Capping the attenuation keeps voices natural:
/// full-strength ML denoising is where robotic tone and dropped word endings come from.
public enum EnhanceStrength: String, Codable, Hashable, Sendable, CaseIterable {
    case light, medium, strong, max

    /// Most noise reduction in dB, or `nil` for no cap.
    public var attenuationCapDB: Double? {
        switch self {
        case .light: 6
        case .medium: 12
        case .strong: 24
        case .max: nil
        }
    }

    /// Share of the denoised signal blended with the (aligned) input, so that fully removed noise is reduced
    /// by exactly `attenuationCapDB`: residual = 1 − wet.
    public var denoiseWet: Double {
        guard let cap = attenuationCapDB else { return 1 }
        return 1 - pow(10, -cap / 20)
    }

    public var title: String { rawValue.capitalized }
}

public struct CaptionSettings: Codable, Hashable, Sendable {
    /// How captions look in the video. `.none` keeps the transcript (and the share page's caption track) but
    /// draws nothing; any other style burns captions into the preview and exports.
    public enum Style: String, Codable, Hashable, Sendable, CaseIterable {
        case none, classic, highlight, marker, pop, oneWord, slam
        /// One or two words at a time, big: made for short social clips.
        public var isWordAtATime: Bool { self == .oneWord || self == .slam }
        /// Styles that draw word by word from `transcript.json` rather than sentence cues from the WebVTT file.
        public var usesWordTimings: Bool { self != .none && self != .classic }
    }
    /// Text, backing and accent colours.
    public enum Palette: String, Codable, Hashable, Sendable, CaseIterable { case night, reelbird, mint, paper, bare }
    public enum Size: String, Codable, Hashable, Sendable, CaseIterable {
        case small, medium, large
        public var scale: Double { switch self { case .small: 0.8; case .medium: 1; case .large: 1.25 } }
    }
    /// Where captions sit. `.auto` uses the padding below the video when there is room, and otherwise the bottom
    /// of the frame, moving a caption to the top while the cursor or a click is in the bottom third.
    public enum Position: String, Codable, Hashable, Sendable, CaseIterable { case auto, bottom, belowVideo, top }

    public var style: Style = .none
    public var palette: Palette = .night
    public var size: Size = .medium
    public var position: Position = .auto
    /// Capital letters for One Word and Slam (other styles ignore it).
    public var uppercase = true
    /// Bundle-relative WebVTT file, produced by transcription.
    public var file: String?
    /// BCP 47 language the transcript was made in, e.g. "en-US".
    public var locale: String?

    /// Burn captions into exported video: any style but `.none`. Kept for older files and the `captions.burnIn`
    /// key; setting it on turns on Classic when no style was chosen.
    public var burnIn: Bool {
        get { style != .none }
        set { if newValue { if style == .none { style = .classic } } else { style = .none } }
    }

    public init() {}

    private enum CodingKeys: String, CodingKey { case style, palette, size, position, uppercase, file, locale, burnIn }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let burned = try c.decodeIfPresent(Bool.self, forKey: .burnIn) ?? false
        // Files from before styles have only `burnIn`: on means Classic, the one look there was.
        style = (try? c.decodeIfPresent(Style.self, forKey: .style)) ?? (burned ? Style.classic : Style.none)
        palette = (try? c.decodeIfPresent(Palette.self, forKey: .palette)) ?? .night
        size = (try? c.decodeIfPresent(Size.self, forKey: .size)) ?? .medium
        position = (try? c.decodeIfPresent(Position.self, forKey: .position)) ?? .auto
        uppercase = try c.decodeIfPresent(Bool.self, forKey: .uppercase) ?? true
        file = try c.decodeIfPresent(String.self, forKey: .file)
        locale = try c.decodeIfPresent(String.self, forKey: .locale)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(style, forKey: .style)
        try c.encode(palette, forKey: .palette)
        try c.encode(size, forKey: .size)
        try c.encode(position, forKey: .position)
        try c.encode(uppercase, forKey: .uppercase)
        try c.encodeIfPresent(file, forKey: .file)
        try c.encodeIfPresent(locale, forKey: .locale)
        // Older Reelbird versions read only this.
        try c.encode(burnIn, forKey: .burnIn)
    }
}

/// An overlay drawn on the screen video for part of the recording: a privacy blur, an arrow, a box, a text label
/// or a highlight. Everything is in full-screen coordinates (see `CropSpace`), so it stays on the content it
/// marks through zoom, crop, padding and aspect. Optional keys are left out of the JSON; see `Annotations.swift`.
public struct Annotation: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable { case arrow, box, text, highlight, blur }
    /// How a blur hides what's under it: blurred, pixelated, or a solid bar in `color`.
    public enum BlurStyle: String, Codable, Hashable, Sendable, CaseIterable { case blur, pixelate, solid }
    /// A blur's outline.
    public enum BlurShape: String, Codable, Hashable, Sendable, CaseIterable { case rectangle, rounded, oval }
    /// Where the area is at recording time `t` (auto-detected text that moves).
    public struct Key: Codable, Hashable, Sendable {
        public var t: Double
        public var rect: NormRect
        public init(t: Double, rect: NormRect) { self.t = t; self.rect = rect }
    }

    public var id: String
    public var kind: Kind
    /// On the recording timeline.
    public var range: TimeRange
    /// Area in normalized screen coordinates. With `keys`, the area they cover over the whole range.
    public var rect: NormRect
    public var text: String?
    public var color: RGBA
    /// Blur only: `blur` (default) or `pixelate`.
    public var style: BlurStyle?
    /// Blur only: 0...1 (default 0.5). Every strength leaves text unreadable; higher is coarser.
    public var strength: Double?
    /// Blur only: the outline (default `rounded`).
    public var shape: BlurShape?
    /// Blur only: 0...1, how far the edge fades out past the area (default 0, a crisp edge). The area itself is
    /// always fully covered: the fade is outside it.
    public var softness: Double?
    /// Text only: letter size as a fraction of the screen video's height. `nil` = 0.7 × `rect.height` (older files).
    public var fontSize: Double?
    /// Arrow only: where it starts and where its head points. `nil` = from `rect`'s top-left to its bottom-right.
    public var tail: NormPoint?
    public var head: NormPoint?
    /// Where the area is over time, sorted by `t` (from Find Sensitive Info). Between two keys the area covers
    /// both, so moving text stays hidden. `nil` = `rect` for the whole range.
    public var keys: [Key]?
    /// What Find Sensitive Info found here (`email`, `apiKey`, `card`, `phone`, `custom`); `nil` = added by hand.
    public var detected: String?

    public init(id: String = ShortID.make(length: 6), kind: Kind, range: TimeRange, rect: NormRect,
                text: String? = nil, color: RGBA = Annotation.defaultColor) {
        self.id = id; self.kind = kind; self.range = range; self.rect = rect; self.text = text; self.color = color
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ShortID.make(length: 6)
        kind = try c.decode(Kind.self, forKey: .kind)
        range = try c.decode(TimeRange.self, forKey: .range)
        rect = try c.decode(NormRect.self, forKey: .rect)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        color = (try? c.decodeIfPresent(RGBA.self, forKey: .color)) ?? Annotation.defaultColor
        style = try? c.decodeIfPresent(BlurStyle.self, forKey: .style)
        strength = try c.decodeIfPresent(Double.self, forKey: .strength).map { min(1, max(0, $0.isFinite ? $0 : 0.5)) }
        shape = try? c.decodeIfPresent(BlurShape.self, forKey: .shape)
        softness = ((try? c.decodeIfPresent(Double.self, forKey: .softness)) ?? nil).map { min(1, max(0, $0.isFinite ? $0 : 0)) }
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize).flatMap { $0.isFinite && $0 > 0 ? min(0.5, $0) : nil }
        tail = try c.decodeIfPresent(NormPoint.self, forKey: .tail)
        head = try c.decodeIfPresent(NormPoint.self, forKey: .head)
        keys = try c.decodeIfPresent([Key].self, forKey: .keys).map { $0.sorted { $0.t < $1.t } }.flatMap { $0.isEmpty ? nil : $0 }
        detected = try c.decodeIfPresent(String.self, forKey: .detected)
    }
}

public struct Chapter: Codable, Hashable, Sendable {
    public var time: Double
    public var title: String
    public init(time: Double, title: String) { self.time = time; self.title = title }
}
