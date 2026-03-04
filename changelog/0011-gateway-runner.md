# Gateway Pattern (Notifier) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a subscription-based `GatewayRunner` that delivers events to `Gateway` implementations for outbound side effects, with position tracking for at-least-once delivery.

**Architecture:** The existing `Gateway` protocol gets a `static var categories` requirement. A new `GatewayRunner<G>` actor uses `EventSubscription` to poll for events and calls `gateway.handle(event)` for each. Errors are swallowed (gateway is responsible for its own retry). Integration with `SongbirdServices` via the existing `Runnable` pattern. A `TestGatewayHarness` provides isolated testing.

**Tech Stack:** Swift 6.2+, Songbird core types (`EventSubscription`, `PositionStore`), SongbirdTesting, SongbirdHummingbird

**Design doc:** `docs/plans/2026-03-04-gateway-pattern-design.md`

---

## Task 1: Update Gateway Protocol

Add `static var categories: [String]` to the `Gateway` protocol and fix the existing `GatewayTests` to conform.

**Files:**
- Modify: `Sources/Songbird/Gateway.swift`
- Modify: `Tests/SongbirdTests/GatewayTests.swift`

**Step 1: Update the Gateway protocol**

Replace `Sources/Songbird/Gateway.swift` with:

```swift
/// A boundary component for outbound side effects (email, webhooks, API calls).
///
/// Gateways subscribe to event categories via `EventSubscription` and receive events
/// through `handle(_:)`. They must be idempotent — events may be delivered more than once
/// (at-least-once delivery). Core components (aggregates, projectors, process managers)
/// must never perform side effects directly; all external interaction goes through gateways.
///
/// Usage:
/// ```swift
/// actor WebhookNotifier: Gateway {
///     let gatewayId = "webhook-notifier"
///     static let categories = ["order", "payment"]
///
///     func handle(_ event: RecordedEvent) async throws {
///         // Send webhook, call external API, etc.
///     }
/// }
/// ```
public protocol Gateway: Sendable {
    var gatewayId: String { get }
    static var categories: [String] { get }
    func handle(_ event: RecordedEvent) async throws
}
```

**Step 2: Update GatewayTests to add categories**

In `Tests/SongbirdTests/GatewayTests.swift`, add `static let categories = ["test"]` to the `TestNotifier` actor:

```swift
actor TestNotifier: Gateway {
    let gatewayId = "test-notifier"
    static let categories = ["test"]
    private(set) var handledEvents: [RecordedEvent] = []

    func handle(_ event: RecordedEvent) async throws {
        handledEvents.append(event)
    }
}
```

**Step 3: Run tests to verify they pass**

Run: `swift test --filter GatewayTests 2>&1 | tail -10`
Expected: 2 tests PASS.

**Step 4: Commit**

```bash
git add Sources/Songbird/Gateway.swift Tests/SongbirdTests/GatewayTests.swift
git commit -m "Add static categories requirement to Gateway protocol"
```

---

## Task 2: GatewayRunner — Basic Event Delivery

Create the `GatewayRunner` actor that subscribes to a gateway's categories and calls `handle()` for each event.

**Files:**
- Create: `Sources/Songbird/GatewayRunner.swift`
- Create: `Tests/SongbirdTests/GatewayRunnerTests.swift`

**Step 1: Write the test file with domain types and first test**

Create `Tests/SongbirdTests/GatewayRunnerTests.swift`:

```swift
import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

// MARK: - Test Gateway

private struct GatewayRunnerTestEvent: Event {
    var eventType: String { "GatewayTestEvent" }
    let value: Int
}

private actor RecordingGateway: Gateway {
    let gatewayId = "recording-gateway"
    static let categories = ["gw-test"]
    private(set) var handledEvents: [RecordedEvent] = []

    func handle(_ event: RecordedEvent) async throws {
        handledEvents.append(event)
    }
}

// MARK: - Tests

@Suite("GatewayRunner")
struct GatewayRunnerTests {

