# Phase 4: Projection Pipeline — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement the ProjectionPipeline actor that bridges write model events to read model projectors via AsyncStream, with waiter support for read-after-write consistency.

**Architecture:** A single actor using AsyncStream for async event delivery. Dispatches to registered Projector instances. CheckedContinuation-based waiters with timeout for synchronization. Based on ether's proven pattern, generalized for any Projector.

**Tech Stack:** Swift 6.2+, macOS 14+, Swift Testing, AsyncStream, CheckedContinuation

**Test command:** `swift test 2>&1`

**Build command:** `swift build 2>&1`

**Design doc:** `docs/plans/2026-03-03-phase4-projection-pipeline-design.md`

---

### Task 1: ProjectionPipeline + tests

**Files:**
- Create: `Sources/Songbird/ProjectionPipeline.swift`
- Create: `Tests/SongbirdTests/ProjectionPipelineTests.swift`

**Step 1: Write the tests**

Create `Tests/SongbirdTests/ProjectionPipelineTests.swift`:

```swift
import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

// Test projector that records applied events
final class RecordingProjector: Projector, @unchecked Sendable {
    let projectorId: String
    private(set) var appliedEvents: [RecordedEvent] = []

    init(id: String = "recording") {
        self.projectorId = id
    }

    func apply(_ event: RecordedEvent) async throws {
        appliedEvents.append(event)
    }
}

// Test projector that only handles specific event types
final class FilteringProjector: Projector, @unchecked Sendable {
    let projectorId = "filtering"
    let acceptedTypes: Set<String>
    private(set) var appliedEvents: [RecordedEvent] = []

    init(acceptedTypes: Set<String>) {
        self.acceptedTypes = acceptedTypes
    }

    func apply(_ event: RecordedEvent) async throws {
        if acceptedTypes.contains(event.eventType) {
            appliedEvents.append(event)
        }
    }
}

// Test projector that throws on specific events
final class FailingProjector: Projector, @unchecked Sendable {
    let projectorId = "failing"
    let failOnType: String
    private(set) var appliedEvents: [RecordedEvent] = []

    init(failOnType: String) {
        self.failOnType = failOnType
    }

    func apply(_ event: RecordedEvent) async throws {
        if event.eventType == failOnType {
            throw ProjectorTestError.intentionalFailure
        }
        appliedEvents.append(event)
    }
}

enum ProjectorTestError: Error {
    case intentionalFailure
}

// Helper to create a RecordedEvent
func makeRecordedEvent(
    globalPosition: Int64,
    eventType: String = "TestEvent",
    streamName: StreamName = StreamName(category: "test", id: "1")
) -> RecordedEvent {
    RecordedEvent(
        id: UUID(),
        streamName: streamName,
        position: globalPosition,
        globalPosition: globalPosition,
        eventType: eventType,
        data: Data("{}".utf8),
        metadata: EventMetadata(),
        timestamp: Date()
    )
}

@Suite("ProjectionPipeline")
struct ProjectionPipelineTests {

    // MARK: - Basic Dispatch

    @Test func dispatchesEventsToRegisteredProjector() async throws {
        let projector = RecordingProjector()
        let pipeline = ProjectionPipeline()
        await pipeline.register(projector)

        let task = Task { await pipeline.run() }

        await pipeline.enqueue(makeRecordedEvent(globalPosition: 0))
        await pipeline.enqueue(makeRecordedEvent(globalPosition: 1))
        try await pipeline.waitForIdle()

        #expect(projector.appliedEvents.count == 2)

        await pipeline.stop()
        await task.value
    }

    @Test func dispatchesToMultipleProjectors() async throws {
        let p1 = RecordingProjector(id: "p1")
        let p2 = RecordingProjector(id: "p2")
        let pipeline = ProjectionPipeline()
        await pipeline.register(p1)
        await pipeline.register(p2)

        let task = Task { await pipeline.run() }

        await pipeline.enqueue(makeRecordedEvent(globalPosition: 0))
        try await pipeline.waitForIdle()

        #expect(p1.appliedEvents.count == 1)
        #expect(p2.appliedEvents.count == 1)

        await pipeline.stop()
        await task.value
    }

    @Test func projectorsCanFilterEvents() async throws {
        let allEvents = RecordingProjector(id: "all")
        let onlyDeposits = FilteringProjector(acceptedTypes: ["Deposited"])
        let pipeline = ProjectionPipeline()
        await pipeline.register(allEvents)
        await pipeline.register(onlyDeposits)

        let task = Task { await pipeline.run() }

        await pipeline.enqueue(makeRecordedEvent(globalPosition: 0, eventType: "Deposited"))
        await pipeline.enqueue(makeRecordedEvent(globalPosition: 1, eventType: "Withdrawn"))
        await pipeline.enqueue(makeRecordedEvent(globalPosition: 2, eventType: "Deposited"))
        try await pipeline.waitForIdle()

        #expect(allEvents.appliedEvents.count == 3)
        #expect(onlyDeposits.appliedEvents.count == 2)

        await pipeline.stop()
        await task.value
    }

    // MARK: - Error Handling

    @Test func projectionErrorDoesNotStopPipeline() async throws {
        let failing = FailingProjector(failOnType: "Bad")
        let recording = RecordingProjector()
        let pipeline = ProjectionPipeline()
        await pipeline.register(failing)
        await pipeline.register(recording)

        let task = Task { await pipeline.run() }

        await pipeline.enqueue(makeRecordedEvent(globalPosition: 0, eventType: "Good"))
        await pipeline.enqueue(makeRecordedEvent(globalPosition: 1, eventType: "Bad"))
        await pipeline.enqueue(makeRecordedEvent(globalPosition: 2, eventType: "Good"))
        try await pipeline.waitForIdle()

        // Recording projector got all 3 events despite failing projector throwing on "Bad"
        #expect(recording.appliedEvents.count == 3)
        // Failing projector got the 2 "Good" events
        #expect(failing.appliedEvents.count == 2)

        await pipeline.stop()
        await task.value
    }

    // MARK: - Waiter Pattern

    @Test func waitForProjectionReturnsImmediatelyWhenAlreadyProjected() async throws {
        let pipeline = ProjectionPipeline()
        await pipeline.register(RecordingProjector())
        let task = Task { await pipeline.run() }

        await pipeline.enqueue(makeRecordedEvent(globalPosition: 0))
        try await pipeline.waitForIdle()

        // This should return immediately since position 0 is already projected
        try await pipeline.waitForProjection(upTo: 0)

        await pipeline.stop()
        await task.value
    }

    @Test func waitForIdleWithNoEventsReturnsImmediately() async throws {
        let pipeline = ProjectionPipeline()
        // Nothing enqueued, should return immediately
        try await pipeline.waitForIdle()
    }

    @Test func waitForProjectionTimesOut() async throws {
        let pipeline = ProjectionPipeline()
        // Don't start run() -- nothing will ever be projected

        await #expect(throws: ProjectionPipelineError.self) {
            try await pipeline.waitForProjection(upTo: 99, timeout: .milliseconds(50))
        }
    }

    // MARK: - Position Tracking

    @Test func currentPositionTracksProjectedEvents() async throws {
        let pipeline = ProjectionPipeline()
        await pipeline.register(RecordingProjector())
        let task = Task { await pipeline.run() }

        let initialPos = await pipeline.currentPosition
        #expect(initialPos == -1)

        await pipeline.enqueue(makeRecordedEvent(globalPosition: 0))
        await pipeline.enqueue(makeRecordedEvent(globalPosition: 1))
        await pipeline.enqueue(makeRecordedEvent(globalPosition: 2))
        try await pipeline.waitForIdle()

        let finalPos = await pipeline.currentPosition
        #expect(finalPos == 2)

        await pipeline.stop()
        await task.value
    }

    // MARK: - Stop

    @Test func stopCausesRunToExit() async throws {
        let pipeline = ProjectionPipeline()
        await pipeline.register(RecordingProjector())
        let task = Task { await pipeline.run() }

        await pipeline.enqueue(makeRecordedEvent(globalPosition: 0))
        try await pipeline.waitForIdle()

        await pipeline.stop()
        await task.value  // Should complete without hanging
    }

    @Test func stopResumesWaiters() async throws {
        let pipeline = ProjectionPipeline()
        let task = Task { await pipeline.run() }

        // Start waiting for a position that will never be projected
        let waiterTask = Task {
            try await pipeline.waitForProjection(upTo: 99, timeout: .seconds(30))
        }

        // Give the waiter time to register
        try await Task.sleep(for: .milliseconds(50))

        // Stop should resume the waiter
        await pipeline.stop()
        await task.value

        // Waiter should complete without throwing
        try await waiterTask.value
    }
}
```

