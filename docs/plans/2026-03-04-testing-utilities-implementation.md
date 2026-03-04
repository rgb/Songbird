# Testing Utilities Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add 7 reusable testing utilities to the `SongbirdTesting` module and refactor existing tests to use them, eliminating duplicated boilerplate.

**Architecture:** All new code goes into `Sources/SongbirdTesting/`. The convenience initializer extends `RecordedEvent` (defined in `Songbird` core). Three test projectors are promoted from `ProjectionPipelineTests.swift`. Three harnesses are new value types that wrap aggregate, projector, and process manager protocols respectively. After implementation, existing test files are refactored to use the new utilities.

**Tech Stack:** Swift 6.2+, Swift Testing (`@Test`, `#expect`), Songbird core protocols (`Event`, `Aggregate`, `Projector`, `ProcessManager`, `CommandHandler`, `EventReaction`, `AnyReaction`).

---

### Task 1: RecordedEvent Convenience Initializer

**Files:**
- Create: `Sources/SongbirdTesting/RecordedEvent+Testing.swift`
- Create: `Tests/SongbirdTestingTests/RecordedEventTestingTests.swift`

**Step 1: Write the failing test**

Create `Tests/SongbirdTestingTests/RecordedEventTestingTests.swift`:

```swift
import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

// Reusable test event for SongbirdTesting tests
enum TestWidgetEvent: Event {
    case created(name: String)
    case renamed(newName: String)

    var eventType: String {
        switch self {
        case .created: "WidgetCreated"
        case .renamed: "WidgetRenamed"
        }
    }
}

@Suite("RecordedEvent+Testing")
struct RecordedEventTestingTests {

    @Test func encodesTypedEventToRecordedEvent() throws {
        let event = TestWidgetEvent.created(name: "Sprocket")
        let recorded = try RecordedEvent(event: event)

        #expect(recorded.eventType == "WidgetCreated")
        // Round-trip: decode back to typed event
        let decoded = try recorded.decode(TestWidgetEvent.self).event
        #expect(decoded == TestWidgetEvent.created(name: "Sprocket"))
    }

    @Test func usesProvidedStreamName() throws {
        let stream = StreamName(category: "widget", id: "w-1")
        let recorded = try RecordedEvent(
            event: TestWidgetEvent.created(name: "Gear"),
            streamName: stream
        )
        #expect(recorded.streamName == stream)
    }

    @Test func usesProvidedPositions() throws {
        let recorded = try RecordedEvent(
            event: TestWidgetEvent.created(name: "Cog"),
            position: 5,
            globalPosition: 42
        )
        #expect(recorded.position == 5)
        #expect(recorded.globalPosition == 42)
    }

    @Test func usesProvidedMetadata() throws {
        let meta = EventMetadata(traceId: "trace-1", userId: "user-1")
        let recorded = try RecordedEvent(
            event: TestWidgetEvent.created(name: "Bolt"),
            metadata: meta
        )
        #expect(recorded.metadata == meta)
    }

    @Test func defaultsAreReasonable() throws {
        let recorded = try RecordedEvent(event: TestWidgetEvent.renamed(newName: "Widget2"))
        #expect(recorded.position == 0)
        #expect(recorded.globalPosition == 0)
        #expect(recorded.streamName == StreamName(category: "test", id: "1"))
        #expect(recorded.metadata == EventMetadata())
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter SongbirdTestingTests`
Expected: Compilation error — `RecordedEvent` has no `init(event:...)` initializer.

**Step 3: Write the implementation**

Create `Sources/SongbirdTesting/RecordedEvent+Testing.swift`:

```swift
import Foundation
import Songbird

extension RecordedEvent {
    /// Creates a `RecordedEvent` from a typed `Event` by JSON-encoding it.
    ///
    /// Provides sensible defaults for all metadata fields, making it easy to
    /// construct test events without boilerplate.
    public init<E: Event>(
        event: E,
        id: UUID = UUID(),
        streamName: StreamName = StreamName(category: "test", id: "1"),
        position: Int64 = 0,
        globalPosition: Int64 = 0,
        metadata: EventMetadata = EventMetadata(),
        timestamp: Date = Date()
    ) throws {
        self.init(
            id: id,
            streamName: streamName,
            position: position,
            globalPosition: globalPosition,
            eventType: event.eventType,
            data: try JSONEncoder().encode(event),
            metadata: metadata,
            timestamp: timestamp
        )
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter SongbirdTestingTests`
Expected: All 5 tests pass, zero warnings.

**Step 5: Commit**

```bash
git add Sources/SongbirdTesting/RecordedEvent+Testing.swift Tests/SongbirdTestingTests/RecordedEventTestingTests.swift
git commit -m "Add RecordedEvent convenience initializer for testing"
```

---

### Task 2: Test Projectors (RecordingProjector, FilteringProjector, FailingProjector)

**Files:**
- Create: `Sources/SongbirdTesting/TestProjectors.swift`
- Create: `Tests/SongbirdTestingTests/TestProjectorsTests.swift`

**Context:** These three projectors currently live as private types inside `Tests/SongbirdTests/ProjectionPipelineTests.swift` (lines 8–58). We promote them to `SongbirdTesting` with public access and add dedicated tests.

**Step 1: Write the failing tests**

Create `Tests/SongbirdTestingTests/TestProjectorsTests.swift`:

```swift
import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

@Suite("TestProjectors")
struct TestProjectorsTests {

    // MARK: - RecordingProjector

    @Test func recordingProjectorRecordsAllEvents() async throws {
        let projector = RecordingProjector()
        let event = try RecordedEvent(event: TestWidgetEvent.created(name: "A"))
        try await projector.apply(event)
        let events = await projector.appliedEvents
        #expect(events.count == 1)
    }

    @Test func recordingProjectorUsesDefaultId() async {
        let projector = RecordingProjector()
        #expect(projector.projectorId == "recording")
    }

    @Test func recordingProjectorUsesCustomId() async {
        let projector = RecordingProjector(id: "custom")
        #expect(projector.projectorId == "custom")
    }

    // MARK: - FilteringProjector

    @Test func filteringProjectorRecordsOnlyMatchingTypes() async throws {
        let projector = FilteringProjector(acceptedTypes: ["WidgetCreated"])
        let created = try RecordedEvent(event: TestWidgetEvent.created(name: "A"))
        let renamed = try RecordedEvent(event: TestWidgetEvent.renamed(newName: "B"))
        try await projector.apply(created)
        try await projector.apply(renamed)
        let events = await projector.appliedEvents
        #expect(events.count == 1)
        #expect(events[0].eventType == "WidgetCreated")
    }

    @Test func filteringProjectorHasDefaultId() async {
        let projector = FilteringProjector(acceptedTypes: [])
        #expect(projector.projectorId == "filtering")
    }

    // MARK: - FailingProjector

    @Test func failingProjectorThrowsOnMatchingType() async throws {
        let projector = FailingProjector(failOnType: "WidgetRenamed")
        let renamed = try RecordedEvent(event: TestWidgetEvent.renamed(newName: "X"))
        await #expect(throws: FailingProjectorError.self) {
            try await projector.apply(renamed)
        }
    }

    @Test func failingProjectorRecordsNonMatchingEvents() async throws {
        let projector = FailingProjector(failOnType: "WidgetRenamed")
        let created = try RecordedEvent(event: TestWidgetEvent.created(name: "Y"))
        try await projector.apply(created)
        let events = await projector.appliedEvents
        #expect(events.count == 1)
    }
}
```

Note: `TestWidgetEvent` is defined in `RecordedEventTestingTests.swift` in the same test target, so it's accessible here. If Swift test compilation scopes them separately, we may need to move the shared type. Check during Step 2.

**Step 2: Run tests to verify they fail**

Run: `swift test --filter SongbirdTestingTests`
Expected: Compilation error — `RecordingProjector`, `FilteringProjector`, `FailingProjector`, `FailingProjectorError` not found.

**Step 3: Write the implementation**

Create `Sources/SongbirdTesting/TestProjectors.swift`:

```swift
import Songbird

/// A projector that records every event it receives.
/// Useful for verifying that events flow through a pipeline.
public actor RecordingProjector: Projector {
    public let projectorId: String
    public private(set) var appliedEvents: [RecordedEvent] = []

    public init(id: String = "recording") {
        self.projectorId = id
    }

    public func apply(_ event: RecordedEvent) async throws {
        appliedEvents.append(event)
    }
}

/// A projector that records only events whose type is in the accepted set.
/// Useful for testing selective event handling.
public actor FilteringProjector: Projector {
    public let projectorId: String = "filtering"
    public let acceptedTypes: Set<String>
    public private(set) var appliedEvents: [RecordedEvent] = []

    public init(acceptedTypes: Set<String>) {
        self.acceptedTypes = acceptedTypes
    }

    public func apply(_ event: RecordedEvent) async throws {
        if acceptedTypes.contains(event.eventType) {
            appliedEvents.append(event)
        }
    }
}

/// Error thrown by `FailingProjector` when it encounters its target event type.
public struct FailingProjectorError: Error {
    public let eventType: String

    public init(eventType: String) {
        self.eventType = eventType
    }
}

/// A projector that throws on a specific event type, records all others.
/// Useful for testing error handling in projection pipelines.
public actor FailingProjector: Projector {
    public let projectorId: String = "failing"
    public let failOnType: String
    public private(set) var appliedEvents: [RecordedEvent] = []

    public init(failOnType: String) {
        self.failOnType = failOnType
    }

    public func apply(_ event: RecordedEvent) async throws {
        if event.eventType == failOnType {
            throw FailingProjectorError(eventType: event.eventType)
        }
        appliedEvents.append(event)
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter SongbirdTestingTests`
Expected: All tests pass (the 5 from Task 1 + 7 new = 12 total), zero warnings.

**Step 5: Commit**

```bash
git add Sources/SongbirdTesting/TestProjectors.swift Tests/SongbirdTestingTests/TestProjectorsTests.swift
git commit -m "Add RecordingProjector, FilteringProjector, and FailingProjector to SongbirdTesting"
```

---

### Task 3: TestAggregateHarness

**Files:**
- Create: `Sources/SongbirdTesting/TestAggregateHarness.swift`
- Create: `Tests/SongbirdTestingTests/TestAggregateHarnessTests.swift`

