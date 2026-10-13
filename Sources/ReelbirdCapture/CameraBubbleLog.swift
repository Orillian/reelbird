import CoreGraphics
import Foundation
import ReelbirdCore
import Synchronization

/// Writes the live camera bubble's place into `events.jsonl` as `camera` events, on the recording timeline
/// (host time − origin, the same clock as pointer events): once when recording starts, then whenever the
/// person finishes dragging or resizing it. The frame is normalized to the captured area and moved fully
/// inside it, so a bubble left beside a recorded window lands at the nearest place over it.
///
/// Updates may arrive at any time from the main thread. Before recording starts (countdown) the latest one
/// is kept and logged at t = 0; one made while paused is logged when recording resumes. The live layout
/// (switched with the layout shortcut) goes into the same events once it has changed.
final class CameraBubbleLog: Sendable {
    private struct State {
        var frame: CGRect?
        var shape: CameraLayout.Shape = .circle
        var layout: LayoutSegment.Kind = .overlay
        /// The layout has been switched: every event from then on carries it.
        var layoutSwitched = false
        var changedAtHost = 0.0
        var writer: EventLogWriter?
        var origin = 0.0
        var realTime = true
        var area: (@Sendable () -> CGRect?)?
        var isPaused: (@Sendable (Double) -> Bool)?
        var pending = false
        var last: (rect: NormRect, shape: CameraLayout.Shape, layout: LayoutSegment.Kind)?
        var onChange: (@Sendable (NormRect, CameraLayout.Shape, LayoutSegment.Kind, Double) -> Void)?
    }
    private let state = Mutex(State())

    /// The bubble's frame in global display points (top-left origin) and its shape; `nil` while it is hidden.
    func update(frame: CGRect?, shape: CameraLayout.Shape, atHostTime host: Double) {
        state.withLock { s in
            s.frame = frame
            s.shape = shape
            s.changedAtHost = host
            guard s.writer != nil else { return }
            guard s.realTime else { return }
            let t = max(0, host - s.origin)
            if s.isPaused?(t) == true { s.pending = true; return }
            Self.log(&s, at: t)
        }
    }

    /// The live layout changed (the layout shortcut) at host time `host`.
    func update(layout: LayoutSegment.Kind, atHostTime host: Double) {
        state.withLock { s in
            guard layout != s.layout else { return }
            s.layout = layout
            s.layoutSwitched = true
            s.changedAtHost = host
            guard s.writer != nil, s.realTime else { return }
            let t = max(0, host - s.origin)
            if s.isPaused?(t) == true { s.pending = true; return }
            Self.log(&s, at: t)
        }
    }

    /// Recording started: logs the current place at t = 0. `onChange` also gets every logged place.
    func begin(writer: EventLogWriter, origin: Double, realTime: Bool, area: @escaping @Sendable () -> CGRect?,
               isPaused: @escaping @Sendable (Double) -> Bool,
               onChange: (@Sendable (NormRect, CameraLayout.Shape, LayoutSegment.Kind, Double) -> Void)? = nil) {
        state.withLock { s in
            s.writer = writer; s.origin = origin; s.realTime = realTime; s.area = area; s.isPaused = isPaused
            s.onChange = onChange
            Self.log(&s, at: 0)
        }
    }

    /// Recording resumed at timeline `t`: logs a move made while paused.
    func resumed(at t: Double) {
        state.withLock { s in
            guard s.pending else { return }
            s.pending = false
            Self.log(&s, at: t)
        }
    }

    /// Stops logging (before the event log closes).
    func end() {
        state.withLock { s in s.writer = nil; s.onChange = nil; s.area = nil; s.isPaused = nil }
    }

    private static func log(_ s: inout State, at t: Double) {
        guard let writer = s.writer, let frame = s.frame, let area = s.area?(),
              let rect = CameraPlacement.normalizedBubble(frame: frame, area: area) else { return }
        let r4: (Double) -> Double = { ($0 * 10_000).rounded() / 10_000 }
        let rounded = NormRect(x: r4(rect.x), y: r4(rect.y), width: r4(rect.width), height: r4(rect.height))
        if let last = s.last, last.rect == rounded, last.shape == s.shape, last.layout == s.layout { return }
        s.last = (rounded, s.shape, s.layout)
        var e = InputEvent.camera(r4(t), frame: rounded, shape: s.shape, layout: s.layoutSwitched ? s.layout : nil)
        e.x = e.x.map(r4); e.y = e.y.map(r4)
        writer.append(e)
        s.onChange?(rounded, s.shape, s.layout, t)
    }
}