**Step 2: Implement ProjectionPipeline**

Create `Sources/Songbird/ProjectionPipeline.swift`:

```swift
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
    private var waiters: [UInt64: (position: Int64, continuation: CheckedContinuation<Void, any Error>)] = [:]
    private var nextWaiterId: UInt64 = 0

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
            waiters[waiterId] = (position: globalPosition, continuation: cont)

            Task {
                try? await Task.sleep(for: timeout)
                self.timeoutWaiter(id: waiterId)
            }
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
            waiter.continuation.resume()
        }
    }

    private func resumeAllWaiters() {
        for (_, waiter) in waiters {
            waiter.continuation.resume()
        }
        waiters.removeAll()
    }

    private func timeoutWaiter(id: UInt64) {
        guard let waiter = waiters.removeValue(forKey: id) else {
            return  // Already resumed
        }
        waiter.continuation.resume(throwing: ProjectionPipelineError.timeout)
    }
}
```

**Step 3: Run tests**

Run: `swift test 2>&1`
Expected: All tests pass, zero warnings.

**Step 4: Commit**

```bash
git add Sources/Songbird/ProjectionPipeline.swift Tests/SongbirdTests/ProjectionPipelineTests.swift
git commit -m "Add ProjectionPipeline with waiter pattern

AsyncStream-based actor bridging write model to read model projectors.
Multi-projector dispatch, error isolation, CheckedContinuation waiters
with timeout. 10 tests covering dispatch, errors, waiting, and lifecycle."
```

---

### Task 2: Final review — clean build, all tests pass, changelog, push

**Step 1: Verify clean build**

Run: `swift build 2>&1`
Expected: Build complete, zero warnings, zero errors.

**Step 2: Verify all tests pass**

Run: `swift test 2>&1`
Expected: All tests pass.

**Step 3: Write changelog entry**

Create `changelog/0005-projection-pipeline.md`:

```markdown
# 0005 — Projection Pipeline

Implemented Phase 4 of Songbird:

- **ProjectionPipeline** — Actor-based async event delivery from write model to read model projectors
  - AsyncStream for non-blocking event enqueueing
  - Multi-projector dispatch (each projector receives all events, filters internally)
  - Error isolation (projection failures don't stop the pipeline)
  - Waiter pattern with timeout for read-after-write consistency
  - `waitForProjection(upTo:)` and `waitForIdle()` for synchronization
- **ProjectionPipelineError** — Timeout error for waiter expiration
```

**Step 4: Commit changelog and push**

```bash
git add changelog/0005-projection-pipeline.md
git commit -m "Add Phase 4 changelog entry"
git push
```
