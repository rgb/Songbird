import Foundation

public enum ProjectionPipelineError: Error {
    case timeout
}

public actor ProjectionPipeline {
    private var projectors: [any Projector] = []
    private let stream: AsyncStream<RecordedEvent>
    private let continuation: AsyncStream<RecordedEvent>.Continuation
    private var projectedPosition: Int64 = -1
    private var enqueuedPosition: Int64 = -1
    private var waiters: [UInt64: Waiter] = [:]
    private var nextWaiterId: UInt64 = 0

    private struct Waiter {
        let position: Int64
        let continuation: CheckedContinuation<Void, any Error>
        let timeoutTask: Task<Void, Never>
    }

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
                do {
                    try await projector.apply(event)
                } catch {
                    // Projection errors are logged but do not stop the pipeline.
                    // In production, integrate with os.Logger or a logging framework.
                }
            }
            projectedPosition = event.globalPosition
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
    }

    // MARK: - Waiting

    public func waitForProjection(upTo globalPosition: Int64, timeout: Duration = .seconds(5)) async throws {
        if projectedPosition >= globalPosition { return }

        let waiterId = nextWaiterId
        nextWaiterId += 1

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            let timeoutTask = Task {
                try? await Task.sleep(for: timeout)
                self.timeoutWaiter(id: waiterId)
            }
            waiters[waiterId] = Waiter(position: globalPosition, continuation: cont, timeoutTask: timeoutTask)
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

    private func timeoutWaiter(id: UInt64) {
        guard let waiter = waiters.removeValue(forKey: id) else {
            return // Already resumed
        }
        // No need to cancel timeoutTask here -- it's the one calling us
        waiter.continuation.resume(throwing: ProjectionPipelineError.timeout)
    }
}
