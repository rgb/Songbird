import Foundation
import Logging
import Metrics

public enum ProjectionPipelineError: Error, Equatable {
    case timeout
}

public actor ProjectionPipeline {
    private let logger = Logger(label: "songbird.projection-pipeline")
    private var projectors: [any Projector] = []
    private let stream: AsyncStream<RecordedEvent>
    private let continuation: AsyncStream<RecordedEvent>.Continuation
    private var projectedPosition: Int64 = -1
    private var enqueuedPosition: Int64 = -1
    private var nextWaiterId: UInt64 = 0

    /// Waiters are keyed by a monotonically increasing ID. All mutations to this dictionary
    /// happen on the actor's serial executor, which guarantees that waiter registration,
    /// resumption (via `resumeWaiters`/`resumeAllWaiters`), timeout, and cancellation are
    /// fully serialized. A continuation is resumed exactly once because the first path to
    /// reach it removes the entry from the dictionary, and subsequent paths find it absent.
    private var waiters: [UInt64: Waiter] = [:]

    private struct Waiter {
        let position: Int64
        let continuation: CheckedContinuation<Void, any Error>
        let timeoutTask: Task<Void, Never>
    }

    /// Creates a new projection pipeline.
    ///
    /// Note: The internal `AsyncStream` uses an unbounded buffer policy (the default for
    /// `makeStream()`). In practice this is acceptable because the pipeline is fed from a
    /// single event store whose append rate is bounded by database I/O. If back-pressure
    /// becomes a concern, consider switching to a bounded buffer with `.bufferingNewest`
    /// or `.bufferingOldest`.
    public init() {
        let (stream, continuation) = AsyncStream<RecordedEvent>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    // MARK: - Registration

    public func register(_ projector: any Projector) {
        projectors.append(projector)
    }

    // MARK: - Lifecycle

    public func run() async {
        for await event in stream {
            for projector in projectors {
                let start = ContinuousClock.now
                do {
                    try await projector.apply(event)
                } catch {
                    logger.error("Projection error",
                        metadata: [
                            "projector_id": "\(projector.projectorId)",
                            "event_type": "\(event.eventType)",
                            "global_position": "\(event.globalPosition)",
                            "error": "\(error)",
                        ])
                }
                let elapsed = ContinuousClock.now - start
                Metrics.Timer(
                    label: "songbird_projection_process_duration_seconds",
                    dimensions: [("projector_id", projector.projectorId)]
                ).recordNanoseconds(elapsed.nanoseconds)
            }
            projectedPosition = event.globalPosition
            Gauge(label: "songbird_projection_lag")
                .record(Double(enqueuedPosition - projectedPosition))
            resumeWaiters()
        }
        resumeAllWaiters()
    }

    public func stop() {
        continuation.finish()
    }

    // MARK: - Enqueueing

    public func enqueue(_ event: RecordedEvent) {
        enqueuedPosition = event.globalPosition
        continuation.yield(event)
        Gauge(label: "songbird_projection_queue_depth")
            .record(Double(enqueuedPosition - projectedPosition))
    }

    // MARK: - Waiting

    public func waitForProjection(upTo globalPosition: Int64, timeout: Duration = .seconds(5)) async throws {
        try Task.checkCancellation()

        if projectedPosition >= globalPosition { return }

        let waiterId = nextWaiterId
        nextWaiterId += 1

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                let timeoutTask = Task {
                    try? await Task.sleep(for: timeout)
                    self.timeoutWaiter(id: waiterId)
                }
                waiters[waiterId] = Waiter(position: globalPosition, continuation: cont, timeoutTask: timeoutTask)

                // If the task was cancelled between withTaskCancellationHandler and here,
                // the onCancel handler already fired but found no waiter to cancel.
                // Check now and clean up immediately to avoid a leaked continuation.
                if Task.isCancelled {
                    if let waiter = waiters.removeValue(forKey: waiterId) {
                        waiter.timeoutTask.cancel()
                        waiter.continuation.resume(throwing: CancellationError())
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterId) }
        }
    }

    public func waitForIdle(timeout: Duration = .seconds(5)) async throws {
        if enqueuedPosition < 0 || projectedPosition >= enqueuedPosition { return }
        try await waitForProjection(upTo: enqueuedPosition, timeout: timeout)
    }

    // MARK: - Diagnostics

    public var currentPosition: Int64 { projectedPosition }

    // MARK: - Private

    private func resumeWaiters() {
        let satisfied = waiters.filter { $0.value.position <= projectedPosition }
        for (id, waiter) in satisfied {
            waiters.removeValue(forKey: id)
            waiter.timeoutTask.cancel()
            waiter.continuation.resume()
        }
    }

    private func resumeAllWaiters() {
        for (_, waiter) in waiters {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume()
        }
        waiters.removeAll()
    }

    private func cancelWaiter(id: UInt64) {
        guard let waiter = waiters.removeValue(forKey: id) else {
            return // Already resumed by projection, timeout, or stop
        }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func timeoutWaiter(id: UInt64) {
        guard let waiter = waiters.removeValue(forKey: id) else {
            return // Already resumed
        }
        // No need to cancel timeoutTask here -- it's the one calling us
        waiter.continuation.resume(throwing: ProjectionPipelineError.timeout)
    }
}
