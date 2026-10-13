import Foundation

/// Receives the quick-share stream while recording, so the link plays the moment recording stops.
/// Implemented by `ReelbirdShare.LiveShareUploader`; the recorder only knows this protocol.
///
/// Order of calls: `begin` → `initSegment` → `mediaSegment`* → `finish`. Calls arrive from one
/// task in order; implementations must not block (queue uploads and return).
public protocol ShareSegmentSink: AnyObject, Sendable {
    /// Called before the first frame. Reserve the link (upload a placeholder page) and return it.
    func begin(recordingID: String, title: String) async throws -> ShareInfo
    /// The fMP4 initialization segment (ftyp + moov) of the share stream.
    func initSegment(_ data: Data) async
    /// A media segment (moof + mdat). `index` starts at 1. `duration` in seconds.
    func mediaSegment(index: Int, data: Data, duration: Double) async
    /// Recording stopped; mark the stream complete. Returns when the last segment is uploaded
    /// or `timeout` elapses (remaining uploads continue in the background).
    func finish(totalDuration: Double, timeout: Double) async
    /// Recording was discarded; delete everything uploaded.
    func cancel() async
    /// Segments queued but not yet uploaded.
    var backlog: Int { get async }
    /// After `finish`: waits until every segment and the final playlist are uploaded (no timeout) and
    /// returns `true`, or `false` if the upload was cancelled or stopped short (an app quit leaves a
    /// journal to resume from, which needs the bundle's `share/` segments). The recorder deletes those
    /// segments only after `true`.
    func waitUntilUploaded() async -> Bool
}

extension ShareSegmentSink {
    public func waitUntilUploaded() async -> Bool { false }
}