    func makeStores() -> (InMemoryEventStore, InMemoryPositionStore) {
        (InMemoryEventStore(), InMemoryPositionStore())
    }

    @Test func deliversEventsToGateway() async throws {
        let (store, positionStore) = makeStores()
        let gateway = RecordingGateway()

        let runner = GatewayRunner(
            gateway: gateway,
            store: store,
            positionStore: positionStore,
            tickInterval: .milliseconds(10)
        )

        let task = Task { try await runner.run() }

        // Append an event in the gateway's subscribed category
        _ = try await store.append(
            GatewayRunnerTestEvent(value: 42),
            to: StreamName(category: "gw-test", id: "1"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Wait for the runner to process
        try await Task.sleep(for: .milliseconds(100))

        let count = await gateway.handledEvents.count
        #expect(count == 1)

        task.cancel()
        _ = await task.result
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter GatewayRunnerTests 2>&1 | tail -10`
Expected: FAIL — `GatewayRunner` not found.

**Step 3: Implement GatewayRunner**

Create `Sources/Songbird/GatewayRunner.swift`:

```swift
/// An actor that runs a `Gateway` by subscribing to its declared categories and calling
/// `handle(_:)` for each event.
///
/// The runner:
/// 1. Creates an `EventSubscription` for `G.categories` with `gateway.gatewayId` as subscriber ID
/// 2. For each incoming event, calls `gateway.handle(event)`
/// 3. Errors from `handle()` are logged but do not stop the subscription loop
///
/// Position is persisted by the underlying `EventSubscription`, providing at-least-once delivery.
/// Gateways must be idempotent since events may be redelivered after a crash.
///
/// Usage:
/// ```swift
/// let runner = GatewayRunner(
///     gateway: webhookNotifier,
///     store: eventStore,
///     positionStore: positionStore
/// )
///
/// let task = Task { try await runner.run() }
///
/// // Later: cancel stops the subscription loop
/// task.cancel()
/// ```
public actor GatewayRunner<G: Gateway> {
    private let gateway: G
    private let store: any EventStore
    private let positionStore: any PositionStore
    private let batchSize: Int
    private let tickInterval: Duration

    public init(
        gateway: G,
        store: any EventStore,
        positionStore: any PositionStore,
        batchSize: Int = 100,
        tickInterval: Duration = .milliseconds(100)
    ) {
        self.gateway = gateway
        self.store = store
        self.positionStore = positionStore
        self.batchSize = batchSize
        self.tickInterval = tickInterval
    }

    // MARK: - Lifecycle

    /// Starts the runner. This method blocks until the enclosing `Task` is cancelled.
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
            do {
                try await gateway.handle(event)
            } catch {
                // Gateway errors are logged but do not stop the subscription.
                // The gateway is responsible for its own retry logic.
            }
        }
    }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter GatewayRunnerTests 2>&1 | tail -10`
Expected: 1 test PASS.

**Step 5: Commit**

```bash
git add Sources/Songbird/GatewayRunner.swift Tests/SongbirdTests/GatewayRunnerTests.swift
git commit -m "Add GatewayRunner with subscription-based event delivery"
```

---

## Task 3: GatewayRunner — Error Handling, Ignoring, Cancellation

Add tests for error swallowing, events from non-subscribed categories being ignored, and cancellation.

**Files:**
- Modify: `Tests/SongbirdTests/GatewayRunnerTests.swift`

**Step 1: Add a FailingGateway and more tests**

Add to `Tests/SongbirdTests/GatewayRunnerTests.swift`, before the `@Suite`:

```swift
private actor FailingGateway: Gateway {
    let gatewayId = "failing-gateway"
    static let categories = ["gw-test"]
    private(set) var attemptCount = 0
    private(set) var successCount = 0

    func handle(_ event: RecordedEvent) async throws {
        attemptCount += 1
        if event.eventType == "GatewayTestEvent" {
            throw GatewayTestError()
        }
        successCount += 1
    }
}

private struct GatewayTestError: Error {}

private struct OtherCategoryEvent: Event {
    var eventType: String { "OtherEvent" }
}
```

Add these tests inside the `GatewayRunnerTests` struct:

```swift
    @Test func errorInHandleDoesNotStopRunner() async throws {
        let (store, positionStore) = makeStores()
        let gateway = FailingGateway()

        let runner = GatewayRunner(
            gateway: gateway,
            store: store,
            positionStore: positionStore,
            tickInterval: .milliseconds(10)
        )

        let task = Task { try await runner.run() }

        // Append two events — first will fail, second should still be delivered
        _ = try await store.append(
            GatewayRunnerTestEvent(value: 1),
            to: StreamName(category: "gw-test", id: "1"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )
        _ = try await store.append(
            OtherCategoryEvent(),
            to: StreamName(category: "gw-test", id: "2"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        try await Task.sleep(for: .milliseconds(100))

        // Both events were attempted
        let attempts = await gateway.attemptCount
        #expect(attempts == 2)

        // Only the non-failing event succeeded
        let successes = await gateway.successCount
        #expect(successes == 1)

        task.cancel()
        _ = await task.result
    }

    @Test func ignoresEventsFromNonSubscribedCategories() async throws {
        let (store, positionStore) = makeStores()
        let gateway = RecordingGateway()

        let runner = GatewayRunner(
            gateway: gateway,
            store: store,
            positionStore: positionStore,
            tickInterval: .milliseconds(10)
        )

        let task = Task { try await runner.run() }

        // Append event in a category the gateway does NOT subscribe to
        _ = try await store.append(
            GatewayRunnerTestEvent(value: 99),
            to: StreamName(category: "other-category", id: "1"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Append event in the subscribed category
        _ = try await store.append(
            GatewayRunnerTestEvent(value: 42),
            to: StreamName(category: "gw-test", id: "1"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        try await Task.sleep(for: .milliseconds(100))

        // Only the subscribed category event was delivered
        let count = await gateway.handledEvents.count
        #expect(count == 1)

        task.cancel()
        _ = await task.result
    }

    @Test func cancellationStopsTheRunner() async throws {
        let (store, positionStore) = makeStores()
        let gateway = RecordingGateway()

        let runner = GatewayRunner(
            gateway: gateway,
            store: store,
            positionStore: positionStore,
            tickInterval: .milliseconds(10)
        )

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

Run: `swift test --filter GatewayRunnerTests 2>&1 | tail -15`
Expected: 4 tests PASS.

**Step 3: Commit**

```bash
git add Tests/SongbirdTests/GatewayRunnerTests.swift
git commit -m "Add GatewayRunner tests for error handling, filtering, and cancellation"
```

---

## Task 4: TestGatewayHarness

Create a test utility in `SongbirdTesting` for feeding events to a gateway in isolation.

**Files:**
- Create: `Sources/SongbirdTesting/TestGatewayHarness.swift`
- Create: `Tests/SongbirdTestingTests/TestGatewayHarnessTests.swift`

**Step 1: Write the tests**

Create `Tests/SongbirdTestingTests/TestGatewayHarnessTests.swift`:

```swift
import Foundation
import Songbird
import Testing

@testable import SongbirdTesting

private struct HarnessTestEvent: Event {
    var eventType: String { "HarnessTestEvent" }
    let value: Int
}

private actor SuccessGateway: Gateway {
    let gatewayId = "success-gateway"
    static let categories = ["test"]
    private(set) var received: [RecordedEvent] = []

    func handle(_ event: RecordedEvent) async throws {
        received.append(event)
    }
}

private actor SelectiveGateway: Gateway {
    let gatewayId = "selective-gateway"
    static let categories = ["test"]

    func handle(_ event: RecordedEvent) async throws {
        if event.eventType == "bad" {
            throw SelectiveError()
        }
    }
}

private struct SelectiveError: Error {}

private struct BadEvent: Event {
    var eventType: String { "bad" }
}

@Suite("TestGatewayHarness")
struct TestGatewayHarnessTests {
    @Test func tracksProcessedEvents() async throws {
        let gateway = SuccessGateway()
        var harness = TestGatewayHarness(gateway: gateway)

        let event = try RecordedEvent(event: HarnessTestEvent(value: 1))
        await harness.given(event)

        #expect(harness.processedEvents.count == 1)
        #expect(harness.errors.isEmpty)
    }

    @Test func capturesErrorsWithoutThrowing() async throws {
        let gateway = SelectiveGateway()
        var harness = TestGatewayHarness(gateway: gateway)

        let badEvent = try RecordedEvent(event: BadEvent())
        await harness.given(badEvent)

        #expect(harness.processedEvents.isEmpty)
        #expect(harness.errors.count == 1)
        #expect(harness.errors[0].1 is SelectiveError)
    }

    @Test func tracksMultipleEventsAndErrors() async throws {
        let gateway = SelectiveGateway()
        var harness = TestGatewayHarness(gateway: gateway)

        let goodEvent = try RecordedEvent(event: HarnessTestEvent(value: 1))
        let badEvent = try RecordedEvent(event: BadEvent())

        await harness.given(goodEvent)
        await harness.given(badEvent)
        await harness.given(goodEvent)

        #expect(harness.processedEvents.count == 2)
        #expect(harness.errors.count == 1)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter TestGatewayHarnessTests 2>&1 | tail -10`
Expected: FAIL — `TestGatewayHarness` not found.

**Step 3: Implement TestGatewayHarness**

Create `Sources/SongbirdTesting/TestGatewayHarness.swift`:

```swift
import Foundation
import Songbird

/// A value-type harness for testing gateways in isolation, without a subscription or runner.
///
/// Feeds events to the gateway's `handle` method and records successes and failures.
/// Does not throw from `given()` — errors are captured for later assertion.
///
/// ```swift
/// let gateway = WebhookNotifier()
/// var harness = TestGatewayHarness(gateway: gateway)
/// await harness.given(try RecordedEvent(event: OrderPlaced()))
/// #expect(harness.processedEvents.count == 1)
/// #expect(harness.errors.isEmpty)
/// ```
public struct TestGatewayHarness<G: Gateway> {
    /// The wrapped gateway instance.
    public let gateway: G

    /// Events that were successfully handled.
    public private(set) var processedEvents: [RecordedEvent] = []

    /// Events that caused an error, paired with the error.
    public private(set) var errors: [(RecordedEvent, any Error)] = []

    public init(gateway: G) {
        self.gateway = gateway
    }

    /// Feeds an event to the gateway's `handle` method.
    /// Records success or failure without throwing.
    public mutating func given(_ event: RecordedEvent) async {
        do {
            try await gateway.handle(event)
            processedEvents.append(event)
        } catch {
            errors.append((event, error))
        }
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter TestGatewayHarnessTests 2>&1 | tail -10`
Expected: 3 tests PASS.

**Step 5: Commit**

```bash
git add Sources/SongbirdTesting/TestGatewayHarness.swift Tests/SongbirdTestingTests/TestGatewayHarnessTests.swift
git commit -m "Add TestGatewayHarness for isolated gateway testing"
```

---

## Task 5: SongbirdServices.registerGateway

Add `registerGateway` to `SongbirdServices`, conforming `GatewayRunner` to the existing `Runnable` protocol.

**Files:**
- Modify: `Sources/SongbirdHummingbird/SongbirdServices.swift`
- Modify: `Tests/SongbirdHummingbirdTests/SongbirdServicesTests.swift`

**Step 1: Write the test**

Add to `Tests/SongbirdHummingbirdTests/SongbirdServicesTests.swift`.

Add this gateway type before the `@Suite`:

```swift
private actor ServicesTestGateway: Gateway {
    let gatewayId = "services-test-gateway"
    static let categories = ["svc-test"]
    private(set) var handledEvents: [RecordedEvent] = []

    func handle(_ event: RecordedEvent) async throws {
        handledEvents.append(event)
    }
}
```

Add this test inside the `SongbirdServicesTests` struct:

```swift
    @Test func registerGatewayAndRun() async throws {
        let store = InMemoryEventStore()
        let pipeline = ProjectionPipeline()
        let gateway = ServicesTestGateway()

        var services = SongbirdServices(
            eventStore: store,
            projectionPipeline: pipeline,
            positionStore: InMemoryPositionStore(),
            eventRegistry: EventTypeRegistry()
        )
        services.registerGateway(gateway, tickInterval: .milliseconds(10))

        let serviceTask = Task { try await services.run() }

        // Append an event in the gateway's subscribed category
        _ = try await store.append(
            ServicesTestEvent(),
            to: StreamName(category: "svc-test", id: "1"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Wait for the gateway runner to poll and process
        try await Task.sleep(for: .milliseconds(100))

        let count = await gateway.handledEvents.count
        #expect(count == 1)

        serviceTask.cancel()
        try? await serviceTask.value
    }
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter SongbirdServicesTests 2>&1 | tail -10`
Expected: FAIL — `registerGateway` not found.

**Step 3: Implement registerGateway**

In `Sources/SongbirdHummingbird/SongbirdServices.swift`:

Add `GatewayRunner` conformance to `Runnable` after the `ProcessManagerRunner` conformance (line 13):

```swift
extension GatewayRunner: Runnable {}
```

Add the `registerGateway` method inside the `// MARK: - Registration` section, after `registerProcessManager` (after line 79):

```swift
    /// Registers a gateway to run as a background subscription.
    ///
    /// The runner is created eagerly and executes in the task group alongside
    /// the projection pipeline when `run()` is called.
    public mutating func registerGateway<G: Gateway>(
        _ gateway: G,
        batchSize: Int = 100,
        tickInterval: Duration = .milliseconds(100)
    ) {
        let runner = GatewayRunner(
            gateway: gateway,
            store: eventStore,
            positionStore: positionStore,
            batchSize: batchSize,
            tickInterval: tickInterval
        )
        runners.append(runner)
    }
```

Update the doc comment on `SongbirdServices` to mention gateways (line 20):

```swift
/// then pass it to a `ServiceGroup` or `Application` (via its `services` parameter).
```

Replace with:

```swift
/// then pass it to a `ServiceGroup` or `Application` (via its `services` parameter).
/// Gateways, process managers, and the projection pipeline all run concurrently in the task group.
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter SongbirdServicesTests 2>&1 | tail -10`
Expected: 3 tests PASS (2 existing + 1 new).

**Step 5: Commit**

```bash
git add Sources/SongbirdHummingbird/SongbirdServices.swift Tests/SongbirdHummingbirdTests/SongbirdServicesTests.swift
git commit -m "Add registerGateway to SongbirdServices"
```

---

## Task 6: Clean Build + Full Test Suite

Verify the entire project builds cleanly and all tests pass.

**Step 1: Build all targets**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds with zero warnings from Songbird code.

**Step 2: Run all tests**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass (previous 225 + new gateway tests).

**Step 3: Commit changelog**

```bash
git add changelog/0011-gateway-runner.md
git commit -m "Add Gateway Pattern changelog entry"
```

---

## Summary

| Task | Component | Module | Files |
|------|-----------|--------|-------|
| 1 | Gateway protocol update (add categories) | Songbird | modify 2 |
| 2 | GatewayRunner — basic delivery | Songbird | create 2 |
| 3 | GatewayRunner — error/filter/cancel tests | Songbird | modify 1 |
| 4 | TestGatewayHarness | SongbirdTesting | create 2 |
| 5 | SongbirdServices.registerGateway | SongbirdHummingbird | modify 2 |
| 6 | Clean build + full test suite | all | verify |
