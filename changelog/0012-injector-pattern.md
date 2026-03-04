# Injector Pattern Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build an AsyncSequence-based `Injector` protocol and `InjectorRunner` that brings external events into the event store, with a `didAppend` callback for cursor tracking.

**Architecture:** The `Injector` protocol produces an `AsyncSequence<InboundEvent>` that the `InjectorRunner` consumes, appending each event to the store and calling `didAppend` with the result. This is the inbound counterpart to the outbound `Gateway`/`GatewayRunner`. Integration with `SongbirdServices` via the existing `Runnable` pattern.

**Tech Stack:** Swift 6.2+, Songbird core types (`EventStore`, `RecordedEvent`), SongbirdTesting, SongbirdHummingbird

**Design doc:** `docs/plans/2026-03-04-injector-pattern-design.md`

---

## Task 1: InboundEvent + Injector Protocol

Create the core types in the Songbird module and verify a type can conform.

**Files:**
- Create: `Sources/Songbird/Injector.swift`
- Create: `Tests/SongbirdTests/InjectorTests.swift`

**Step 1: Create `Sources/Songbird/Injector.swift`**

```swift
import Foundation

/// An event from an external source, ready to be appended to the event store.
///
/// Wraps the three values that `EventStore.append` needs: a domain event,
/// the target stream, and metadata. Created by `Injector` implementations
/// and consumed by `InjectorRunner`.
public struct InboundEvent: Sendable {
    public let event: any Event
    public let stream: StreamName
    public let metadata: EventMetadata

    public init(event: any Event, stream: StreamName, metadata: EventMetadata) {
        self.event = event
        self.stream = stream
        self.metadata = metadata
    }
}

/// A boundary component for inbound external events (polling APIs, message queues, timers).
///
/// Injectors produce an `AsyncSequence` of `InboundEvent` values that the `InjectorRunner`
/// consumes and appends to the event store. After each append attempt, the runner calls
/// `didAppend` with the result so the injector can track its cursor and handle errors.
///
/// For request-driven inbound data (webhooks), use `eventStore.append()` directly
/// in the route handler instead — no `Injector` needed.
///
/// Usage:
/// ```swift
/// actor GitHubPoller: Injector {
///     let injectorId = "github-poller"
///
///     func events() -> any AsyncSequence<InboundEvent, any Error> {
///         AsyncThrowingStream<InboundEvent, Error> { continuation in
///             // Poll external API, yield InboundEvents
///         }
///     }
///
///     func didAppend(_ event: InboundEvent, result: Result<RecordedEvent, any Error>) {
///         // Advance cursor on success, log on failure
///     }
/// }
/// ```
public protocol Injector: Sendable {
    var injectorId: String { get }
    func events() -> any AsyncSequence<InboundEvent, any Error>
    func didAppend(_ event: InboundEvent, result: Result<RecordedEvent, any Error>) async
}
```

**Step 2: Create `Tests/SongbirdTests/InjectorTests.swift`**

```swift
import Foundation
import Testing

@testable import Songbird

private struct ExternalEvent: Event {
    var eventType: String { "ExternalEvent" }
}

private actor TestInjector: Injector {
    let injectorId = "test-injector"
    private(set) var appendResults: [Result<RecordedEvent, any Error>] = []

    func events() -> any AsyncSequence<InboundEvent, any Error> {
        AsyncThrowingStream<InboundEvent, Error> { continuation in
            continuation.yield(InboundEvent(
                event: ExternalEvent(),
                stream: StreamName(category: "external", id: "1"),
                metadata: EventMetadata()
            ))
            continuation.finish()
        }
    }

    func didAppend(_ event: InboundEvent, result: Result<RecordedEvent, any Error>) {
        appendResults.append(result)
    }
}

@Suite("Injector")
struct InjectorTests {
    @Test func injectorHasId() {
        let injector = TestInjector()
        #expect(injector.injectorId == "test-injector")
    }

