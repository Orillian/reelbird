import Foundation

/// How a microphone is connected, from CoreAudio's `kAudioDevicePropertyTransportType`.
public enum MicTransport: String, Codable, Hashable, Sendable {
    /// The Mac's own microphone array.
    case builtIn
    /// USB, Thunderbolt, FireWire, PCI or AVB: audio interfaces, USB mics, displays with mics.
    case interface
    /// Classic Bluetooth or Bluetooth LE (AirPods, headsets). Records in call quality on the Mac.
    case bluetooth
    /// An iPhone used as a microphone through Continuity.
    case continuity
    /// HDMI, DisplayPort or AirPlay.
    case display
    /// Software devices: virtual drivers (ZoomAudioDevice, BlackHole, Loopback) and aggregates.
    case virtual
    case unknown

    /// Maps a CoreAudio transport four-character code ('bltn', 'usb ', 'blue', …).
    public init(coreAudio code: UInt32) {
        switch code {
        case Self.fourCC("bltn"): self = .builtIn
        case Self.fourCC("usb "), Self.fourCC("thun"), Self.fourCC("1394"), Self.fourCC("pci "), Self.fourCC("eavb"): self = .interface
        case Self.fourCC("blue"), Self.fourCC("blea"): self = .bluetooth
        case Self.fourCC("ccwd"), Self.fourCC("ccwl"): self = .continuity
        case Self.fourCC("hdmi"), Self.fourCC("dprt"), Self.fourCC("airp"): self = .display
        case Self.fourCC("virt"), Self.fourCC("grup"), Self.fourCC("fgrp"): self = .virtual
        default: self = .unknown
        }
    }

    static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
}

/// What the ranking needs to know about one input device.
public struct MicCandidate: Hashable, Sendable {
    /// Device unique ID (CoreAudio UID = `AVCaptureDevice.uniqueID`).
    public var id: String
    public var name: String
    public var transport: MicTransport
    /// Nominal input sample rate in Hz, when known.
    public var sampleRate: Double?
    /// macOS's current default input.
    public var isSystemDefault: Bool
    /// A webcam's built-in mic (USB but usually worse than the Mac's own array).
    public var isCameraMic: Bool

    public init(id: String, name: String, transport: MicTransport, sampleRate: Double? = nil,
                isSystemDefault: Bool = false, isCameraMic: Bool = false) {
        self.id = id; self.name = name; self.transport = transport; self.sampleRate = sampleRate
        self.isSystemDefault = isSystemDefault; self.isCameraMic = isCameraMic
    }
}

/// Picks the microphone to record with, so a take never silently lands on a call-quality or virtual
/// input. Pure and deterministic; the device list comes from `ReelbirdCapture.Devices`.
public enum MicPolicy {
    /// `RecordingOptions.microphoneID` / preference value meaning "the best connected microphone".
    /// Resolved to an explicit device ID when recording starts, so the input never changes mid-take.
    public static let automaticID = "auto"
    /// The system default input (resolved and locked at start, like `automaticID`).
    public static let systemDefaultID = "default"
    /// At or below this input rate a microphone is call quality (Bluetooth hands-free profile).
    public static let callQualityRate = 24_000.0

    /// Names of common virtual or processing drivers. They often report a plain transport type, so the
    /// name is checked too.
    static let virtualNames = ["zoomaudiodevice", "zoom audio", "blackhole", "loopback", "soundflower", "microsoft teams audio",
                               "teams audio", "krisp", "rogue amoeba", "audio hijack", "obs virtual", "nvidia broadcast",
                               "aggregate", "multi-output", "camo", "elgato virtual"]

    public static func isVirtual(_ c: MicCandidate) -> Bool {
        if c.transport == .virtual { return true }
        let n = c.name.lowercased()
        return virtualNames.contains { n.contains($0) }
    }

    /// Bluetooth inputs, and anything running at 24 kHz or less, record in call quality.
    public static func isCallQuality(_ c: MicCandidate) -> Bool {
        if c.transport == .bluetooth { return true }
        if let r = c.sampleRate, r > 0, r <= callQualityRate { return true }
        return false
    }

    /// Preference order: audio interface or USB mic, then the built-in array, then a webcam mic, then an
    /// iPhone, then displays and unknown devices, then Bluetooth. Virtual devices are never picked
    /// automatically (`nil`). Lower is better.
    public static func tier(_ c: MicCandidate) -> Int? {
        if isVirtual(c) { return nil }
        var t: Int
        switch c.transport {
        case .interface: t = c.isCameraMic ? 2 : 0
        case .builtIn: t = 1
        case .continuity: t = 3
        case .display, .unknown: t = 4
        case .bluetooth: t = 5
        case .virtual: return nil
        }
        // A wired device stuck at call quality (rare) still loses to every full-rate device.
        if c.transport != .bluetooth, isCallQuality(c) { t = 5 }
        return t
    }

    /// Auto-eligible devices, best first. Ties prefer the system default, then the higher sample rate,
    /// then the name, so the result is stable.
    public static func rank(_ candidates: [MicCandidate]) -> [MicCandidate] {
        candidates.compactMap { c in tier(c).map { (c, $0) } }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                if a.0.isSystemDefault != b.0.isSystemDefault { return a.0.isSystemDefault }
                let ra = a.0.sampleRate ?? 0, rb = b.0.sampleRate ?? 0
                if ra != rb { return ra > rb }
                if a.0.name != b.0.name { return a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending }
                return a.0.id < b.0.id
            }
            .map(\.0)
    }

    /// The device "Automatic" records with. With only virtual devices connected, the system default
    /// (else the first device) is better than no microphone.
    public static func best(_ candidates: [MicCandidate]) -> MicCandidate? {
        rank(candidates).first ?? candidates.first(where: \.isSystemDefault) ?? candidates.first
    }

    /// The best full-quality device to offer instead of a call-quality one, if there is any.
    public static func bestAlternative(to current: MicCandidate, in candidates: [MicCandidate]) -> MicCandidate? {
        rank(candidates).first { $0.id != current.id && !isCallQuality($0) }
    }

    /// Resolves a preference value to a connected device: `automaticID` (or `nil`) → `best`,
    /// `systemDefaultID` → the system default, an explicit ID → that device, or `best` when it is not
    /// connected.
    public static func resolve(_ id: String?, in candidates: [MicCandidate]) -> MicCandidate? {
        switch id {
        case nil, automaticID?: return best(candidates)
        case systemDefaultID?: return candidates.first(where: \.isSystemDefault) ?? best(candidates)
        case let id?: return candidates.first { $0.id == id } ?? best(candidates)
        }
    }

    /// Whether an explicit choice is not connected (the picker says so; recording falls back to `best`).
    public static func isMissing(_ id: String?, in candidates: [MicCandidate]) -> Bool {
        guard let id, id != automaticID, id != systemDefaultID else { return false }
        return !candidates.contains { $0.id == id }
    }
}
