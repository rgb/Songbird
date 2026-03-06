# Metrics & Observability Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add framework-level metrics to all Songbird components using swift-metrics.

**Architecture:** Components emit metrics via the swift-metrics facade (Counter, Timer, Gauge). EventStore gets a `MetricsEventStore` decorator. ProjectionPipeline, EventSubscription, and GatewayRunner get metrics built in. `TestMetricsFactory` in SongbirdTesting captures metrics for test assertions.

**Tech Stack:** swift-metrics 2.x, Swift Testing, ContinuousClock for timing

**Design doc:** `docs/plans/2026-03-06-metrics-observability-design.md`

---

### Task 1: Package.swift + TestMetricsFactory

**Files:**
- Modify: `Package.swift`
- Create: `Sources/SongbirdTesting/TestMetricsFactory.swift`
- Create: `Tests/SongbirdTests/TestMetricsFactoryTests.swift`

**Context:** swift-metrics is Apple's standard metrics abstraction. Components call `Counter(label:).increment()`, `Timer(label:).recordNanoseconds()`, `Gauge(label:).record()`. If no backend is bootstrapped, these are no-ops. `TestMetricsFactory` is a backend that captures values in memory for test assertions.

**Step 1: Modify Package.swift**

Add swift-metrics dependency to the `dependencies` array:
```swift
.package(url: "https://github.com/apple/swift-metrics.git", from: "2.0.0"),
```

Add `Metrics` product to the `Songbird` target:
```swift
.target(
    name: "Songbird",
    dependencies: [
        .product(name: "Metrics", package: "swift-metrics"),
    ]
),
```

No changes to other targets — `Metrics` is transitively available to `SongbirdTesting` and all test targets via the `Songbird` dependency.

**Step 2: Write the failing test**

Create `Tests/SongbirdTests/TestMetricsFactoryTests.swift`:

```swift
import Metrics
import Testing
@testable import SongbirdTesting

@Suite(.serialized)
struct TestMetricsFactoryTests {
    init() {
        TestMetricsFactory.bootstrap()
        TestMetricsFactory.shared.reset()
    }

    @Test func counterIncrements() {
        Counter(label: "test_counter").increment()
        Counter(label: "test_counter").increment(by: 4)

        let counter = TestMetricsFactory.shared.counter("test_counter")
        #expect(counter?.totalValue == 5)
    }

    @Test func timerRecordsValues() {
        Metrics.Timer(label: "test_timer").recordNanoseconds(1000)
        Metrics.Timer(label: "test_timer").recordNanoseconds(2000)

        let timer = TestMetricsFactory.shared.timer("test_timer")
        #expect(timer?.values == [1000, 2000])
    }

    @Test func gaugeRecordsLastValue() {
        Gauge(label: "test_gauge").record(42)
        Gauge(label: "test_gauge").record(99)

        let gauge = TestMetricsFactory.shared.gauge("test_gauge")
        #expect(gauge?.lastValue == 99)
    }

    @Test func dimensionsCreateSeparateHandlers() {
        Counter(label: "dim_counter", dimensions: [("env", "prod")]).increment()
        Counter(label: "dim_counter", dimensions: [("env", "test")]).increment(by: 3)

        let prod = TestMetricsFactory.shared.counter("dim_counter", dimensions: [("env", "prod")])
        let test = TestMetricsFactory.shared.counter("dim_counter", dimensions: [("env", "test")])
        #expect(prod?.totalValue == 1)
        #expect(test?.totalValue == 3)
    }

    @Test func resetClearsAllValues() {
        Counter(label: "reset_counter").increment()
        Metrics.Timer(label: "reset_timer").recordNanoseconds(100)
        Gauge(label: "reset_gauge").record(50)

        TestMetricsFactory.shared.reset()

        #expect(TestMetricsFactory.shared.counter("reset_counter")?.totalValue == 0)
        #expect(TestMetricsFactory.shared.timer("reset_timer")?.values.isEmpty == true)
        #expect(TestMetricsFactory.shared.gauge("reset_gauge")?.lastValue == nil)
    }
}
```

**Step 3: Run test to verify it fails**

Run: `swift test --filter TestMetricsFactoryTests 2>&1 | head -30`
Expected: Compilation error — `TestMetricsFactory` doesn't exist yet.

**Step 4: Implement TestMetricsFactory**

Create `Sources/SongbirdTesting/TestMetricsFactory.swift`:

```swift
import Foundation
import Metrics

/// A swift-metrics backend that captures all emitted metrics in memory for test assertions.
///
/// Usage:
/// ```swift
/// // Once per test process:
/// TestMetricsFactory.bootstrap()
///
/// // Before each test:
/// TestMetricsFactory.shared.reset()
///
/// // After running code that emits metrics:
/// let counter = TestMetricsFactory.shared.counter("my_counter")
/// #expect(counter?.totalValue == 1)
/// ```
public final class TestMetricsFactory: MetricsFactory, @unchecked Sendable {
    public static let shared = TestMetricsFactory()

    private static let _doBootstrap: Bool = {
        MetricsSystem.bootstrap(TestMetricsFactory.shared)
        return true
    }()

