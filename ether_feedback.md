# Ether Feedback

Findings from the Songbird concurrency review that also apply to the ether codebase.

## 1. EventStore actor blocks the cooperative thread pool

**Severity:** Critical

Ether's `EventStore` is an `actor`, but all SQLite calls (`db.run`, `db.prepare`, `db.scalar`, `db.execute`) are synchronous blocking I/O. These execute on the cooperative thread pool, which has a limited number of threads (typically equal to core count). Blocking a thread with disk I/O reduces the pool's capacity and can cascade into performance degradation or deadlock under concurrent load.

**Recommendation:** Give the `EventStore` actor a custom serial executor using `DispatchSerialQueue`, so all SQLite operations run on a dedicated thread outside the cooperative pool:

```swift
import Dispatch

public actor EventStore {
    private let executor: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    public init(path: String) throws {
        self.executor = DispatchSerialQueue(label: "ether.event-store")
        // ... existing init code ...
    }
}
```

The same applies to `ReadModelStore` if it performs synchronous DuckDB/Smew operations within actor isolation.

**Reference:** research/08-swift-concurrency-waits-for-no-one.md -- "all tasks on the cooperative thread pool must make forward progress."

## 2. `nonisolated(unsafe)` on `db: Connection` lacks safety documentation

**Severity:** Important

The `Connection` property is marked `nonisolated(unsafe)`, which removes the compiler's Sendable checking entirely. While the actor serialization makes this safe in practice, the annotation should include a comment explaining why:

```swift
// SAFETY: Connection is not Sendable, but all access is serialized through this
// actor's executor. Static methods only access it during init (before the actor is shared).
nonisolated(unsafe) let db: Connection
```

## 3. `verifyChain` can block for extended periods

**Severity:** Important

The `verifyChain(batchSize:)` method iterates over all events synchronously. For a large event store, this could block the actor (and its thread) for the entire duration. Consider making it `async` and adding `await Task.yield()` between batches to allow other work to proceed.

## 4. ProjectionPipeline -- missing cancellation propagation

**Severity:** Important

When a caller's task is cancelled while waiting in `waitForProjection(upTo:timeout:)`, the cancellation intent is not propagated -- the waiter continues until either the projection catches up or the timeout fires. Consider wrapping the continuation in `withTaskCancellationHandler` to resume the waiter with `CancellationError()` on caller cancellation.
