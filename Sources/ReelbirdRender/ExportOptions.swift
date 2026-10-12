import Foundation

/// What to export. Unset fields fall back to the edit's canvas settings, then to the source.
public struct ExportOptions: Codable, Hashable, Sendable {
    public enum Format: String, Codable, Hashable, Sendable, CaseIterable {
        /// H.264 High profile in MP4: plays everywhere.
        case mp4H264
        /// HEVC in MP4: about 40% smaller at the same quality.
        case mp4HEVC
        /// Apple ProRes 422 in MOV: for further editing.
        case proRes
        /// Animated GIF: reduced frame rate (15 fps) and size (≤ 540 px tall) by default, no audio.
        case gif

        public var fileExtension: String {
            switch self {
            case .mp4H264, .mp4HEVC: "mp4"
            case .proRes: "mov"
            case .gif: "gif"
            }
        }
    }

    public var format: Format
    /// Output height in pixels (width follows the canvas aspect). `nil` = canvas setting / source.
    public var height: Int?
    /// Output frame rate. `nil` = canvas setting / capture rate (GIF: 15).
    public var frameRate: Int?
    /// Output file. `nil` = `<bundle>/exports/<title> <date>.<ext>`.
    public var destination: URL?

    public init(format: Format = .mp4H264, height: Int? = nil, frameRate: Int? = nil, destination: URL? = nil) {
        self.format = format; self.height = height; self.frameRate = frameRate; self.destination = destination
    }
}
