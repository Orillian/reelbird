import Dispatch
import Synchronization

/// Runs blocking work (an `AVAssetReader` loop, a synchronous decode or encode, a GPU wait) on its own dispatch
/// queue instead of Swift concurrency's cooperative thread pool, and hands the result back to the caller.
///
/// The cooperative pool has one thread per core and never grows. AVFoundation finishes part of every read on that
/// pool, so a blocking media call on a pool thread can wait for work that needs a pool thread: once every pool
/// thread is blocked that way the process deadlocks (measured on a 14-core Mac with macOS 27: 14 concurrent
/// `copyNextSampleBuffer` loops in tasks never finish, 13 finish in 0.2 s). A serial dispatch queue gets a thread
/// of its own from GCD (it targets the overcommit root queue), so work here never takes a pool thread.
///
/// Cancelling the calling task sets the `CancellationFlag` the work receives; loops check it per buffer and stop
/// early. See docs/ARCHITECTURE.md (Threading).
public enum BlockingWork {
    /// Runs `work` off the cooperative pool and returns its result. `label` names the queue in samples and crash logs.
    public static func run<T: Sendable>(_ label: String, qos: DispatchQoS? = nil,
                                        _ work: @escaping @Sendable (CancellationFlag) throws -> T) async throws -> T {
        let flag = CancellationFlag()
        let queue = DispatchQueue(label: label, qos: qos ?? Self.qos(Task.currentPriority))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, any Error>) in
                queue.async { cont.resume(with: Result { try work(flag) }) }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    /// Non-throwing form of `run`.
    public static func run<T: Sendable>(_ label: String, qos: DispatchQoS? = nil,
                                        _ work: @escaping @Sendable (CancellationFlag) -> T) async -> T {
        let flag = CancellationFlag()
        let queue = DispatchQueue(label: label, qos: qos ?? Self.qos(Task.currentPriority))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
                queue.async { cont.resume(returning: work(flag)) }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    /// The dispatch QoS matching a task priority, so the work runs at the caller's urgency.
    static func qos(_ p: TaskPriority) -> DispatchQoS {
        if p >= .high { return .userInitiated }
        if p >= .medium { return .default }
        if p >= .low { return .utility }
        return .background
    }
}

/// Set when the task that started a `BlockingWork` job is cancelled. Thread-safe; cheap enough to check per buffer.
public final class CancellationFlag: Sendable {
    private let flag = Atomic(false)

    public init() {}

    public var isCancelled: Bool { flag.load(ordering: .relaxed) }

    /// Throws `CancellationError` when cancelled.
    public func check() throws { if isCancelled { throw CancellationError() } }

    public func cancel() { flag.store(true, ordering: .relaxed) }
}