    @Test func inboundEventHoldsValues() {
        let event = InboundEvent(
            event: ExternalEvent(),
            stream: StreamName(category: "external", id: "1"),
            metadata: EventMetadata()
        )
        #expect(event.stream.category == "external")
        #expect(event.stream.id == "1")
    }
}
```

**Step 3: Run tests to verify they pass**

Run: `swift test --filter InjectorTests 2>&1 | tail -10`
Expected: 2 tests PASS.

**Step 4: Commit**

```bash
git add Sources/Songbird/Injector.swift Tests/SongbirdTests/InjectorTests.swift
git commit -m "Add InboundEvent struct and Injector protocol"
```

---

## Task 2: InjectorRunner — Basic Event Delivery

Create the `InjectorRunner` actor and test that it appends events to the store and calls `didAppend`.

**Files:**
- Create: `Sources/Songbird/InjectorRunner.swift`
- Create: `Tests/SongbirdTests/InjectorRunnerTests.swift`

**Step 1: Write the test file with a reusable test injector and first test**

Create `Tests/SongbirdTests/InjectorRunnerTests.swift`:

```swift
import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

// MARK: - Test Types

private struct InjectorTestEvent: Event {
    var eventType: String { "InjectorTestEvent" }
    let value: Int
}

private actor RecordingInjector: Injector {
    let injectorId: String
    private let continuation: AsyncThrowingStream<InboundEvent, Error>.Continuation
    private let _events: AsyncThrowingStream<InboundEvent, Error>
    private(set) var appendResults: [Result<RecordedEvent, any Error>] = []

    init(id: String = "recording-injector") {
        self.injectorId = id
        let (stream, continuation) = AsyncThrowingStream<InboundEvent, Error>.makeStream()
        self._events = stream
        self.continuation = continuation
    }

    func events() -> any AsyncSequence<InboundEvent, any Error> {
        _events
    }

    func didAppend(_ event: InboundEvent, result: Result<RecordedEvent, any Error>) {
        appendResults.append(result)
    }

    nonisolated func yield(_ event: InboundEvent) {
        continuation.yield(event)
    }

    nonisolated func finish() {
        continuation.finish()
    }
}

// MARK: - Tests

@Suite("InjectorRunner")
struct InjectorRunnerTests {

    @Test func deliversEventsToStore() async throws {
        let store = InMemoryEventStore()
        let injector = RecordingInjector()

        let runner = InjectorRunner(injector: injector, store: store)

        let task = Task { try await runner.run() }

        // Yield an event through the injector
        let stream = StreamName(category: "external", id: "1")
        injector.yield(InboundEvent(
            event: InjectorTestEvent(value: 42),
            stream: stream,
            metadata: EventMetadata()
        ))

        // Give runner time to process
        try await Task.sleep(for: .milliseconds(50))

        // Finish the stream so the runner exits
        injector.finish()
        try await task.value

        // Assert event was appended to the store
        let events = try await store.readStream(stream, from: 0, maxCount: 100)
        #expect(events.count == 1)
        #expect(events[0].eventType == "InjectorTestEvent")

        // Assert didAppend was called with success
        let results = await injector.appendResults
        #expect(results.count == 1)
        if case .success = results[0] {} else {
            Issue.record("Expected .success, got .failure")
        }
    }