**Context:** The harness needs to import `Songbird` for `Aggregate`, `CommandHandler`, and `Event` protocols. It also needs the Swift Testing framework's `SourceLocation` for the `then` method. Since `SongbirdTesting` is a library (not a test target), it cannot import `Testing`. The `then` method should use a different approach — either return a Bool or simply let test callers assert with `#expect` directly. We'll provide `then` as a method that takes a `file` and `line` parameter (the standard Swift pattern for assertion helpers), or skip `then` entirely and let callers use `#expect(harness.state == expected)` directly. **Decision: skip `then` — the state is already public, so `#expect(harness.state == expected)` is clear and idiomatic.**

**Step 1: Write the failing tests**

Create `Tests/SongbirdTestingTests/TestAggregateHarnessTests.swift`:

```swift
import Testing

@testable import Songbird
@testable import SongbirdTesting

// Test aggregate for harness tests
enum HarnessCounter: Aggregate {
    struct State: Sendable, Equatable {
        var count: Int
    }

    enum Event: Songbird.Event {
        case incremented(by: Int)
        case decremented(by: Int)

        var eventType: String {
            switch self {
            case .incremented: "Incremented"
            case .decremented: "Decremented"
            }
        }
    }

    enum Failure: Error {
        case cannotDecrementBelowZero
    }

    static let category = "harness-counter"
    static let initialState = State(count: 0)

    static func apply(_ state: State, _ event: Event) -> State {
        switch event {
        case .incremented(let by): State(count: state.count + by)
        case .decremented(let by): State(count: state.count - by)
        }
    }
}

struct IncrementBy: Command {
    var commandType: String { "IncrementBy" }
    let amount: Int
}

struct DecrementBy: Command {
    var commandType: String { "DecrementBy" }
    let amount: Int
}

enum IncrementByHandler: CommandHandler {
    typealias Agg = HarnessCounter
    typealias Cmd = IncrementBy

    static func handle(
        _ command: IncrementBy,
        given state: HarnessCounter.State
    ) throws(HarnessCounter.Failure) -> [HarnessCounter.Event] {
        [.incremented(by: command.amount)]
    }
}

enum DecrementByHandler: CommandHandler {
    typealias Agg = HarnessCounter
    typealias Cmd = DecrementBy

    static func handle(
        _ command: DecrementBy,
        given state: HarnessCounter.State
    ) throws(HarnessCounter.Failure) -> [HarnessCounter.Event] {
        guard state.count >= command.amount else { throw .cannotDecrementBelowZero }
        return [.decremented(by: command.amount)]
    }
}

@Suite("TestAggregateHarness")
struct TestAggregateHarnessTests {

    @Test func startsWithInitialState() {
        let harness = TestAggregateHarness<HarnessCounter>()
        #expect(harness.state == HarnessCounter.State(count: 0))
        #expect(harness.version == -1)
        #expect(harness.appliedEvents.isEmpty)
    }

    @Test func startsWithCustomState() {
        let harness = TestAggregateHarness<HarnessCounter>(
            state: HarnessCounter.State(count: 10)
        )
        #expect(harness.state == HarnessCounter.State(count: 10))
    }

    @Test func givenFoldsEvents() {
        var harness = TestAggregateHarness<HarnessCounter>()
        harness.given(.incremented(by: 5), .incremented(by: 3))
        #expect(harness.state == HarnessCounter.State(count: 8))
        #expect(harness.version == 1)
        #expect(harness.appliedEvents.count == 2)
    }

    @Test func givenWithArrayFoldsEvents() {
        var harness = TestAggregateHarness<HarnessCounter>()
        harness.given([.incremented(by: 1), .decremented(by: 1), .incremented(by: 10)])
        #expect(harness.state == HarnessCounter.State(count: 10))
        #expect(harness.version == 2)
    }

    @Test func whenExecutesCommandHandler() throws {
        var harness = TestAggregateHarness<HarnessCounter>()
        let events = try harness.when(IncrementBy(amount: 7), using: IncrementByHandler.self)
        #expect(events == [.incremented(by: 7)])
        #expect(harness.state == HarnessCounter.State(count: 7))
        #expect(harness.version == 0)
    }

    @Test func whenThrowsOnFailedValidation() {
        var harness = TestAggregateHarness<HarnessCounter>()
        // count is 0, cannot decrement
        #expect(throws: HarnessCounter.Failure.self) {
            try harness.when(DecrementBy(amount: 1), using: DecrementByHandler.self)
        }
        // State should not change on failure
        #expect(harness.state == HarnessCounter.State(count: 0))
        #expect(harness.version == -1)
    }

    @Test func givenThenWhenWorkflow() throws {
        var harness = TestAggregateHarness<HarnessCounter>()
        harness.given(.incremented(by: 10))
        let events = try harness.when(DecrementBy(amount: 3), using: DecrementByHandler.self)
        #expect(events == [.decremented(by: 3)])
        #expect(harness.state == HarnessCounter.State(count: 7))
        #expect(harness.version == 1)
        #expect(harness.appliedEvents.count == 2)
    }

    @Test func versionIncrementsPerEvent() throws {
        var harness = TestAggregateHarness<HarnessCounter>()
        #expect(harness.version == -1)
        harness.given(.incremented(by: 1))
        #expect(harness.version == 0)
        harness.given(.incremented(by: 1))
        #expect(harness.version == 1)
        _ = try harness.when(IncrementBy(amount: 1), using: IncrementByHandler.self)
        #expect(harness.version == 2)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter SongbirdTestingTests`
Expected: Compilation error — `TestAggregateHarness` not found.

**Step 3: Write the implementation**

