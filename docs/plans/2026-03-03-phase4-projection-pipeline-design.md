# Phase 4: Projection Pipeline -- Design

## Summary

Implement `ProjectionPipeline` -- an actor-based async event delivery mechanism that bridges the write model (EventStore) and read model (Projectors). Based on ether's proven pattern with AsyncStream, waiter support, and timeout handling. Lives in the core `Songbird` module.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Module | Core `Songbird` | Zero external dependencies. Central to the architecture. One import for users. |
| Stream type | `AsyncStream<RecordedEvent>` | RecordedEvent already carries globalPosition. Simpler than ether's tuple. |
| Projector dispatch | All registered projectors per event | Each projector decides which events it cares about. |
| Error handling | Log and continue | Projection errors must not stop the pipeline. |
| Waiter mechanism | CheckedContinuation with timeout | Proven pattern from ether. Enables read-after-write consistency. |

## Types

### ProjectionPipeline

```swift
public actor ProjectionPipeline {
    private var projectors: [any Projector] = []
    private let stream: AsyncStream<RecordedEvent>
    private let continuation: AsyncStream<RecordedEvent>.Continuation
    private var projectedPosition: Int64 = -1
    private var enqueuedPosition: Int64 = -1
    private var waiters: [UInt64: (position: Int64, continuation: CheckedContinuation<Void, any Error>)] = [:]
    private var nextWaiterId: UInt64 = 0

    public init()

    public func register(_ projector: any Projector)

    public func run() async
    public func stop()

    public func enqueue(_ event: RecordedEvent)

    public func waitForProjection(upTo globalPosition: Int64, timeout: Duration = .seconds(5)) async throws
    public func waitForIdle(timeout: Duration = .seconds(5)) async throws

    public var currentPosition: Int64 { get }
}
```

### ProjectionPipelineError

```swift
public enum ProjectionPipelineError: Error {
    case timeout
}
```

### Behavior

**`run()`**: Consumes the AsyncStream. For each event, dispatches to all registered projectors. Updates `projectedPosition`. Resumes satisfied waiters. On stream end, resumes all remaining waiters.

**`enqueue(_:)`**: Fire-and-forget. Updates `enqueuedPosition`. Yields event to the continuation.

**`waitForProjection(upTo:timeout:)`**: Returns immediately if already projected. Otherwise parks a CheckedContinuation. Timeout task cancels the waiter after the specified duration.

**`waitForIdle(timeout:)`**: Convenience -- waits until `projectedPosition >= enqueuedPosition`.

**`stop()`**: Calls `continuation.finish()`. Causes `run()` to exit and resume all waiters.

**Error handling**: Projection errors are caught and logged per-projector. The pipeline continues processing. `projectedPosition` advances regardless.

## File Layout

```
Sources/Songbird/
├── (existing files)
└── ProjectionPipeline.swift

Tests/SongbirdTests/
├── (existing files)
└── ProjectionPipelineTests.swift
```