    /// Bootstrap the global MetricsSystem with this factory. Safe to call multiple times.
    public static func bootstrap() {
        _ = _doBootstrap
    }

    private let lock = NSLock()
    private var _counters: [String: TestCounter] = [:]
    private var _timers: [String: TestTimer] = [:]
    private var _recorders: [String: TestRecorder] = [:]

    init() {}

    /// Reset all metric values. Call before each test to start fresh.
    public func reset() {
        lock.withLock {
            for counter in _counters.values { counter.reset() }
            for timer in _timers.values { timer.reset() }
            for recorder in _recorders.values { recorder.reset() }
        }
    }

    // MARK: - MetricsFactory

    public func makeCounter(label: String, dimensions: [(String, String)]) -> CounterHandler {
        lock.withLock {
            let key = Self.makeKey(label, dimensions)
            if let existing = _counters[key] { return existing }
            let handler = TestCounter()
            _counters[key] = handler
            return handler
        }
    }

    public func makeRecorder(label: String, dimensions: [(String, String)], aggregate: Bool) -> RecorderHandler {
        lock.withLock {
            let key = Self.makeKey(label, dimensions)
            if let existing = _recorders[key] { return existing }
            let handler = TestRecorder()
            _recorders[key] = handler
            return handler
        }
    }

    public func makeTimer(label: String, dimensions: [(String, String)]) -> TimerHandler {
        lock.withLock {
            let key = Self.makeKey(label, dimensions)
            if let existing = _timers[key] { return existing }
            let handler = TestTimer()
            _timers[key] = handler
            return handler
        }
    }

    public func destroyCounter(_ handler: CounterHandler) {}
    public func destroyRecorder(_ handler: RecorderHandler) {}
    public func destroyTimer(_ handler: TimerHandler) {}

    // MARK: - Query API

    public func counter(_ label: String, dimensions: [(String, String)] = []) -> TestCounter? {
        lock.withLock { _counters[Self.makeKey(label, dimensions)] }
    }

    public func timer(_ label: String, dimensions: [(String, String)] = []) -> TestTimer? {
        lock.withLock { _timers[Self.makeKey(label, dimensions)] }
    }

    public func gauge(_ label: String, dimensions: [(String, String)] = []) -> TestRecorder? {
        lock.withLock { _recorders[Self.makeKey(label, dimensions)] }
    }

    // MARK: - Key Construction

    private static func makeKey(_ label: String, _ dimensions: [(String, String)]) -> String {
        if dimensions.isEmpty { return label }
        let dims = dimensions.sorted { $0.0 < $1.0 }.map { "\($0.0)=\($0.1)" }.joined(separator: ",")
        return "\(label)[\(dims)]"
    }
}

// MARK: - Test Metric Handlers

public final class TestCounter: CounterHandler, @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var totalValue: Int64 = 0

    public func increment(by amount: Int64) {
        lock.withLock { totalValue += amount }
    }

    public func reset() {
        lock.withLock { totalValue = 0 }
    }
}

public final class TestTimer: TimerHandler, @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var values: [Int64] = []

    public var lastValue: Int64? { lock.withLock { values.last } }

    public func recordNanoseconds(_ duration: Int64) {
        lock.withLock { values.append(duration) }
    }

    public func reset() {
        lock.withLock { values.removeAll() }
    }
}

public final class TestRecorder: RecorderHandler, @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var lastValue: Double?
    public private(set) var values: [Double] = []

    public func record(_ value: Int64) {
        lock.withLock {
            let d = Double(value)
            lastValue = d
            values.append(d)
        }
    }

    public func record(_ value: Double) {
        lock.withLock {
            lastValue = value
            values.append(value)
        }
    }

    public func reset() {
        lock.withLock {
            lastValue = nil
            values.removeAll()
        }
    }
}
```

**Step 5: Run tests to verify they pass**

Run: `swift test --filter TestMetricsFactoryTests 2>&1 | tail -20`
Expected: All 5 tests pass.

**Step 6: Commit**

```bash
git add Package.swift Sources/SongbirdTesting/TestMetricsFactory.swift Tests/SongbirdTests/TestMetricsFactoryTests.swift
git commit -m "Add swift-metrics dependency and TestMetricsFactory"
```

---

### Task 2: MetricsEventStore Decorator

**Files:**
- Create: `Sources/Songbird/MetricsEventStore.swift`
- Create: `Tests/SongbirdTests/MetricsEventStoreTests.swift`

**Context:** `MetricsEventStore<Inner: EventStore>` wraps any EventStore, emitting metrics for every operation. Follows the same decorator pattern as `CryptoShreddingStore`. See `Sources/Songbird/CryptoShreddingStore.swift` for the pattern. Composition: `MetricsEventStore(CryptoShreddingStore(SQLiteEventStore(...)))`.

**Metrics emitted:**
- `songbird_event_store_append_total` Counter — dimensions: `stream_category`
- `songbird_event_store_append_duration_seconds` Timer — dimensions: `stream_category`
- `songbird_event_store_read_duration_seconds` Timer — dimensions: `stream_category` (when applicable), `read_type`
- `songbird_event_store_read_events_total` Counter — no dimensions
- `songbird_event_store_version_conflict_total` Counter — dimensions: `stream_category`

**Step 1: Write the failing tests**

Create `Tests/SongbirdTests/MetricsEventStoreTests.swift`:

```swift
import Metrics
import Testing
@testable import Songbird
@testable import SongbirdTesting