Create `Sources/SongbirdTesting/TestAggregateHarness.swift`:

```swift
import Songbird

/// A value-type harness for testing aggregates in isolation, without an event store.
///
/// Provides a `given`/`when` API:
/// - `given` feeds events to fold into the aggregate state
/// - `when` executes a command handler against the current state, folds resulting events
///
/// ```swift
/// var harness = TestAggregateHarness<MyAggregate>()
/// harness.given(.accountOpened(name: "Alice"))
/// let events = try harness.when(Deposit(amount: 100), using: DepositHandler.self)
/// #expect(harness.state == MyAggregate.State(balance: 100))
/// ```
public struct TestAggregateHarness<A: Aggregate> {
    /// The current aggregate state after all applied events.
    public private(set) var state: A.State

    /// The current version (number of events applied minus one, starting at -1).
    public private(set) var version: Int64

    /// All events that have been applied, from both `given` and `when` calls.
    public private(set) var appliedEvents: [A.Event]

    public init(state: A.State = A.initialState) {
        self.state = state
        self.version = -1
        self.appliedEvents = []
    }

    /// Feed events to fold into the aggregate state.
    public mutating func given(_ events: A.Event...) {
        given(events)
    }

    /// Feed an array of events to fold into the aggregate state.
    public mutating func given(_ events: [A.Event]) {
        for event in events {
            state = A.apply(state, event)
            version += 1
            appliedEvents.append(event)
        }
    }