    @Test func callsDidAppendForEachEvent() async throws {
        let store = InMemoryEventStore()
        let injector = RecordingInjector()

        let runner = InjectorRunner(injector: injector, store: store)

        let task = Task { try await runner.run() }

        // Yield multiple events
        for i in 1...3 {
            injector.yield(InboundEvent(
                event: InjectorTestEvent(value: i),
                stream: StreamName(category: "external", id: "\(i)"),
                metadata: EventMetadata()
            ))
        }

        try await Task.sleep(for: .milliseconds(50))
        injector.finish()
        try await task.value

        let results = await injector.appendResults
        #expect(results.count == 3)

        // All should be successes
        for result in results {
            if case .failure = result {
                Issue.record("Expected all .success results")
            }
        }
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter InjectorRunnerTests 2>&1 | tail -10`
Expected: FAIL — `InjectorRunner` not found.

**Step 3: Implement InjectorRunner**

Create `Sources/Songbird/InjectorRunner.swift`:

```swift
/// An actor that runs an `Injector` by consuming its event sequence and appending each
/// event to the event store.
///
/// The runner:
/// 1. Calls `injector.events()` to get the inbound event sequence
/// 2. For each `InboundEvent`, calls `eventStore.append()` with `expectedVersion: nil`
/// 3. Calls `injector.didAppend()` with the result (success or failure)
///
/// Unlike `GatewayRunner`, the `InjectorRunner` has no `PositionStore` or `EventSubscription` —
/// the injector is responsible for tracking its own cursor in the external system via `didAppend`.
///
/// Usage:
/// ```swift
/// let runner = InjectorRunner(
///     injector: githubPoller,
///     store: eventStore
/// )
///
/// let task = Task { try await runner.run() }
///
/// // Later: cancel stops the runner
/// task.cancel()
/// ```
public actor InjectorRunner<I: Injector> {
    private let injector: I
    private let store: any EventStore

    public init(
        injector: I,
        store: any EventStore
    ) {
        self.injector = injector
        self.store = store
    }

    // MARK: - Lifecycle

    /// Starts the runner. This method blocks until the injector's sequence finishes
    /// or the enclosing `Task` is cancelled.
    public func run() async throws {
        for try await inbound in injector.events() {
            let result: Result<RecordedEvent, any Error>
            do {
                let recorded = try await store.append(
                    inbound.event,
                    to: inbound.stream,
                    metadata: inbound.metadata,
                    expectedVersion: nil
                )
                result = .success(recorded)
            } catch {
                result = .failure(error)
            }
            await injector.didAppend(inbound, result: result)
        }
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter InjectorRunnerTests 2>&1 | tail -10`
Expected: 2 tests PASS.

**Step 5: Commit**

```bash
git add Sources/Songbird/InjectorRunner.swift Tests/SongbirdTests/InjectorRunnerTests.swift
git commit -m "Add InjectorRunner with AsyncSequence-based event delivery"
```

---

## Task 3: InjectorRunner — Error Handling + Cancellation

Add tests for store failures reported via `didAppend`, sequence completion, and task cancellation.

**Files:**
- Modify: `Tests/SongbirdTests/InjectorRunnerTests.swift`

**Step 1: Add a FailingEventStore and error/cancellation tests**

Add before the `@Suite`, after the existing test types:

```swift
private struct InjectorTestError: Error {}

private actor FailingEventStore: EventStore {
    let inner = InMemoryEventStore()
    var shouldFail = false

    func setFailure(_ value: Bool) { shouldFail = value }

    func append(
        _ event: some Event,
        to stream: StreamName,
        metadata: EventMetadata,
        expectedVersion: Int64?
    ) async throws -> RecordedEvent {
        if shouldFail { throw InjectorTestError() }
        return try await inner.append(event, to: stream, metadata: metadata, expectedVersion: expectedVersion)
    }

    func readStream(_ stream: StreamName, from position: Int64, maxCount: Int) async throws -> [RecordedEvent] {
        try await inner.readStream(stream, from: position, maxCount: maxCount)
    }

    func readCategories(_ categories: [String], from globalPosition: Int64, maxCount: Int) async throws -> [RecordedEvent] {
        try await inner.readCategories(categories, from: globalPosition, maxCount: maxCount)
    }

    func readLastEvent(in stream: StreamName) async throws -> RecordedEvent? {
        try await inner.readLastEvent(in: stream)
    }

    func streamVersion(_ stream: StreamName) async throws -> Int64 {
        try await inner.streamVersion(stream)
    }
}
```

Add these tests inside the `InjectorRunnerTests` struct:

```swift
    @Test func didAppendReceivesFailureOnStoreError() async throws {
        let store = FailingEventStore()
        let injector = RecordingInjector()

        let runner = InjectorRunner(injector: injector, store: store)

        let task = Task { try await runner.run() }

        // First event: store will fail
        await store.setFailure(true)
        injector.yield(InboundEvent(
            event: InjectorTestEvent(value: 1),
            stream: StreamName(category: "external", id: "1"),
            metadata: EventMetadata()
        ))
        try await Task.sleep(for: .milliseconds(50))

        // Second event: store will succeed
        await store.setFailure(false)
        injector.yield(InboundEvent(
            event: InjectorTestEvent(value: 2),
            stream: StreamName(category: "external", id: "2"),
            metadata: EventMetadata()
        ))
        try await Task.sleep(for: .milliseconds(50))

        injector.finish()
        try await task.value

        let results = await injector.appendResults
        #expect(results.count == 2)

        // First should be failure
        if case .failure(let error) = results[0] {
            #expect(error is InjectorTestError)
        } else {
            Issue.record("Expected first result to be .failure")
        }

        // Second should be success
        if case .success = results[1] {} else {
            Issue.record("Expected second result to be .success")
        }
    }

    @Test func runnerContinuesAfterStoreError() async throws {
        let store = FailingEventStore()
        let injector = RecordingInjector()

        let runner = InjectorRunner(injector: injector, store: store)

        let task = Task { try await runner.run() }

        // Fail first, succeed second
        await store.setFailure(true)
        injector.yield(InboundEvent(
            event: InjectorTestEvent(value: 1),
            stream: StreamName(category: "external", id: "1"),
            metadata: EventMetadata()
        ))
        try await Task.sleep(for: .milliseconds(50))

        await store.setFailure(false)
        injector.yield(InboundEvent(
            event: InjectorTestEvent(value: 2),
            stream: StreamName(category: "external", id: "2"),
            metadata: EventMetadata()
        ))
        try await Task.sleep(for: .milliseconds(50))

        injector.finish()
        try await task.value

        // Only the second event should be in the store
        let events = try await store.inner.readAll(from: 0, maxCount: 100)
        #expect(events.count == 1)
        #expect(events[0].eventType == "InjectorTestEvent")
    }

    @Test func cancellationStopsTheRunner() async throws {
        let store = InMemoryEventStore()
        let injector = RecordingInjector()

        let runner = InjectorRunner(injector: injector, store: store)

        let task = Task { try await runner.run() }

        try await Task.sleep(for: .milliseconds(50))

        task.cancel()

        let result = await task.result
        switch result {
        case .success:
            break
        case .failure(let error):
            #expect(error is CancellationError)
        }
    }
```

**Step 2: Run tests to verify they all pass**

Run: `swift test --filter InjectorRunnerTests 2>&1 | tail -15`
Expected: 5 tests PASS.

**Step 3: Commit**

```bash
git add Tests/SongbirdTests/InjectorRunnerTests.swift
git commit -m "Add InjectorRunner tests for error handling and cancellation"
```

---

## Task 4: TestInjectorHarness

Create a test utility in `SongbirdTesting` for running injectors in isolation.

**Files:**
- Create: `Sources/SongbirdTesting/TestInjectorHarness.swift`
- Create: `Tests/SongbirdTestingTests/TestInjectorHarnessTests.swift`

**Step 1: Write the tests**

Create `Tests/SongbirdTestingTests/TestInjectorHarnessTests.swift`:

```swift
import Foundation
import Songbird
import Testing

@testable import SongbirdTesting

private struct HarnessEvent: Event {
    var eventType: String { "HarnessEvent" }
    let value: Int
}

private actor FiniteInjector: Injector {
    let injectorId = "finite-injector"
    private let inboundEvents: [InboundEvent]
    private(set) var appendResults: [Result<RecordedEvent, any Error>] = []

    init(events: [InboundEvent]) {
        self.inboundEvents = events
    }

    func events() -> any AsyncSequence<InboundEvent, any Error> {
        let items = inboundEvents
        return AsyncThrowingStream<InboundEvent, Error> { continuation in
            for item in items {
                continuation.yield(item)
            }
            continuation.finish()
        }
    }

    func didAppend(_ event: InboundEvent, result: Result<RecordedEvent, any Error>) {
        appendResults.append(result)
    }
}

@Suite("TestInjectorHarness")
struct TestInjectorHarnessTests {
    @Test func runsInjectorAndReturnsAppendedEvents() async throws {
        let injector = FiniteInjector(events: [
            InboundEvent(
                event: HarnessEvent(value: 1),
                stream: StreamName(category: "test", id: "1"),
                metadata: EventMetadata()
            ),
            InboundEvent(
                event: HarnessEvent(value: 2),
                stream: StreamName(category: "test", id: "2"),
                metadata: EventMetadata()
            ),
        ])

        let harness = TestInjectorHarness(injector: injector)
        let events = try await harness.run()

        #expect(events.count == 2)
        #expect(events[0].eventType == "HarnessEvent")
        #expect(events[1].eventType == "HarnessEvent")
    }

    @Test func didAppendCalledForEachEvent() async throws {
        let injector = FiniteInjector(events: [
            InboundEvent(
                event: HarnessEvent(value: 1),
                stream: StreamName(category: "test", id: "1"),
                metadata: EventMetadata()
            ),
        ])

        let harness = TestInjectorHarness(injector: injector)
        _ = try await harness.run()

        let results = await injector.appendResults
        #expect(results.count == 1)
        if case .success = results[0] {} else {
            Issue.record("Expected .success")
        }
    }

    @Test func emptyInjectorReturnsNoEvents() async throws {
        let injector = FiniteInjector(events: [])

        let harness = TestInjectorHarness(injector: injector)
        let events = try await harness.run()

        #expect(events.isEmpty)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter TestInjectorHarnessTests 2>&1 | tail -10`
Expected: FAIL — `TestInjectorHarness` not found.

**Step 3: Implement TestInjectorHarness**

Create `Sources/SongbirdTesting/TestInjectorHarness.swift`:

```swift
import Foundation
import Songbird

/// A harness for testing injectors in isolation, without `SongbirdServices` or external infrastructure.
///
/// Runs the injector's event sequence against an `InMemoryEventStore` via `InjectorRunner`
/// and returns all successfully appended events.
///
/// ```swift
/// let injector = MyPollingInjector(testData: items)
/// let harness = TestInjectorHarness(injector: injector)
/// let events = try await harness.run()
/// #expect(events.count == 3)
/// ```
public struct TestInjectorHarness<I: Injector> {
    /// The wrapped injector instance.
    public let injector: I

    /// The in-memory event store used for appending.
    public let store: InMemoryEventStore

    public init(injector: I, store: InMemoryEventStore = InMemoryEventStore()) {
        self.injector = injector
        self.store = store
    }

    /// Runs the injector until its event sequence finishes, then returns all appended events.
    ///
    /// The injector's sequence must be finite (complete) for this method to return.
    public func run() async throws -> [RecordedEvent] {
        let runner = InjectorRunner(injector: injector, store: store)
        try await runner.run()
        return try await store.readAll(from: 0, maxCount: Int.max)
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter TestInjectorHarnessTests 2>&1 | tail -10`
Expected: 3 tests PASS.

**Step 5: Commit**

```bash
git add Sources/SongbirdTesting/TestInjectorHarness.swift Tests/SongbirdTestingTests/TestInjectorHarnessTests.swift
git commit -m "Add TestInjectorHarness for isolated injector testing"
```

---

## Task 5: SongbirdServices.registerInjector

Add `registerInjector` to `SongbirdServices`, conforming `InjectorRunner` to the existing `Runnable` protocol.

**Files:**
- Modify: `Sources/SongbirdHummingbird/SongbirdServices.swift`
- Modify: `Tests/SongbirdHummingbirdTests/SongbirdServicesTests.swift`

**Step 1: Write the test**

Add a test injector actor to `Tests/SongbirdHummingbirdTests/SongbirdServicesTests.swift`, before the `@Suite`:

```swift
private struct ServicesInjectorEvent: Event {
    var eventType: String { "ServicesInjectorEvent" }
}

private actor ServicesTestInjector: Injector {
    let injectorId = "services-test-injector"
    private let continuation: AsyncThrowingStream<InboundEvent, Error>.Continuation
    private let _events: AsyncThrowingStream<InboundEvent, Error>
    private(set) var appendResults: [Result<RecordedEvent, any Error>] = []

    init() {
        let (stream, continuation) = AsyncThrowingStream<InboundEvent, Error>.makeStream()
        self._events = stream
        self.continuation = continuation
    }

    func events() -> any AsyncSequence<InboundEvent, any Error> {
        _events
    }

    func didAppend(_ event: InboundEvent, result: Result<RecordedEvent, any Error>) {
        appendResults.append(result)
    }

    nonisolated func yield(_ event: InboundEvent) {
        continuation.yield(event)
    }

    nonisolated func finish() {
        continuation.finish()
    }
}
```

Add this test inside the `SongbirdServicesTests` struct:

```swift
    @Test func registerInjectorAndRun() async throws {
        let store = InMemoryEventStore()
        let pipeline = ProjectionPipeline()
        let injector = ServicesTestInjector()

        var services = SongbirdServices(
            eventStore: store,
            projectionPipeline: pipeline,
            positionStore: InMemoryPositionStore(),
            eventRegistry: EventTypeRegistry()
        )
        services.registerInjector(injector)

        let serviceTask = Task { try await services.run() }

        // Yield an event through the injector
        injector.yield(InboundEvent(
            event: ServicesInjectorEvent(),
            stream: StreamName(category: "injected", id: "1"),
            metadata: EventMetadata()
        ))

        // Wait for the runner to process
        try await Task.sleep(for: .milliseconds(100))

        // Assert event was appended to the store
        let events = try await store.readStream(
            StreamName(category: "injected", id: "1"),
            from: 0,
            maxCount: 100
        )
        #expect(events.count == 1)

        // Assert didAppend was called
        let results = await injector.appendResults
        #expect(results.count == 1)

        serviceTask.cancel()
        try? await serviceTask.value
    }
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter SongbirdServicesTests 2>&1 | tail -10`
Expected: FAIL — `registerInjector` not found.

**Step 3: Implement registerInjector**

In `Sources/SongbirdHummingbird/SongbirdServices.swift`:

Add `InjectorRunner` conformance to `Runnable` after the existing conformances (after `extension GatewayRunner: Runnable {}`):

```swift
extension InjectorRunner: Runnable {}
```

Add the `registerInjector` method inside the `// MARK: - Registration` section, after `registerGateway`:

```swift
    /// Registers an injector to run as a background event producer.
    ///
    /// The runner is created eagerly and executes in the task group alongside
    /// the projection pipeline when `run()` is called.
    public mutating func registerInjector<I: Injector>(
        _ injector: I
    ) {
        let runner = InjectorRunner(
            injector: injector,
            store: eventStore
        )
        runners.append(runner)
    }
```

Update the struct-level doc comment to mention injectors. Change:

```swift
/// and gateways, then pass it to a `ServiceGroup` or `Application` (via its `services`
/// parameter). Gateways, process managers, and the projection pipeline all run concurrently
/// in the task group.
```

to:

```swift
/// and gateways, then pass it to a `ServiceGroup` or `Application` (via its `services`
/// parameter). Injectors, gateways, process managers, and the projection pipeline all run
/// concurrently in the task group.
```

Update the code example in the doc comment. After:

```swift
/// services.registerGateway(webhookNotifier, tickInterval: .seconds(1))
```

Add:

```swift
/// services.registerInjector(githubPoller)
```

Update the `run()` doc comment. Change:

```swift
    /// Starts the projection pipeline and all registered runners (process managers and gateways).
```

to:

```swift
    /// Starts the projection pipeline and all registered runners (process managers, gateways, and injectors).
```

And change:

```swift
    /// - Process manager and gateway runners are cancelled (their subscription polling loop exits)
```

to:

```swift
    /// - Process manager, gateway, and injector runners are cancelled (their event loops exit)
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter SongbirdServicesTests 2>&1 | tail -10`
Expected: 4 tests PASS (3 existing + 1 new).

**Step 5: Commit**

```bash
git add Sources/SongbirdHummingbird/SongbirdServices.swift Tests/SongbirdHummingbirdTests/SongbirdServicesTests.swift
git commit -m "Add registerInjector to SongbirdServices"
```

---

## Task 6: Clean Build + Full Test Suite

Verify the entire project builds cleanly and all tests pass.

**Step 1: Build all targets**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds with zero warnings from Songbird code.

**Step 2: Run all tests**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass (previous 233 + new injector tests).

**Step 3: Commit changelog**

```bash
git add changelog/0012-injector-pattern.md
git commit -m "Add Injector Pattern changelog entry"
```

---

## Summary

| Task | Component | Module | Files |
|------|-----------|--------|-------|
| 1 | InboundEvent + Injector protocol | Songbird | create 2 |
| 2 | InjectorRunner — basic delivery + didAppend | Songbird | create 2 |
| 3 | InjectorRunner — error handling + cancellation | Songbird | modify 1 |
| 4 | TestInjectorHarness | SongbirdTesting | create 2 |
| 5 | SongbirdServices.registerInjector | SongbirdHummingbird | modify 2 |
| 6 | Clean build + full test suite | all | verify |