@Suite(.serialized)
struct MetricsEventStoreTests {
    struct TestEvent: Event {
        let data: String
        var eventType: String { "TestEvent" }
    }

    init() {
        TestMetricsFactory.bootstrap()
        TestMetricsFactory.shared.reset()
    }

    private func makeStore() -> MetricsEventStore<InMemoryEventStore> {
        MetricsEventStore(inner: InMemoryEventStore())
    }

    @Test func appendEmitsCounterAndTimer() async throws {
        let store = makeStore()
        let stream = StreamName(category: "order", id: "1")

        _ = try await store.append(
            TestEvent(data: "hello"), to: stream,
            metadata: EventMetadata(), expectedVersion: nil
        )

        let counter = TestMetricsFactory.shared.counter(
            "songbird_event_store_append_total",
            dimensions: [("stream_category", "order")]
        )
        #expect(counter?.totalValue == 1)

        let timer = TestMetricsFactory.shared.timer(
            "songbird_event_store_append_duration_seconds",
            dimensions: [("stream_category", "order")]
        )
        #expect(timer != nil)
        #expect(timer!.values.count == 1)
        #expect(timer!.values[0] > 0)
    }

    @Test func readStreamEmitsTimerAndEventCount() async throws {
        let store = makeStore()
        let stream = StreamName(category: "order", id: "1")

        _ = try await store.append(
            TestEvent(data: "a"), to: stream,
            metadata: EventMetadata(), expectedVersion: nil
        )
        _ = try await store.append(
            TestEvent(data: "b"), to: stream,
            metadata: EventMetadata(), expectedVersion: 0
        )
        TestMetricsFactory.shared.reset()

        _ = try await store.readStream(stream, from: 0, maxCount: 10)

        let timer = TestMetricsFactory.shared.timer(
            "songbird_event_store_read_duration_seconds",
            dimensions: [("stream_category", "order"), ("read_type", "stream")]
        )
        #expect(timer?.values.count == 1)

        let eventCount = TestMetricsFactory.shared.counter("songbird_event_store_read_events_total")
        #expect(eventCount?.totalValue == 2)
    }

    @Test func readCategoriesEmitsMetrics() async throws {
        let store = makeStore()

        _ = try await store.append(
            TestEvent(data: "a"), to: StreamName(category: "order", id: "1"),
            metadata: EventMetadata(), expectedVersion: nil
        )
        TestMetricsFactory.shared.reset()

        _ = try await store.readCategories(["order"], from: 0, maxCount: 10)

        let timer = TestMetricsFactory.shared.timer(
            "songbird_event_store_read_duration_seconds",
            dimensions: [("read_type", "categories")]
        )
        #expect(timer?.values.count == 1)
    }

    @Test func readAllUsesAllReadType() async throws {
        let store = makeStore()

        _ = try await store.append(
            TestEvent(data: "a"), to: StreamName(category: "order", id: "1"),
            metadata: EventMetadata(), expectedVersion: nil
        )
        TestMetricsFactory.shared.reset()

        _ = try await store.readAll(from: 0, maxCount: 10)

        let timer = TestMetricsFactory.shared.timer(
            "songbird_event_store_read_duration_seconds",
            dimensions: [("read_type", "all")]
        )
        #expect(timer?.values.count == 1)
    }

    @Test func readLastEventEmitsMetrics() async throws {
        let store = makeStore()
        let stream = StreamName(category: "order", id: "1")

        _ = try await store.append(
            TestEvent(data: "a"), to: stream,
            metadata: EventMetadata(), expectedVersion: nil
        )
        TestMetricsFactory.shared.reset()

        _ = try await store.readLastEvent(in: stream)

        let timer = TestMetricsFactory.shared.timer(
            "songbird_event_store_read_duration_seconds",
            dimensions: [("stream_category", "order"), ("read_type", "lastEvent")]
        )
        #expect(timer?.values.count == 1)

        let eventCount = TestMetricsFactory.shared.counter("songbird_event_store_read_events_total")
        #expect(eventCount?.totalValue == 1)
    }

    @Test func versionConflictEmitsCounter() async throws {
        let store = makeStore()
        let stream = StreamName(category: "order", id: "1")

        _ = try await store.append(
            TestEvent(data: "first"), to: stream,
            metadata: EventMetadata(), expectedVersion: nil
        )
        TestMetricsFactory.shared.reset()

        do {
            _ = try await store.append(
                TestEvent(data: "conflict"), to: stream,
                metadata: EventMetadata(), expectedVersion: 99
            )
        } catch {}

        let counter = TestMetricsFactory.shared.counter(
            "songbird_event_store_version_conflict_total",
            dimensions: [("stream_category", "order")]
        )
        #expect(counter?.totalValue == 1)

        // Append counter should NOT increment on conflict
        let appendCounter = TestMetricsFactory.shared.counter(
            "songbird_event_store_append_total",
            dimensions: [("stream_category", "order")]
        )
        #expect(appendCounter == nil || appendCounter?.totalValue == 0)
    }