    /// Execute a command handler against the current state.
    /// Returns the events produced by the handler. Those events are also folded into state.
    @discardableResult
    public mutating func when<H: CommandHandler>(
        _ command: H.Cmd,
        using handler: H.Type
    ) throws -> [A.Event] where H.Agg == A {
        let events = try handler.handle(command, given: state)
        for event in events {
            state = A.apply(state, event)
            version += 1
            appliedEvents.append(event)
        }
        return events
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter SongbirdTestingTests`
Expected: All tests pass (12 from Tasks 1-2 + 8 new = 20 total), zero warnings.

**Step 5: Commit**

```bash
git add Sources/SongbirdTesting/TestAggregateHarness.swift Tests/SongbirdTestingTests/TestAggregateHarnessTests.swift
git commit -m "Add TestAggregateHarness for isolated aggregate testing"
```

---

### Task 4: TestProjectorHarness

**Files:**
- Create: `Sources/SongbirdTesting/TestProjectorHarness.swift`
- Create: `Tests/SongbirdTestingTests/TestProjectorHarnessTests.swift`

**Step 1: Write the failing tests**

Create `Tests/SongbirdTestingTests/TestProjectorHarnessTests.swift`:

```swift
import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

@Suite("TestProjectorHarness")
struct TestProjectorHarnessTests {

    @Test func feedsTypedEventsToProjector() async throws {
        let projector = RecordingProjector()
        var harness = TestProjectorHarness(projector: projector)

        try await harness.given(TestWidgetEvent.created(name: "A"))
        try await harness.given(TestWidgetEvent.renamed(newName: "B"))

        let events = await projector.appliedEvents
        #expect(events.count == 2)
        #expect(events[0].eventType == "WidgetCreated")
        #expect(events[1].eventType == "WidgetRenamed")
    }

    @Test func incrementsGlobalPositionAutomatically() async throws {
        let projector = RecordingProjector()
        var harness = TestProjectorHarness(projector: projector)

        try await harness.given(TestWidgetEvent.created(name: "A"))
        try await harness.given(TestWidgetEvent.created(name: "B"))
        try await harness.given(TestWidgetEvent.created(name: "C"))

        let events = await projector.appliedEvents
        #expect(events[0].globalPosition == 0)
        #expect(events[1].globalPosition == 1)
        #expect(events[2].globalPosition == 2)
        #expect(harness.globalPosition == 3)
    }

    @Test func usesProvidedStreamName() async throws {
        let projector = RecordingProjector()
        var harness = TestProjectorHarness(projector: projector)

        let stream = StreamName(category: "widget", id: "w-1")
        try await harness.given(TestWidgetEvent.created(name: "A"), streamName: stream)

        let events = await projector.appliedEvents
        #expect(events[0].streamName == stream)
    }

    @Test func usesProvidedMetadata() async throws {
        let projector = RecordingProjector()
        var harness = TestProjectorHarness(projector: projector)

        let meta = EventMetadata(traceId: "trace-1")
        try await harness.given(TestWidgetEvent.created(name: "A"), metadata: meta)

        let events = await projector.appliedEvents
        #expect(events[0].metadata == meta)
    }

    @Test func roundTripsTypedEvents() async throws {
        let projector = RecordingProjector()
        var harness = TestProjectorHarness(projector: projector)

        try await harness.given(TestWidgetEvent.created(name: "Sprocket"))

        let events = await projector.appliedEvents
        let decoded = try events[0].decode(TestWidgetEvent.self).event
        #expect(decoded == TestWidgetEvent.created(name: "Sprocket"))
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter SongbirdTestingTests`
Expected: Compilation error — `TestProjectorHarness` not found.

**Step 3: Write the implementation**

Create `Sources/SongbirdTesting/TestProjectorHarness.swift`:

```swift
import Foundation
import Songbird

/// A harness that feeds typed events to a `Projector`, auto-encoding them
/// and auto-incrementing global positions.
///
/// ```swift
/// let projector = RecordingProjector()
/// var harness = TestProjectorHarness(projector: projector)
/// try await harness.given(OrderEvent.placed(id: "1"))
/// let events = await projector.appliedEvents
/// ```
public struct TestProjectorHarness<P: Projector> {
    /// The wrapped projector instance.
    public let projector: P

    /// The next global position to assign. Starts at 0, increments after each event.
    public private(set) var globalPosition: Int64

    public init(projector: P) {
        self.projector = projector
        self.globalPosition = 0
    }

    /// Feed a typed event to the projector.
    /// The event is JSON-encoded into a `RecordedEvent` with auto-incrementing global position.
    public mutating func given<E: Event>(
        _ event: E,
        streamName: StreamName = StreamName(category: "test", id: "1"),
        metadata: EventMetadata = EventMetadata()
    ) async throws {
        let recorded = try RecordedEvent(
            event: event,
            streamName: streamName,
            position: globalPosition,
            globalPosition: globalPosition,
            metadata: metadata
        )
        try await projector.apply(recorded)
        globalPosition += 1
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter SongbirdTestingTests`
Expected: All tests pass (20 from Tasks 1-3 + 5 new = 25 total), zero warnings.

**Step 5: Commit**

```bash
git add Sources/SongbirdTesting/TestProjectorHarness.swift Tests/SongbirdTestingTests/TestProjectorHarnessTests.swift
git commit -m "Add TestProjectorHarness for feeding typed events to projectors"
```

---

### Task 5: TestProcessManagerHarness

**Files:**
- Create: `Sources/SongbirdTesting/TestProcessManagerHarness.swift`
- Create: `Tests/SongbirdTestingTests/TestProcessManagerHarnessTests.swift`

**Context:** This harness routes events through `AnyReaction.tryRoute` and `AnyReaction.handle`, matching the logic in `ProcessManagerRunner` (`Sources/Songbird/ProcessManagerRunner.swift`). It is a value type (no async needed — reactions are synchronous).

**Step 1: Write the failing tests**

Create `Tests/SongbirdTestingTests/TestProcessManagerHarnessTests.swift`:

We need a process manager to test with. Define a minimal one in this file:

```swift
import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

// MARK: - Test Domain

enum HarnessOrderEvent: Event {
    case placed(orderId: String, total: Int)

    var eventType: String {
        switch self {
        case .placed: "HarnessOrderPlaced"
        }
    }
}

enum HarnessPaymentEvent: Event {
    case charged(orderId: String)

    var eventType: String {
        switch self {
        case .charged: "HarnessPaymentCharged"
        }
    }
}

enum HarnessFulfillmentEvent: Event {
    case paymentRequested(orderId: String, amount: Int)
    case shipmentRequested(orderId: String)

    var eventType: String {
        switch self {
        case .paymentRequested: "HarnessPaymentRequested"
        case .shipmentRequested: "HarnessShipmentRequested"
        }
    }
}

enum HarnessOnOrderPlaced: EventReaction {
    typealias PMState = HarnessFulfillmentPM.State
    typealias Input = HarnessOrderEvent

    static let eventTypes = ["HarnessOrderPlaced"]

    static func route(_ event: HarnessOrderEvent) -> String? {
        switch event { case .placed(let orderId, _): orderId }
    }

    static func apply(_ state: PMState, _ event: HarnessOrderEvent) -> PMState {
        switch event { case .placed(_, let total): .init(total: total, paid: false) }
    }

    static func react(_ state: PMState, _ event: HarnessOrderEvent) -> [any Event] {
        switch event {
        case .placed(let orderId, let total):
            [HarnessFulfillmentEvent.paymentRequested(orderId: orderId, amount: total)]
        }
    }
}

enum HarnessOnPaymentCharged: EventReaction {
    typealias PMState = HarnessFulfillmentPM.State
    typealias Input = HarnessPaymentEvent

    static let eventTypes = ["HarnessPaymentCharged"]

    static func route(_ event: HarnessPaymentEvent) -> String? {
        switch event { case .charged(let orderId): orderId }
    }

    static func apply(_ state: PMState, _ event: HarnessPaymentEvent) -> PMState {
        switch event { case .charged: .init(total: state.total, paid: true) }
    }

    static func react(_ state: PMState, _ event: HarnessPaymentEvent) -> [any Event] {
        switch event {
        case .charged(let orderId):
            [HarnessFulfillmentEvent.shipmentRequested(orderId: orderId)]
        }
    }
}

enum HarnessFulfillmentPM: ProcessManager {
    struct State: Sendable, Equatable {
        var total: Int
        var paid: Bool
    }

    static let processId = "harness-fulfillment"
    static let initialState = State(total: 0, paid: false)

    static let reactions: [AnyReaction<State>] = [
        reaction(for: HarnessOnOrderPlaced.self, categories: ["harness-order"]),
        reaction(for: HarnessOnPaymentCharged.self, categories: ["harness-payment"]),
    ]
}

// MARK: - Tests

@Suite("TestProcessManagerHarness")
struct TestProcessManagerHarnessTests {

    @Test func startsEmpty() {
        let harness = TestProcessManagerHarness<HarnessFulfillmentPM>()
        #expect(harness.states.isEmpty)
        #expect(harness.output.isEmpty)
    }

    @Test func processesTypedEventAndUpdatesState() throws {
        var harness = TestProcessManagerHarness<HarnessFulfillmentPM>()
        try harness.given(
            HarnessOrderEvent.placed(orderId: "order-1", total: 100),
            streamName: StreamName(category: "harness-order", id: "order-1")
        )
        #expect(harness.state(for: "order-1") == HarnessFulfillmentPM.State(total: 100, paid: false))
    }

    @Test func collectsOutputEvents() throws {
        var harness = TestProcessManagerHarness<HarnessFulfillmentPM>()
        try harness.given(
            HarnessOrderEvent.placed(orderId: "order-1", total: 200),
            streamName: StreamName(category: "harness-order", id: "order-1")
        )
        #expect(harness.output.count == 1)
        let first = harness.output[0] as? HarnessFulfillmentEvent
        #expect(first == HarnessFulfillmentEvent.paymentRequested(orderId: "order-1", amount: 200))
    }

    @Test func tracksPerEntityStateIsolation() throws {
        var harness = TestProcessManagerHarness<HarnessFulfillmentPM>()
        try harness.given(
            HarnessOrderEvent.placed(orderId: "A", total: 50),
            streamName: StreamName(category: "harness-order", id: "A")
        )
        try harness.given(
            HarnessOrderEvent.placed(orderId: "B", total: 75),
            streamName: StreamName(category: "harness-order", id: "B")
        )
        #expect(harness.state(for: "A") == HarnessFulfillmentPM.State(total: 50, paid: false))
        #expect(harness.state(for: "B") == HarnessFulfillmentPM.State(total: 75, paid: false))
    }

    @Test func multiStepWorkflow() throws {
        var harness = TestProcessManagerHarness<HarnessFulfillmentPM>()
        try harness.given(
            HarnessOrderEvent.placed(orderId: "order-1", total: 300),
            streamName: StreamName(category: "harness-order", id: "order-1")
        )
        try harness.given(
            HarnessPaymentEvent.charged(orderId: "order-1"),
            streamName: StreamName(category: "harness-payment", id: "order-1")
        )
        #expect(harness.state(for: "order-1") == HarnessFulfillmentPM.State(total: 300, paid: true))
        #expect(harness.output.count == 2)
        let second = harness.output[1] as? HarnessFulfillmentEvent
        #expect(second == HarnessFulfillmentEvent.shipmentRequested(orderId: "order-1"))
    }

    @Test func returnsInitialStateForUnknownEntity() {
        let harness = TestProcessManagerHarness<HarnessFulfillmentPM>()
        #expect(harness.state(for: "nonexistent") == HarnessFulfillmentPM.initialState)
    }

    @Test func skipsEventsWithNoMatchingReaction() throws {
        var harness = TestProcessManagerHarness<HarnessFulfillmentPM>()
        // Feed an event with an event type that no reaction handles
        try harness.given(
            TestWidgetEvent.created(name: "irrelevant"),
            streamName: StreamName(category: "harness-order", id: "x")
        )
        #expect(harness.states.isEmpty)
        #expect(harness.output.isEmpty)
    }

    @Test func acceptsRawRecordedEvent() throws {
        var harness = TestProcessManagerHarness<HarnessFulfillmentPM>()
        let recorded = try RecordedEvent(
            event: HarnessOrderEvent.placed(orderId: "order-1", total: 150),
            streamName: StreamName(category: "harness-order", id: "order-1")
        )
        try harness.given(recorded)
        #expect(harness.state(for: "order-1") == HarnessFulfillmentPM.State(total: 150, paid: false))
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter SongbirdTestingTests`
Expected: Compilation error — `TestProcessManagerHarness` not found.

**Step 3: Write the implementation**

Create `Sources/SongbirdTesting/TestProcessManagerHarness.swift`:

```swift
import Foundation
import Songbird

/// A value-type harness for testing process managers in isolation, without an event store or runner.
///
/// Routes events through the process manager's `AnyReaction` registrations and tracks
/// per-entity state and accumulated output events.
///
/// ```swift
/// var harness = TestProcessManagerHarness<FulfillmentPM>()
/// try harness.given(OrderEvent.placed(orderId: "1", total: 100),
///                   streamName: StreamName(category: "order", id: "1"))
/// #expect(harness.state(for: "1") == FulfillmentPM.State(total: 100, paid: false))
/// #expect(harness.output.count == 1)
/// ```
public struct TestProcessManagerHarness<PM: ProcessManager> {
    /// Per-entity state, keyed by the route (entity instance ID) from reactions.
    public private(set) var states: [String: PM.State]

    /// All output events accumulated across all `given` calls.
    public private(set) var output: [any Event]

    public init() {
        self.states = [:]
        self.output = []
    }

    /// Feed a raw `RecordedEvent` through the process manager's reactions.
    /// Matches the first reaction whose `tryRoute` returns a non-nil route,
    /// then calls `handle` with the current per-entity state.
    public mutating func given(_ event: RecordedEvent) throws {
        for reaction in PM.reactions {
            guard let route = try? reaction.tryRoute(event) else { continue }
            guard let route else { continue }

            let currentState = states[route] ?? PM.initialState
            let (newState, newOutput) = try reaction.handle(currentState, event)
            states[route] = newState
            output.append(contentsOf: newOutput)
            return
        }
        // No matching reaction — silently skip (matches ProcessManagerRunner behavior)
    }

    /// Feed a typed event through the process manager's reactions.
    /// The event is auto-encoded to a `RecordedEvent` via the convenience initializer.
    public mutating func given<E: Event>(
        _ event: E,
        streamName: StreamName,
        metadata: EventMetadata = EventMetadata()
    ) throws {
        let recorded = try RecordedEvent(
            event: event,
            streamName: streamName,
            metadata: metadata
        )
        try given(recorded)
    }

    /// Get the per-entity state for a given instance ID.
    /// Returns `PM.initialState` if no events have been routed to this entity.
    public func state(for instanceId: String) -> PM.State {
        states[instanceId] ?? PM.initialState
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter SongbirdTestingTests`
Expected: All tests pass (25 from Tasks 1-4 + 8 new = 33 total), zero warnings.

**Step 5: Commit**

```bash
git add Sources/SongbirdTesting/TestProcessManagerHarness.swift Tests/SongbirdTestingTests/TestProcessManagerHarnessTests.swift
git commit -m "Add TestProcessManagerHarness for isolated process manager testing"
```

---

### Task 6: Refactor ProjectionPipelineTests to Use SongbirdTesting Utilities

**Files:**
- Modify: `Tests/SongbirdTests/ProjectionPipelineTests.swift`

**Context:** Currently `ProjectionPipelineTests.swift` defines its own `RecordingProjector`, `FilteringProjector`, `FailingProjector`, `ProjectorTestError`, and `makeRecordedEvent()` helper (lines 1–76). After this task, those are replaced with imports from `SongbirdTesting`.

**Step 1: Remove the local definitions**

In `Tests/SongbirdTests/ProjectionPipelineTests.swift`:

1. Remove the `RecordingProjector` actor (lines 8–19)
2. Remove the `FilteringProjector` actor (lines 22–36)
3. Remove the `FailingProjector` actor (lines 39–54)
4. Remove the `ProjectorTestError` enum (lines 56–58)
5. Remove the `makeRecordedEvent` function (lines 61–76)
6. Add `@testable import SongbirdTesting` if not already present

Replace all calls to `makeRecordedEvent(globalPosition:eventType:streamName:)` with the new `RecordedEvent` constructor. The old helper created events with `Data("{}".utf8)` — these tests only check event flow, not deserialization, so we can use a minimal event type.

The old `ProjectorTestError.intentionalFailure` is now `FailingProjectorError`. Update any `throws: ProjectorTestError.self` expectations to use `FailingProjectorError.self` if present (there are none — the tests don't directly assert the error type from the projector).

Since `makeRecordedEvent` used raw `Data("{}".utf8)` and tests never decode the event payload, we need a lightweight approach. Create a minimal event type in the test file:

```swift
private enum PipelineTestEvent: Event {
    case test

    var eventType: String { "TestEvent" }
}
```

Then replace `makeRecordedEvent(globalPosition: N)` with `try RecordedEvent(event: PipelineTestEvent.test, globalPosition: N)` and for calls with a custom `eventType`, use a more specific event enum or directly construct `RecordedEvent` with the raw data approach.

**Actually — simpler approach:** The tests use `makeRecordedEvent(globalPosition:eventType:streamName:)` with different `eventType` strings like `"Deposited"`, `"Withdrawn"`, `"Good"`, `"Bad"`. These strings matter for the `FilteringProjector` and `FailingProjector` tests. The simplest approach is to keep a small `makeRecordedEvent` helper that uses `RecordedEvent`'s raw initializer (since the event data content doesn't matter for pipeline tests), or define trivial events. Since the goal is to remove boilerplate and use the new utilities, let's define a small helper event type:

```swift
/// Minimal event whose `eventType` can be customized for pipeline tests.
private struct PipelineTestEvent: Event {
    let eventType: String
    var messageType: String { eventType }

    init(_ type: String = "TestEvent") {
        self.eventType = type
    }
}
```

Wait — `Event` requires `Codable` (via `Message`). And `eventType` is an instance property. Let me check — the `Event` protocol requires `var eventType: String { get }`. The `Message` protocol requires `Sendable, Codable, Equatable`. So a struct with a stored `eventType` would work as long as it's Codable.

But `RecordedEvent(event:)` would encode the struct (including the `eventType` field) as the data. That's fine — the pipeline tests never decode the data.

Then replace `makeRecordedEvent(globalPosition: 0, eventType: "Deposited")` with `try RecordedEvent(event: PipelineTestEvent("Deposited"), globalPosition: 0)`.

**Step 1: Modify the file**

Replace lines 1–76 of `ProjectionPipelineTests.swift` with:

```swift
import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

/// Minimal event for pipeline tests. The `eventType` can be customized to test
/// type-based filtering without needing a full domain event enum.
private struct PipelineTestEvent: Event {
    let eventType: String

    init(_ type: String = "TestEvent") {
        self.eventType = type
    }
}
```

Then replace every `makeRecordedEvent(globalPosition: N)` with `try RecordedEvent(event: PipelineTestEvent(), globalPosition: N)`.

Replace `makeRecordedEvent(globalPosition: N, eventType: "Foo")` with `try RecordedEvent(event: PipelineTestEvent("Foo"), globalPosition: N)`.

Replace `makeRecordedEvent(globalPosition: N, eventType: "Foo", streamName: bar)` with `try RecordedEvent(event: PipelineTestEvent("Foo"), streamName: bar, globalPosition: N)`.

Mark all test methods that now call the throwing `RecordedEvent(event:)` as `throws` if not already.

**Step 2: Run the full test suite**

Run: `swift test`
Expected: All existing tests pass, zero warnings. The ProjectionPipelineTests should behave identically.

**Step 3: Commit**

```bash
git add Tests/SongbirdTests/ProjectionPipelineTests.swift
git commit -m "Refactor ProjectionPipelineTests to use SongbirdTesting utilities"
```

---

### Task 7: Refactor Remaining Tests to Use RecordedEvent Convenience Initializer

**Files:**
- Modify: `Tests/SongbirdTests/ProcessManagerTests.swift`
- Modify: `Tests/SongbirdTests/GatewayTests.swift`

**Context:** These files construct `RecordedEvent` manually with `JSONEncoder().encode(event)` and `Data("{}".utf8)`. Replace with the convenience initializer.

**Step 1: Refactor ProcessManagerTests.swift**

In `ProcessManagerTests.swift`, find all patterns like:

```swift
let data = try JSONEncoder().encode(event)
let recorded = RecordedEvent(
    id: UUID(),
    streamName: ...,
    position: 0,
    globalPosition: 0,
    eventType: "...",
    data: data,
    metadata: EventMetadata(),
    timestamp: Date()
)
```

Replace with:

```swift
let recorded = try RecordedEvent(
    event: event,
    streamName: ...,
    globalPosition: 0
)
```

This affects the tests at approximately lines 161–173, 179–191, 199–211, 223–235, 247–259.

Add `@testable import SongbirdTesting` to the imports.

**Step 2: Refactor GatewayTests.swift**

In `GatewayTests.swift`, replace the manual `RecordedEvent` construction:

```swift
let recorded = RecordedEvent(
    id: UUID(),
    streamName: StreamName(category: "test", id: "1"),
    position: 0,
    globalPosition: 0,
    eventType: "TestEvent",
    data: Data("{}".utf8),
    metadata: EventMetadata(),
    timestamp: Date()
)
```

With a minimal event approach. Define a simple event type in the file:

```swift
private struct GatewayTestEvent: Event {
    let eventType: String = "TestEvent"
}
```

Then use: `let recorded = try RecordedEvent(event: GatewayTestEvent())`.

Add `@testable import SongbirdTesting` to the imports.

**Step 3: Run the full test suite**

Run: `swift test`
Expected: All tests pass, zero warnings.

**Step 4: Commit**

```bash
git add Tests/SongbirdTests/ProcessManagerTests.swift Tests/SongbirdTests/GatewayTests.swift
git commit -m "Refactor ProcessManager and Gateway tests to use RecordedEvent convenience initializer"
```

---

### Task 8: Final Review and Changelog

**Files:**
- Create: `changelog/0009-testing-utilities.md`

**Step 1: Run full test suite**

Run: `swift test`
Expected: All tests pass, zero warnings, zero errors.

**Step 2: Verify clean build**

Run: `swift build 2>&1`
Expected: Build succeeded, zero warnings.

**Step 3: Review SongbirdTesting module files**

Verify the following files exist and have correct public APIs:

- `Sources/SongbirdTesting/RecordedEvent+Testing.swift`
- `Sources/SongbirdTesting/TestProjectors.swift`
- `Sources/SongbirdTesting/TestAggregateHarness.swift`
- `Sources/SongbirdTesting/TestProjectorHarness.swift`
- `Sources/SongbirdTesting/TestProcessManagerHarness.swift`
- `Sources/SongbirdTesting/InMemoryEventStore.swift` (existing)
- `Sources/SongbirdTesting/InMemoryPositionStore.swift` (existing)

**Step 4: Write changelog entry**

Create `changelog/0009-testing-utilities.md`:

```markdown
# 0009: Testing Utilities

Expanded the `SongbirdTesting` module with reusable test utilities that eliminate boilerplate across Songbird test files.

## New Components

### RecordedEvent Convenience Initializer
- `RecordedEvent.init(event:id:streamName:position:globalPosition:metadata:timestamp:)` — accepts any typed `Event`, JSON-encodes it automatically, and provides sensible defaults for all metadata fields.

### Test Projectors (promoted from ProjectionPipelineTests)
- **RecordingProjector** — records every event it receives
- **FilteringProjector** — records only events whose type is in the accepted set
- **FailingProjector** — throws `FailingProjectorError` on a specific event type, records all others

### TestAggregateHarness
- Value type for testing aggregates in isolation without an event store
- `given(events...)` folds events into state
- `when(command, using: handler)` executes a command handler and folds resulting events
- Tracks `state`, `version`, and `appliedEvents`

### TestProjectorHarness
- Wraps any `Projector` and feeds it typed events (auto-encoded)
- Auto-increments global positions

### TestProcessManagerHarness
- Value type for testing process managers in isolation without an event store or runner
- Routes events through `AnyReaction.tryRoute` then `AnyReaction.handle`
- Tracks per-entity `states` and accumulated `output` events

## Refactoring
- Removed duplicated projector definitions and `makeRecordedEvent()` helper from `ProjectionPipelineTests.swift`
- Replaced manual `RecordedEvent` construction with convenience initializer in `ProcessManagerTests.swift` and `GatewayTests.swift`
```

**Step 5: Commit**

```bash
git add changelog/0009-testing-utilities.md
git commit -m "Add testing utilities changelog entry"
```
