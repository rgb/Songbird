# Phase 1: Core Domain Types — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement all core protocols and types for the Songbird event sourcing framework.

**Architecture:** Protocol-based types in a single `Songbird` module with zero external dependencies beyond Foundation. Each type gets its own source file and corresponding test file. TDD throughout — write failing tests first, then implement.

**Tech Stack:** Swift 6.2+, macOS 14+, Swift Testing framework (`@Test`, `#expect`)

**Test command:** `swift test 2>&1`

**Build command:** `swift build 2>&1`

---

### Task 1: StreamName

**Files:**
- Create: `Sources/Songbird/StreamName.swift`
- Create: `Tests/SongbirdTests/StreamNameTests.swift`
- Delete: `Sources/Songbird/Songbird.swift` (placeholder, no longer needed)

**Step 1: Write the failing tests**

Create `Tests/SongbirdTests/StreamNameTests.swift`:

```swift
import Testing

@testable import Songbird

@Suite("StreamName")
struct StreamNameTests {
    @Test func entityStreamHasCategoryAndId() {
        let stream = StreamName(category: "order", id: "abc-123")
        #expect(stream.category == "order")
        #expect(stream.id == "abc-123")
        #expect(stream.isCategory == false)
    }

    @Test func categoryStreamHasNilId() {
        let stream = StreamName(category: "order")
        #expect(stream.category == "order")
        #expect(stream.id == nil)
        #expect(stream.isCategory == true)
    }

    @Test func entityStreamDescription() {
        let stream = StreamName(category: "order", id: "abc-123")
        #expect(stream.description == "order-abc-123")
    }

    @Test func categoryStreamDescription() {
        let stream = StreamName(category: "order")
        #expect(stream.description == "order")
    }

    @Test func equalityByValue() {
        let a = StreamName(category: "order", id: "123")
        let b = StreamName(category: "order", id: "123")
        let c = StreamName(category: "order", id: "456")
        #expect(a == b)
        #expect(a != c)
    }

    @Test func hashableForDictionaryKeys() {
        let stream = StreamName(category: "order", id: "123")
        var dict: [StreamName: Int] = [:]
        dict[stream] = 42
        #expect(dict[StreamName(category: "order", id: "123")] == 42)
    }

    @Test func codableRoundTrip() throws {
        let stream = StreamName(category: "order", id: "abc-123")
        let data = try JSONEncoder().encode(stream)
        let decoded = try JSONDecoder().decode(StreamName.self, from: data)
        #expect(stream == decoded)
    }

    @Test func codableCategoryStreamRoundTrip() throws {
        let stream = StreamName(category: "order")
        let data = try JSONEncoder().encode(stream)
        let decoded = try JSONDecoder().decode(StreamName.self, from: data)
        #expect(stream == decoded)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test 2>&1`
Expected: Compilation errors — `StreamName` not defined.

**Step 3: Implement StreamName**

Delete `Sources/Songbird/Songbird.swift`. Create `Sources/Songbird/StreamName.swift`:

```swift
import Foundation

public struct StreamName: Sendable, Hashable, Codable, CustomStringConvertible {
    public let category: String
    public let id: String?

    public init(category: String, id: String? = nil) {
        self.category = category
        self.id = id
    }

    public var isCategory: Bool { id == nil }

    public var description: String {
        if let id { "\(category)-\(id)" } else { category }
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test 2>&1`
Expected: All StreamName tests PASS, zero warnings.

**Step 5: Commit**

```
git add Sources/Songbird/StreamName.swift Tests/SongbirdTests/StreamNameTests.swift
git rm Sources/Songbird/Songbird.swift
git commit -m "Add StreamName type

Structured stream identity with category + optional entity ID.
Sendable, Hashable, Codable, CustomStringConvertible."
```

---

### Task 2: Event protocol, EventMetadata, RecordedEvent, EventEnvelope

**Files:**
- Create: `Sources/Songbird/Event.swift`
- Create: `Tests/SongbirdTests/EventTests.swift`
- Modify: `Tests/SongbirdTests/SongbirdTests.swift` (delete placeholder test)

**Step 1: Write the failing tests**

Create `Tests/SongbirdTests/EventTests.swift`:

```swift
import Foundation
import Testing

@testable import Songbird

// Test event type
struct CounterIncremented: Event {
    static let eventType = "CounterIncremented"
    let amount: Int
}

struct CounterDecremented: Event {
    static let eventType = "CounterDecremented"
    let amount: Int
}

@Suite("Event")
struct EventTests {
    @Test func eventTypeIsAccessible() {
        #expect(CounterIncremented.eventType == "CounterIncremented")
        #expect(CounterDecremented.eventType == "CounterDecremented")
    }

    @Test func eventIsCodable() throws {
        let event = CounterIncremented(amount: 5)
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(CounterIncremented.self, from: data)
        #expect(event == decoded)
    }

    @Test func eventIsEquatable() {
        let a = CounterIncremented(amount: 5)
        let b = CounterIncremented(amount: 5)
        let c = CounterIncremented(amount: 10)
        #expect(a == b)
        #expect(a != c)
    }
}

@Suite("EventMetadata")
struct EventMetadataTests {
    @Test func defaultsToNil() {
        let meta = EventMetadata()
        #expect(meta.traceId == nil)
        #expect(meta.causationId == nil)
        #expect(meta.correlationId == nil)
        #expect(meta.userId == nil)
    }

    @Test func initWithValues() {
        let meta = EventMetadata(
            traceId: "trace-1",
            causationId: "cause-1",
            correlationId: "corr-1",
            userId: "user-1"
        )
        #expect(meta.traceId == "trace-1")
        #expect(meta.causationId == "cause-1")
        #expect(meta.correlationId == "corr-1")
        #expect(meta.userId == "user-1")
    }

    @Test func codableRoundTrip() throws {
        let meta = EventMetadata(traceId: "trace-1", userId: "user-1")
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(EventMetadata.self, from: data)
        #expect(meta == decoded)
    }
}

@Suite("RecordedEvent")
struct RecordedEventTests {
    @Test func decodesToTypedEnvelope() throws {
        let event = CounterIncremented(amount: 5)
        let data = try JSONEncoder().encode(event)
        let stream = StreamName(category: "counter", id: "abc")
        let now = Date()
        let id = UUID()

        let recorded = RecordedEvent(
            id: id,
            streamName: stream,
            position: 0,
            globalPosition: 42,
            eventType: CounterIncremented.eventType,
            data: data,
            metadata: EventMetadata(traceId: "t1"),
            timestamp: now
        )

        let envelope = try recorded.decode(CounterIncremented.self)
        #expect(envelope.id == id)
        #expect(envelope.streamName == stream)
        #expect(envelope.position == 0)
        #expect(envelope.globalPosition == 42)
        #expect(envelope.event == event)
        #expect(envelope.metadata.traceId == "t1")
        #expect(envelope.timestamp == now)
    }

    @Test func decodeThrowsForWrongType() throws {
        let event = CounterIncremented(amount: 5)
        let data = try JSONEncoder().encode(event)

        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "counter", id: "abc"),
            position: 0,
            globalPosition: 0,
            eventType: CounterIncremented.eventType,
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        #expect(throws: (any Error).self) {
            _ = try recorded.decode(CounterDecremented.self)
        }
    }
}

@Suite("EventEnvelope")
struct EventEnvelopeTests {
    @Test func holdsTypedEvent() {
        let event = CounterIncremented(amount: 7)
        let envelope = EventEnvelope(
            id: UUID(),
            streamName: StreamName(category: "counter", id: "x"),
            position: 0,
            globalPosition: 1,
            event: event,
            metadata: EventMetadata(),
            timestamp: Date()
        )
        #expect(envelope.event.amount == 7)
    }
}
```

Delete the placeholder test in `Tests/SongbirdTests/SongbirdTests.swift` (remove the file).

**Step 2: Run tests to verify they fail**

Run: `swift test 2>&1`
Expected: Compilation errors — `Event`, `EventMetadata`, `RecordedEvent`, `EventEnvelope` not defined.

**Step 3: Implement Event.swift**

Create `Sources/Songbird/Event.swift`:

```swift
import Foundation

public protocol Event: Sendable, Codable, Equatable {
    static var eventType: String { get }
}

public struct EventMetadata: Sendable, Codable, Equatable {
    public var traceId: String?
    public var causationId: String?
    public var correlationId: String?
    public var userId: String?

    public init(
        traceId: String? = nil,
        causationId: String? = nil,
        correlationId: String? = nil,
        userId: String? = nil
    ) {
        self.traceId = traceId
        self.causationId = causationId
        self.correlationId = correlationId
        self.userId = userId
    }
}

public struct RecordedEvent: Sendable {
    public let id: UUID
    public let streamName: StreamName
    public let position: Int64
    public let globalPosition: Int64
    public let eventType: String
    public let data: Data
    public let metadata: EventMetadata
    public let timestamp: Date

    public init(
        id: UUID,
        streamName: StreamName,
        position: Int64,
        globalPosition: Int64,
        eventType: String,
        data: Data,
        metadata: EventMetadata,
        timestamp: Date
    ) {
        self.id = id
        self.streamName = streamName
        self.position = position
        self.globalPosition = globalPosition
        self.eventType = eventType
        self.data = data
        self.metadata = metadata
        self.timestamp = timestamp
    }

    public func decode<E: Event>(_ type: E.Type) throws -> EventEnvelope<E> {
        let event = try JSONDecoder().decode(E.self, from: data)
        return EventEnvelope(
            id: id,
            streamName: streamName,
            position: position,
            globalPosition: globalPosition,
            event: event,
            metadata: metadata,
            timestamp: timestamp
        )
    }
}

public struct EventEnvelope<E: Event>: Sendable {
    public let id: UUID
    public let streamName: StreamName
    public let position: Int64
    public let globalPosition: Int64
    public let event: E
    public let metadata: EventMetadata
    public let timestamp: Date

    public init(
        id: UUID,
        streamName: StreamName,
        position: Int64,
        globalPosition: Int64,
        event: E,
        metadata: EventMetadata,
        timestamp: Date
    ) {
        self.id = id
        self.streamName = streamName
        self.position = position
        self.globalPosition = globalPosition
        self.event = event
        self.metadata = metadata
        self.timestamp = timestamp
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test 2>&1`
Expected: All Event, EventMetadata, RecordedEvent, EventEnvelope tests PASS, zero warnings.

**Step 5: Commit**

```
git rm Tests/SongbirdTests/SongbirdTests.swift
git add Sources/Songbird/Event.swift Tests/SongbirdTests/EventTests.swift
git commit -m "Add Event protocol, EventMetadata, RecordedEvent, EventEnvelope

Event protocol: Sendable + Codable + Equatable with eventType discriminator.
RecordedEvent: raw store output with decode() to typed EventEnvelope.
EventMetadata: traceId, causationId, correlationId, userId."
```

---

### Task 3: Command protocol

**Files:**
- Create: `Sources/Songbird/Command.swift`
- Create: `Tests/SongbirdTests/CommandTests.swift`

**Step 1: Write the failing test**

Create `Tests/SongbirdTests/CommandTests.swift`:

```swift
import Testing

@testable import Songbird

struct IncrementCounter: Command {
    static let commandType = "IncrementCounter"
    let amount: Int
}

@Suite("Command")
struct CommandTests {
    @Test func commandTypeIsAccessible() {
        #expect(IncrementCounter.commandType == "IncrementCounter")
    }

    @Test func commandIsSendable() {
        let cmd = IncrementCounter(amount: 5)
        // Compile-time check: can be passed across concurrency boundaries
        Task { @Sendable in
            _ = cmd.amount
        }
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test 2>&1`
Expected: Compilation error — `Command` not defined.

**Step 3: Implement Command.swift**

Create `Sources/Songbird/Command.swift`:

```swift
public protocol Command: Sendable {
    static var commandType: String { get }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test 2>&1`
Expected: All Command tests PASS, zero warnings.

**Step 5: Commit**

```
git add Sources/Songbird/Command.swift Tests/SongbirdTests/CommandTests.swift
git commit -m "Add Command protocol

Sendable protocol with commandType discriminator string."
```

---

### Task 4: Aggregate protocol

**Files:**
- Create: `Sources/Songbird/Aggregate.swift`
- Create: `Tests/SongbirdTests/AggregateTests.swift`

**Step 1: Write the failing tests**

Create `Tests/SongbirdTests/AggregateTests.swift`:

```swift
import Testing

@testable import Songbird

// Test aggregate: a simple counter
enum CounterAggregate: Aggregate {
    struct State: Sendable, Equatable {
        var count: Int
    }

    enum Event: String, Songbird.Event, CaseIterable {
        case incremented = "CounterIncremented"
        case decremented = "CounterDecremented"

        static var eventType: String { "CounterEvent" }
        // Note: for real use, each event would be its own type.
        // This enum style works for testing the Aggregate protocol.
    }

    enum Failure: Error {
        case cannotDecrementBelowZero
    }

    static let category = "counter"
    static let initialState = State(count: 0)

    static func apply(_ state: State, _ event: Event) -> State {
        switch event {
        case .incremented: State(count: state.count + 1)
        case .decremented: State(count: state.count - 1)
        }
    }
}

@Suite("Aggregate")
struct AggregateTests {
    @Test func initialState() {
        #expect(CounterAggregate.initialState == CounterAggregate.State(count: 0))
    }

    @Test func applyIsPure() {
        let state = CounterAggregate.State(count: 5)
        let newState = CounterAggregate.apply(state, .incremented)
        #expect(newState == CounterAggregate.State(count: 6))
        // Original state unchanged (value type)
        #expect(state == CounterAggregate.State(count: 5))
    }

    @Test func foldEventsFromInitial() {
        let events: [CounterAggregate.Event] = [
            .incremented, .incremented, .incremented, .decremented,
        ]
        let state = events.reduce(CounterAggregate.initialState, CounterAggregate.apply)
        #expect(state == CounterAggregate.State(count: 2))
    }

    @Test func categoryProvidesStreamPrefix() {
        #expect(CounterAggregate.category == "counter")
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test 2>&1`
Expected: Compilation error — `Aggregate` not defined.

**Step 3: Implement Aggregate.swift**

Create `Sources/Songbird/Aggregate.swift`:

```swift
public protocol Aggregate {
    associatedtype State: Sendable, Equatable
    associatedtype Event: Songbird.Event
    associatedtype Failure: Error

    static var category: String { get }
    static var initialState: State { get }
    static func apply(_ state: State, _ event: Event) -> State
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test 2>&1`
Expected: All Aggregate tests PASS, zero warnings.

**Step 5: Commit**

```
git add Sources/Songbird/Aggregate.swift Tests/SongbirdTests/AggregateTests.swift
git commit -m "Add Aggregate protocol

Static apply function enforces purity: (State, Event) -> State.
Category string for stream naming. Typed Failure for command validation."
```

---

### Task 5: Projector protocol

**Files:**
- Create: `Sources/Songbird/Projector.swift`
- Create: `Tests/SongbirdTests/ProjectorTests.swift`

**Step 1: Write the failing tests**

Create `Tests/SongbirdTests/ProjectorTests.swift`:

```swift
import Foundation
import Testing

@testable import Songbird

// Test projector: counts events
final class EventCounterProjector: Projector, @unchecked Sendable {
    let projectorId = "event-counter"
    private(set) var count = 0

    func apply(_ event: RecordedEvent) async throws {
        count += 1
    }
}

@Suite("Projector")
struct ProjectorTests {
    @Test func projectorHasId() {
        let projector = EventCounterProjector()
        #expect(projector.projectorId == "event-counter")
    }

    @Test func projectorAppliesEvents() async throws {
        let projector = EventCounterProjector()
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
        try await projector.apply(recorded)
        try await projector.apply(recorded)
        #expect(projector.count == 2)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test 2>&1`
Expected: Compilation error — `Projector` not defined.

**Step 3: Implement Projector.swift**

Create `Sources/Songbird/Projector.swift`:

```swift
public protocol Projector: Sendable {
    var projectorId: String { get }
    func apply(_ event: RecordedEvent) async throws
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test 2>&1`
Expected: All Projector tests PASS, zero warnings.

**Step 5: Commit**

```
git add Sources/Songbird/Projector.swift Tests/SongbirdTests/ProjectorTests.swift
git commit -m "Add Projector protocol

Receives RecordedEvent (type-erased) for category stream processing.
Projector implementations decode only the event types they care about."
```

---

### Task 6: EventStore protocol and VersionConflictError

**Files:**
- Create: `Sources/Songbird/EventStore.swift`
- Create: `Tests/SongbirdTests/EventStoreTests.swift`

**Step 1: Write the failing tests**

Create `Tests/SongbirdTests/EventStoreTests.swift`:

```swift
import Testing

@testable import Songbird

@Suite("VersionConflictError")
struct VersionConflictErrorTests {
    @Test func containsConflictDetails() {
        let error = VersionConflictError(
            streamName: StreamName(category: "order", id: "123"),
            expectedVersion: 3,
            actualVersion: 5
        )
        #expect(error.streamName == StreamName(category: "order", id: "123"))
        #expect(error.expectedVersion == 3)
        #expect(error.actualVersion == 5)
    }

    @Test func hasReadableDescription() {
        let error = VersionConflictError(
            streamName: StreamName(category: "order", id: "123"),
            expectedVersion: 3,
            actualVersion: 5
        )
        let desc = error.localizedDescription
        #expect(desc.contains("order-123"))
        #expect(desc.contains("3"))
        #expect(desc.contains("5"))
    }
}

@Suite("EventStore protocol")
struct EventStoreProtocolTests {
    // Verify the protocol is usable as an existential (any EventStore)
    @Test func protocolIsUsableAsExistential() async throws {
        // This test verifies the protocol compiles and can be referenced.
        // Actual store implementations come in Phase 2.
        let _: (any EventStore)? = nil
        _ = _  // suppress unused warning
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test 2>&1`
Expected: Compilation errors — `EventStore`, `VersionConflictError` not defined.

**Step 3: Implement EventStore.swift**

Create `Sources/Songbird/EventStore.swift`:

```swift
public protocol EventStore: Sendable {
    func append(
        _ event: some Event,
        to stream: StreamName,
        metadata: EventMetadata,
        expectedVersion: Int64?
    ) async throws -> RecordedEvent

    func readStream(
        _ stream: StreamName,
        from position: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent]

    func readCategory(
        _ category: String,
        from globalPosition: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent]

    func readLastEvent(
        in stream: StreamName
    ) async throws -> RecordedEvent?

    func streamVersion(
        _ stream: StreamName
    ) async throws -> Int64
}

public struct VersionConflictError: Error, CustomStringConvertible {
    public let streamName: StreamName
    public let expectedVersion: Int64
    public let actualVersion: Int64

    public init(streamName: StreamName, expectedVersion: Int64, actualVersion: Int64) {
        self.streamName = streamName
        self.expectedVersion = expectedVersion
        self.actualVersion = actualVersion
    }

    public var description: String {
        "Version conflict on stream \(streamName): expected \(expectedVersion), actual \(actualVersion)"
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test 2>&1`
Expected: All EventStore tests PASS, zero warnings.

**Step 5: Commit**

```
git add Sources/Songbird/EventStore.swift Tests/SongbirdTests/EventStoreTests.swift
git commit -m "Add EventStore protocol and VersionConflictError

Protocol with append (optimistic concurrency), readStream, readCategory,
readLastEvent, streamVersion. VersionConflictError with stream/version details."
```

---

### Task 7: ProcessManager and Gateway protocol stubs

**Files:**
- Create: `Sources/Songbird/ProcessManager.swift`
- Create: `Sources/Songbird/Gateway.swift`
- Create: `Tests/SongbirdTests/ProcessManagerTests.swift`
- Create: `Tests/SongbirdTests/GatewayTests.swift`

**Step 1: Write the failing tests**

Create `Tests/SongbirdTests/ProcessManagerTests.swift`:

```swift
import Testing

@testable import Songbird

struct ItemReserved: Event {
    static let eventType = "ItemReserved"
    let orderId: String
}

struct ChargePayment: Command {
    static let commandType = "ChargePayment"
    let orderId: String
    let amount: Int
}

enum FulfillmentProcess: ProcessManager {
    struct State: Sendable {
        var reserved: Bool
    }

    typealias InputEvent = ItemReserved
    typealias OutputCommand = ChargePayment

    static let processId = "fulfillment"
    static let initialState = State(reserved: false)

    static func apply(_ state: State, _ event: ItemReserved) -> State {
        State(reserved: true)
    }

    static func commands(_ state: State, _ event: ItemReserved) -> [ChargePayment] {
        [ChargePayment(orderId: event.orderId, amount: 100)]
    }
}

@Suite("ProcessManager")
struct ProcessManagerTests {
    @Test func processIdIsAccessible() {
        #expect(FulfillmentProcess.processId == "fulfillment")
    }

    @Test func applyUpdatesState() {
        let state = FulfillmentProcess.apply(
            FulfillmentProcess.initialState,
            ItemReserved(orderId: "o1")
        )
        #expect(state.reserved == true)
    }

    @Test func commandsProducesOutput() {
        let commands = FulfillmentProcess.commands(
            FulfillmentProcess.initialState,
            ItemReserved(orderId: "o1")
        )
        #expect(commands.count == 1)
        #expect(commands[0].orderId == "o1")
    }
}
```

Create `Tests/SongbirdTests/GatewayTests.swift`:

```swift
import Foundation
import Testing

@testable import Songbird

final class TestNotifier: Gateway, @unchecked Sendable {
    let gatewayId = "test-notifier"
    private(set) var handledEvents: [RecordedEvent] = []

    func handle(_ event: RecordedEvent) async throws {
        handledEvents.append(event)
    }
}

@Suite("Gateway")
struct GatewayTests {
    @Test func gatewayHasId() {
        let gateway = TestNotifier()
        #expect(gateway.gatewayId == "test-notifier")
    }

    @Test func gatewayHandlesEvents() async throws {
        let gateway = TestNotifier()
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
        try await gateway.handle(recorded)
        #expect(gateway.handledEvents.count == 1)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test 2>&1`
Expected: Compilation errors — `ProcessManager`, `Gateway` not defined.

**Step 3: Implement ProcessManager.swift and Gateway.swift**

Create `Sources/Songbird/ProcessManager.swift`:

```swift
public protocol ProcessManager {
    associatedtype State: Sendable
    associatedtype InputEvent: Event
    associatedtype OutputCommand: Command

    static var processId: String { get }
    static var initialState: State { get }
    static func apply(_ state: State, _ event: InputEvent) -> State
    static func commands(_ state: State, _ event: InputEvent) -> [OutputCommand]
}
```

Create `Sources/Songbird/Gateway.swift`:

```swift
public protocol Gateway: Sendable {
    var gatewayId: String { get }
    func handle(_ event: RecordedEvent) async throws
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test 2>&1`
Expected: All ProcessManager and Gateway tests PASS, zero warnings.

**Step 5: Commit**

```
git add Sources/Songbird/ProcessManager.swift Sources/Songbird/Gateway.swift Tests/SongbirdTests/ProcessManagerTests.swift Tests/SongbirdTests/GatewayTests.swift
git commit -m "Add ProcessManager and Gateway protocol stubs

ProcessManager: event-consuming, command-emitting state machine.
Gateway: boundary component for external side effects.
Both are stubs — runtime implementations come in later phases."
```

---

### Task 8: Final review — clean build, all tests pass, no warnings

**Step 1: Verify clean build**

Run: `swift build 2>&1`
Expected: Build complete, zero warnings, zero errors.

**Step 2: Verify all tests pass**

Run: `swift test 2>&1`
Expected: All tests pass, zero warnings, zero failures.

**Step 3: Verify file layout matches design**

Run: `find Sources/Songbird -name '*.swift' | sort`
Expected:
```
Sources/Songbird/Aggregate.swift
Sources/Songbird/Command.swift
Sources/Songbird/Event.swift
Sources/Songbird/EventStore.swift
Sources/Songbird/Gateway.swift
Sources/Songbird/ProcessManager.swift
Sources/Songbird/Projector.swift
Sources/Songbird/StreamName.swift
```

Run: `find Tests/SongbirdTests -name '*.swift' | sort`
Expected:
```
Tests/SongbirdTests/AggregateTests.swift
Tests/SongbirdTests/CommandTests.swift
Tests/SongbirdTests/EventStoreTests.swift
Tests/SongbirdTests/EventTests.swift
Tests/SongbirdTests/GatewayTests.swift
Tests/SongbirdTests/ProcessManagerTests.swift
Tests/SongbirdTests/ProjectorTests.swift
Tests/SongbirdTests/StreamNameTests.swift
```

**Step 4: Write changelog entry**

Create `changelog/0002-core-types.md`:

```markdown
# 0002 — Core Domain Types

Implemented the foundational protocols and types for Songbird (Phase 1):

- **StreamName** — Structured stream identity (category + optional entity ID)
- **Event** — Protocol for immutable domain events (Sendable + Codable + Equatable)
- **EventMetadata** — Tracing fields (traceId, causationId, correlationId, userId)
- **RecordedEvent** — Raw event envelope from the store with decode() bridge
- **EventEnvelope<E>** — Typed event wrapper for user code
- **Command** — Protocol for imperative requests (Sendable)
- **Aggregate** — Protocol with static apply for pure state folding
- **Projector** — Protocol for event-driven read model updates
- **EventStore** — Protocol for append-only event persistence with optimistic concurrency
- **ProcessManager** — Protocol stub for event-to-command state machines
- **Gateway** — Protocol stub for external side effect boundaries
- **VersionConflictError** — Error type for optimistic concurrency failures
```

**Step 5: Commit changelog and push**

```
git add changelog/0002-core-types.md
git commit -m "Add Phase 1 changelog entry"
git push
```