    @Test func streamVersionEmitsNoMetrics() async throws {
        let store = makeStore()
        let stream = StreamName(category: "order", id: "1")

        _ = try await store.append(
            TestEvent(data: "a"), to: stream,
            metadata: EventMetadata(), expectedVersion: nil
        )
        TestMetricsFactory.shared.reset()

        _ = try await store.streamVersion(stream)

        // streamVersion is lightweight — no metrics
        let timer = TestMetricsFactory.shared.timer(
            "songbird_event_store_read_duration_seconds",
            dimensions: [("read_type", "streamVersion")]
        )
        #expect(timer == nil)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter MetricsEventStoreTests 2>&1 | head -30`
Expected: Compilation error — `MetricsEventStore` doesn't exist yet.

**Step 3: Implement MetricsEventStore**

Create `Sources/Songbird/MetricsEventStore.swift`:

```swift
import Metrics

/// A decorator that wraps any ``EventStore``, emitting swift-metrics for every operation.
///
/// Composition order:
/// ```swift
/// MetricsEventStore(CryptoShreddingStore(SQLiteEventStore(...)))
/// ```
///
/// Metrics on the outside measure total time including any middleware (encryption, etc.).
/// All metrics are prefixed with `songbird_event_store_`.
///
/// If no `MetricsSystem` backend is bootstrapped, all metric calls are zero-cost no-ops.
public struct MetricsEventStore<Inner: EventStore>: Sendable {
    private let inner: Inner

    public init(inner: Inner) {
        self.inner = inner
    }
}

// MARK: - EventStore Conformance

extension MetricsEventStore: EventStore {
    public func append(
        _ event: some Event,
        to stream: StreamName,
        metadata: EventMetadata,
        expectedVersion: Int64?
    ) async throws -> RecordedEvent {
        let dims: [(String, String)] = [("stream_category", stream.category)]
        let start = ContinuousClock.now

        do {
            let result = try await inner.append(
                event, to: stream, metadata: metadata, expectedVersion: expectedVersion
            )
            let elapsed = ContinuousClock.now - start

            Counter(label: "songbird_event_store_append_total", dimensions: dims).increment()
            Metrics.Timer(label: "songbird_event_store_append_duration_seconds", dimensions: dims)
                .recordNanoseconds(elapsed.nanoseconds)

            return result
        } catch let error as VersionConflictError {
            Counter(label: "songbird_event_store_version_conflict_total", dimensions: dims).increment()
            throw error
        }
    }

    public func readStream(
        _ stream: StreamName,
        from position: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        let dims: [(String, String)] = [("stream_category", stream.category), ("read_type", "stream")]
        let start = ContinuousClock.now

        let results = try await inner.readStream(stream, from: position, maxCount: maxCount)
        let elapsed = ContinuousClock.now - start

        Metrics.Timer(label: "songbird_event_store_read_duration_seconds", dimensions: dims)
            .recordNanoseconds(elapsed.nanoseconds)
        Counter(label: "songbird_event_store_read_events_total")
            .increment(by: Int64(results.count))

        return results
    }

    public func readCategories(
        _ categories: [String],
        from globalPosition: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        let readType = categories.isEmpty ? "all" : "categories"
        let dims: [(String, String)] = [("read_type", readType)]
        let start = ContinuousClock.now

        let results = try await inner.readCategories(
            categories, from: globalPosition, maxCount: maxCount
        )
        let elapsed = ContinuousClock.now - start

        Metrics.Timer(label: "songbird_event_store_read_duration_seconds", dimensions: dims)
            .recordNanoseconds(elapsed.nanoseconds)
        Counter(label: "songbird_event_store_read_events_total")
            .increment(by: Int64(results.count))

        return results
    }

    public func readLastEvent(
        in stream: StreamName
    ) async throws -> RecordedEvent? {
        let dims: [(String, String)] = [("stream_category", stream.category), ("read_type", "lastEvent")]
        let start = ContinuousClock.now

        let result = try await inner.readLastEvent(in: stream)
        let elapsed = ContinuousClock.now - start

        Metrics.Timer(label: "songbird_event_store_read_duration_seconds", dimensions: dims)
            .recordNanoseconds(elapsed.nanoseconds)
        Counter(label: "songbird_event_store_read_events_total")
            .increment(by: result != nil ? 1 : 0)

        return result
    }

    public func streamVersion(
        _ stream: StreamName
    ) async throws -> Int64 {
        try await inner.streamVersion(stream)
    }
}

// MARK: - Duration Extension

extension Duration {
    /// Convert to nanoseconds for swift-metrics Timer recording.
    var nanoseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter MetricsEventStoreTests 2>&1 | tail -20`
Expected: All 7 tests pass.

**Step 5: Commit**

```bash
git add Sources/Songbird/MetricsEventStore.swift Tests/SongbirdTests/MetricsEventStoreTests.swift
git commit -m "Add MetricsEventStore decorator with event store metrics"
```

---

### Task 3: ProjectionPipeline Metrics

**Files:**
- Modify: `Sources/Songbird/ProjectionPipeline.swift:1-2,49-63,71-74`
- Create: `Tests/SongbirdTests/ProjectionPipelineMetricsTests.swift`

**Context:** ProjectionPipeline is an actor (see `Sources/Songbird/ProjectionPipeline.swift`). Add metrics directly since there's only one implementation. The pipeline processes events from an AsyncStream and dispatches them to registered projectors.

**Metrics emitted:**
- `songbird_projection_lag` Gauge — `enqueuedPosition - projectedPosition`, recorded after each event is processed
- `songbird_projection_process_duration_seconds` Timer — time per projector `apply()` call, dimensions: `projector_id`
- `songbird_projection_queue_depth` Gauge — `enqueuedPosition - projectedPosition`, recorded when events are enqueued

**Step 1: Write the failing tests**

Create `Tests/SongbirdTests/ProjectionPipelineMetricsTests.swift`:

```swift
import Metrics
import Testing
@testable import Songbird
@testable import SongbirdTesting

@Suite(.serialized)
struct ProjectionPipelineMetricsTests {
    struct MetricsTestEvent: Event {
        var eventType: String { "MetricsTestEvent" }
    }

    init() {
        TestMetricsFactory.bootstrap()
        TestMetricsFactory.shared.reset()
    }

    @Test func processingRecordsTimerPerProjector() async throws {
        let pipeline = ProjectionPipeline()
        let projector = RecordingProjector(projectorId: "test-projector")
        await pipeline.register(projector)

        let task = Task { await pipeline.run() }

        let event = try RecordedEvent(event: MetricsTestEvent(), globalPosition: 0)
        await pipeline.enqueue(event)
        try await pipeline.waitForIdle()
        await pipeline.stop()
        await task.value

        let timer = TestMetricsFactory.shared.timer(
            "songbird_projection_process_duration_seconds",
            dimensions: [("projector_id", "test-projector")]
        )
        #expect(timer != nil)
        #expect(timer!.values.count == 1)
        #expect(timer!.values[0] > 0)
    }

    @Test func lagGaugeUpdatesAfterProcessing() async throws {
        let pipeline = ProjectionPipeline()
        let projector = RecordingProjector(projectorId: "lag-projector")
        await pipeline.register(projector)

        let task = Task { await pipeline.run() }

        // Enqueue two events
        let event1 = try RecordedEvent(event: MetricsTestEvent(), globalPosition: 0)
        let event2 = try RecordedEvent(event: MetricsTestEvent(), globalPosition: 1)
        await pipeline.enqueue(event1)
        await pipeline.enqueue(event2)
        try await pipeline.waitForIdle()
        await pipeline.stop()
        await task.value

        let lag = TestMetricsFactory.shared.gauge("songbird_projection_lag")
        #expect(lag != nil)
        // After processing all events, lag should be 0
        #expect(lag?.lastValue == 0)
    }

    @Test func queueDepthUpdatesOnEnqueue() async throws {
        let pipeline = ProjectionPipeline()
        let projector = RecordingProjector(projectorId: "depth-projector")
        await pipeline.register(projector)

        let task = Task { await pipeline.run() }

        let event = try RecordedEvent(event: MetricsTestEvent(), globalPosition: 0)
        await pipeline.enqueue(event)
        try await pipeline.waitForIdle()
        await pipeline.stop()
        await task.value

        let depth = TestMetricsFactory.shared.gauge("songbird_projection_queue_depth")
        #expect(depth != nil)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter ProjectionPipelineMetricsTests 2>&1 | head -30`
Expected: FAIL — metrics are not emitted yet.

**Step 3: Modify ProjectionPipeline to emit metrics**

In `Sources/Songbird/ProjectionPipeline.swift`:

Add `import Metrics` at the top (after `import Foundation`).

In `run()`, wrap each `projector.apply(event)` call with timing, and record lag after processing:

Replace the current `run()` body (lines 49-63):
```swift
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
```

With:
```swift
public func run() async {
    for await event in stream {
        for projector in projectors {
            let start = ContinuousClock.now
            do {
                try await projector.apply(event)
            } catch {
                // Projection errors are logged but do not stop the pipeline.
                // In production, integrate with os.Logger or a logging framework.
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
```

In `enqueue()`, add queue depth recording after yielding (lines 71-74):

Replace:
```swift
public func enqueue(_ event: RecordedEvent) {
    enqueuedPosition = event.globalPosition
    continuation.yield(event)
}
```

With:
```swift
public func enqueue(_ event: RecordedEvent) {
    enqueuedPosition = event.globalPosition
    continuation.yield(event)
    Gauge(label: "songbird_projection_queue_depth")
        .record(Double(enqueuedPosition - projectedPosition))
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter ProjectionPipelineMetricsTests 2>&1 | tail -20`
Expected: All 3 tests pass.

Also run existing pipeline tests to verify no regressions:

Run: `swift test --filter ProjectionPipelineTests 2>&1 | tail -20`
Expected: All existing tests still pass.

**Step 5: Commit**

```bash
git add Sources/Songbird/ProjectionPipeline.swift Tests/SongbirdTests/ProjectionPipelineMetricsTests.swift
git commit -m "Add metrics to ProjectionPipeline"
```

---

### Task 4: EventSubscription + GatewayRunner Metrics

**Files:**
- Modify: `Sources/Songbird/EventSubscription.swift:1-2,84-110,112-157`
- Modify: `Sources/Songbird/GatewayRunner.swift:1,49-67`
- Create: `Tests/SongbirdTests/GatewayRunnerMetricsTests.swift`

**Context:**
- `EventSubscription` (see `Sources/Songbird/EventSubscription.swift`) is a polling-based AsyncSequence. Its `Iterator` fetches batches from the store and yields events one at a time. Subscription-level metrics (position, batch size, tick duration) go here.
- `GatewayRunner` (see `Sources/Songbird/GatewayRunner.swift`) is an actor that creates an EventSubscription and calls `gateway.handle(event)` for each event. Gateway-specific metrics (delivery timing, success/failure counts, handler errors) go here.
- Both are tested together because GatewayRunner exercises EventSubscription internally.

**Metrics emitted by EventSubscription:**
- `songbird_subscription_position` Gauge — dimensions: `subscriber_id`
- `songbird_subscription_batch_size` Gauge — dimensions: `subscriber_id`
- `songbird_subscription_tick_duration_seconds` Timer — dimensions: `subscriber_id`

**Metrics emitted by GatewayRunner:**
- `songbird_gateway_delivery_duration_seconds` Timer — dimensions: `gateway_id`
- `songbird_gateway_delivery_total` Counter — dimensions: `gateway_id`, `status` (success/failure)
- `songbird_subscription_errors_total` Counter — dimensions: `subscriber_id`

**Step 1: Write the failing tests**

Create `Tests/SongbirdTests/GatewayRunnerMetricsTests.swift`:

```swift
import Metrics
import Testing
@testable import Songbird
@testable import SongbirdTesting

@Suite(.serialized)
struct GatewayRunnerMetricsTests {
    struct GatewayMetricsEvent: Event {
        let data: String
        var eventType: String { "GatewayMetricsEvent" }
    }

    actor SuccessGateway: Gateway {
        static let categories: [String] = ["gw-metrics"]
        let gatewayId = "success-gw"
        var handledCount = 0

        func handle(_ event: RecordedEvent) async throws {
            handledCount += 1
        }
    }

    actor FailingGateway: Gateway {
        static let categories: [String] = ["gw-metrics"]
        let gatewayId = "failing-gw"

        func handle(_ event: RecordedEvent) async throws {
            throw TestGatewayError()
        }
    }

    struct TestGatewayError: Error {}

    init() {
        TestMetricsFactory.bootstrap()
        TestMetricsFactory.shared.reset()
    }

    @Test func successfulDeliveryEmitsMetrics() async throws {
        let store = InMemoryEventStore()
        let positionStore = InMemoryPositionStore()
        let gateway = SuccessGateway()

        let runner = GatewayRunner(
            gateway: gateway, store: store, positionStore: positionStore,
            tickInterval: .milliseconds(10)
        )
        let task = Task { try await runner.run() }

        _ = try await store.append(
            GatewayMetricsEvent(data: "hello"),
            to: StreamName(category: "gw-metrics", id: "1"),
            metadata: EventMetadata(), expectedVersion: nil
        )

        // Wait for processing
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        _ = await task.result

        // Gateway delivery metrics
        let successCounter = TestMetricsFactory.shared.counter(
            "songbird_gateway_delivery_total",
            dimensions: [("gateway_id", "success-gw"), ("status", "success")]
        )
        #expect(successCounter?.totalValue == 1)

        let deliveryTimer = TestMetricsFactory.shared.timer(
            "songbird_gateway_delivery_duration_seconds",
            dimensions: [("gateway_id", "success-gw")]
        )
        #expect(deliveryTimer?.values.count == 1)

        // Subscription metrics (emitted by EventSubscription)
        let position = TestMetricsFactory.shared.gauge(
            "songbird_subscription_position",
            dimensions: [("subscriber_id", "success-gw")]
        )
        #expect(position != nil)

        let batchSize = TestMetricsFactory.shared.gauge(
            "songbird_subscription_batch_size",
            dimensions: [("subscriber_id", "success-gw")]
        )
        #expect(batchSize != nil)
        #expect(batchSize!.lastValue == 1)

        let tickTimer = TestMetricsFactory.shared.timer(
            "songbird_subscription_tick_duration_seconds",
            dimensions: [("subscriber_id", "success-gw")]
        )
        #expect(tickTimer != nil)
    }

    @Test func failedDeliveryEmitsFailureStatus() async throws {
        let store = InMemoryEventStore()
        let positionStore = InMemoryPositionStore()
        let gateway = FailingGateway()

        let runner = GatewayRunner(
            gateway: gateway, store: store, positionStore: positionStore,
            tickInterval: .milliseconds(10)
        )
        let task = Task { try await runner.run() }

        _ = try await store.append(
            GatewayMetricsEvent(data: "hello"),
            to: StreamName(category: "gw-metrics", id: "1"),
            metadata: EventMetadata(), expectedVersion: nil
        )

        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        _ = await task.result

        let failureCounter = TestMetricsFactory.shared.counter(
            "songbird_gateway_delivery_total",
            dimensions: [("gateway_id", "failing-gw"), ("status", "failure")]
        )
        #expect(failureCounter?.totalValue == 1)

        let errorsCounter = TestMetricsFactory.shared.counter(
            "songbird_subscription_errors_total",
            dimensions: [("subscriber_id", "failing-gw")]
        )
        #expect(errorsCounter?.totalValue == 1)

        // Timer still records even on failure
        let deliveryTimer = TestMetricsFactory.shared.timer(
            "songbird_gateway_delivery_duration_seconds",
            dimensions: [("gateway_id", "failing-gw")]
        )
        #expect(deliveryTimer?.values.count == 1)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter GatewayRunnerMetricsTests 2>&1 | head -30`
Expected: FAIL — metrics are not emitted yet.

**Step 3: Modify EventSubscription to emit subscription metrics**

In `Sources/Songbird/EventSubscription.swift`:

Add `import Metrics` after `import Foundation`.

Add metric properties to `Iterator` (after the existing stored properties at lines 91-94):

```swift
private let positionGauge: Gauge
private let batchSizeGauge: Gauge
private let tickDurationTimer: Metrics.Timer
```

Initialize them in `Iterator.init` (after the existing assignments at lines 103-109):

```swift
self.positionGauge = Gauge(
    label: "songbird_subscription_position",
    dimensions: [("subscriber_id", subscriberId)]
)
self.batchSizeGauge = Gauge(
    label: "songbird_subscription_batch_size",
    dimensions: [("subscriber_id", subscriberId)]
)
self.tickDurationTimer = Metrics.Timer(
    label: "songbird_subscription_tick_duration_seconds",
    dimensions: [("subscriber_id", subscriberId)]
)
```

In `next()`, add metrics at three points:

After saving position (around line 132, after `globalPosition = lastPosition`):
```swift
positionGauge.record(Double(lastPosition))
```

Time the `readCategories` call (around line 140):
```swift
// Replace:
let batch = try await store.readCategories(
    categories,
    from: globalPosition + 1,
    maxCount: batchSize
)

// With:
let tickStart = ContinuousClock.now
let batch = try await store.readCategories(
    categories,
    from: globalPosition + 1,
    maxCount: batchSize
)
let tickElapsed = ContinuousClock.now - tickStart
tickDurationTimer.recordNanoseconds(tickElapsed.nanoseconds)
```

Record batch size when a non-empty batch arrives (around line 146, after `if !batch.isEmpty`):
```swift
batchSizeGauge.record(Double(batch.count))
```

**Step 4: Modify GatewayRunner to emit gateway metrics**

In `Sources/Songbird/GatewayRunner.swift`:

Add `import Metrics` at the top.

Replace the `run()` method body (lines 49-67):

```swift
public func run() async throws {
    let subscription = EventSubscription(
        subscriberId: gateway.gatewayId,
        categories: G.categories,
        store: store,
        positionStore: positionStore,
        batchSize: batchSize,
        tickInterval: tickInterval
    )

    for try await event in subscription {
        let start = ContinuousClock.now
        do {
            try await gateway.handle(event)
            let elapsed = ContinuousClock.now - start
            Metrics.Timer(
                label: "songbird_gateway_delivery_duration_seconds",
                dimensions: [("gateway_id", gateway.gatewayId)]
            ).recordNanoseconds(elapsed.nanoseconds)
            Counter(
                label: "songbird_gateway_delivery_total",
                dimensions: [("gateway_id", gateway.gatewayId), ("status", "success")]
            ).increment()
        } catch {
            let elapsed = ContinuousClock.now - start
            Metrics.Timer(
                label: "songbird_gateway_delivery_duration_seconds",
                dimensions: [("gateway_id", gateway.gatewayId)]
            ).recordNanoseconds(elapsed.nanoseconds)
            Counter(
                label: "songbird_gateway_delivery_total",
                dimensions: [("gateway_id", gateway.gatewayId), ("status", "failure")]
            ).increment()
            Counter(
                label: "songbird_subscription_errors_total",
                dimensions: [("subscriber_id", gateway.gatewayId)]
            ).increment()
            // Gateway errors are swallowed and do not stop the subscription.
            // The gateway is responsible for its own retry/logging logic.
        }
    }
}
```

**Step 5: Run tests to verify they pass**

Run: `swift test --filter GatewayRunnerMetricsTests 2>&1 | tail -20`
Expected: All tests pass.

Also run existing gateway tests to verify no regressions:

Run: `swift test --filter GatewayRunnerTests 2>&1 | tail -20`
Expected: All existing tests still pass.

**Step 6: Commit**

```bash
git add Sources/Songbird/EventSubscription.swift Sources/Songbird/GatewayRunner.swift Tests/SongbirdTests/GatewayRunnerMetricsTests.swift
git commit -m "Add metrics to EventSubscription and GatewayRunner"
```

---

### Task 5: Clean Build + Full Test Suite + Changelog

**Files:**
- Verify: all source and test files
- Create: `changelog/0026-metrics-observability.md`

**Step 1: Run full build**

Run: `swift build 2>&1 | tail -20`
Expected: Build succeeded with no warnings.

**Step 2: Run full test suite**

Run: `swift test 2>&1 | tail -40`
Expected: All tests pass across all test targets. Note: SongbirdPostgresTests require Docker.

**Step 3: Write changelog**

Create `changelog/0026-metrics-observability.md`:

```markdown
# 0026 — Metrics & Observability

Framework-level metrics for Songbird using swift-metrics. Components emit metrics via the standard facade; calls are zero-cost no-ops unless the app bootstraps a backend (Prometheus, StatsD, etc.).

## What Changed

### Package.swift

- Added `swift-metrics` (from 2.0.0) dependency
- Added `Metrics` product to `Songbird` core target

### Core Types (Songbird module)

- **`MetricsEventStore<Inner: EventStore>`** — Decorator wrapping any EventStore. Emits append counter, append timer, read timer, read event count, and version conflict counter. All with `songbird_event_store_` prefix. Follows same pattern as `CryptoShreddingStore`.

- **`ProjectionPipeline`** — Now emits projection lag gauge, per-projector processing timer, and queue depth gauge. All with `songbird_projection_` prefix.

- **`EventSubscription`** — Now emits subscription position gauge, batch size gauge, and tick duration timer. All with `songbird_subscription_` prefix. Dimensions include `subscriber_id`.

- **`GatewayRunner`** — Now emits delivery duration timer, delivery total counter (with success/failure status), and subscription error counter. All with `songbird_gateway_` prefix. Dimensions include `gateway_id`.

- **`Duration.nanoseconds`** — Internal extension for converting `Duration` to nanoseconds for swift-metrics Timer recording.

### Testing (SongbirdTesting module)

- **`TestMetricsFactory`** — swift-metrics backend that captures metrics in memory. Singleton with `bootstrap()` and `reset()`. Query via `counter(_:dimensions:)`, `timer(_:dimensions:)`, `gauge(_:dimensions:)`.

- **`TestCounter`**, **`TestTimer`**, **`TestRecorder`** — In-memory metric handlers for test assertions.

## Metrics Reference

| Metric | Type | Dimensions |
|--------|------|------------|
| `songbird_event_store_append_total` | Counter | `stream_category` |
| `songbird_event_store_append_duration_seconds` | Timer | `stream_category` |
| `songbird_event_store_read_duration_seconds` | Timer | `stream_category`, `read_type` |
| `songbird_event_store_read_events_total` | Counter | |
| `songbird_event_store_version_conflict_total` | Counter | `stream_category` |
| `songbird_projection_lag` | Gauge | |
| `songbird_projection_process_duration_seconds` | Timer | `projector_id` |
| `songbird_projection_queue_depth` | Gauge | |
| `songbird_subscription_position` | Gauge | `subscriber_id` |
| `songbird_subscription_batch_size` | Gauge | `subscriber_id` |
| `songbird_subscription_tick_duration_seconds` | Timer | `subscriber_id` |
| `songbird_subscription_errors_total` | Counter | `subscriber_id` |
| `songbird_gateway_delivery_duration_seconds` | Timer | `gateway_id` |
| `songbird_gateway_delivery_total` | Counter | `gateway_id`, `status` |

## Files Added

- `Sources/Songbird/MetricsEventStore.swift`
- `Sources/SongbirdTesting/TestMetricsFactory.swift`
- `Tests/SongbirdTests/TestMetricsFactoryTests.swift`
- `Tests/SongbirdTests/MetricsEventStoreTests.swift`
- `Tests/SongbirdTests/ProjectionPipelineMetricsTests.swift`
- `Tests/SongbirdTests/GatewayRunnerMetricsTests.swift`

## Files Modified

- `Package.swift` — Added swift-metrics dependency
- `Sources/Songbird/ProjectionPipeline.swift` — Added metrics emission
- `Sources/Songbird/EventSubscription.swift` — Added metrics emission
- `Sources/Songbird/GatewayRunner.swift` — Added metrics emission

## Test Coverage

- 5 tests for TestMetricsFactory (counter, timer, gauge, dimensions, reset)
- 7 tests for MetricsEventStore (append, reads, version conflict, streamVersion)
- 3 tests for ProjectionPipeline metrics (processing timer, lag gauge, queue depth)
- 2 tests for GatewayRunner metrics (success delivery, failure delivery with errors)
```

**Step 4: Commit**

```bash
git add changelog/0026-metrics-observability.md
git commit -m "Add metrics and observability changelog entry"
```
