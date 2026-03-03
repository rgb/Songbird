# Phase 3: Aggregate Execution — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement the CommandHandler protocol and AggregateRepository for loading aggregate state and executing commands. Also includes a breaking change to the Event protocol (static -> instance eventType) to support enum-based events.

**Architecture:** Event protocol changes from static to instance eventType. EventTypeRegistry register API changes to accept explicit eventType string arrays. CommandHandler is a protocol with static `handle` method. AggregateRepository is a generic struct that loads aggregate state by folding events and executes commands via CommandHandler. All in the core Songbird module. Tests use InMemoryEventStore from SongbirdTesting.

**Tech Stack:** Swift 6.2+, macOS 14+, Swift Testing, InMemoryEventStore (SongbirdTesting)

**Test command:** `swift test 2>&1`

**Build command:** `swift build 2>&1`

**Design doc:** `docs/plans/2026-03-03-phase3-aggregate-execution-design.md`

---

### Task 1: Event protocol breaking change (static -> instance eventType)

This is one atomic change because every source and test file that touches `eventType` must change together.

**Files:**
- Modify: `Sources/Songbird/Event.swift`
- Modify: `Sources/Songbird/EventTypeRegistry.swift`
- Modify: `Sources/SongbirdTesting/InMemoryEventStore.swift`
- Modify: `Sources/SongbirdSQLite/SQLiteEventStore.swift`
- Modify: `Tests/SongbirdTests/EventTests.swift`
- Modify: `Tests/SongbirdTests/EventTypeRegistryTests.swift`
- Modify: `Tests/SongbirdTests/AggregateTests.swift`
- Modify: `Tests/SongbirdTests/ProcessManagerTests.swift`
- Modify: `Tests/SongbirdTestingTests/InMemoryEventStoreTests.swift`
- Modify: `Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift`
- Modify: `Package.swift`

**Step 1: Modify `Sources/Songbird/Event.swift`**

Change the `Event` protocol from static to instance `eventType`. Line 4 changes from `static var eventType: String { get }` to `var eventType: String { get }`.

Replace the entire file with:

```swift
import Foundation

public protocol Event: Sendable, Codable, Equatable {
    var eventType: String { get }
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

**Step 2: Modify `Sources/Songbird/EventTypeRegistry.swift`**

Replace the `register` method. The old API `register<E: Event>(_ type: E.Type)` used `E.eventType` (static) as the key. The new API takes explicit eventType strings since enum events have per-case eventType values but share a single decoder.

Replace the entire file with:

```swift
import Foundation

public enum EventTypeRegistryError: Error {
    case unregisteredEventType(String)
}

public final class EventTypeRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var decoders: [String: @Sendable (Data) throws -> any Event] = [:]

    public init() {}

    public func register<E: Event>(_ type: E.Type, eventTypes: [String]) {
        lock.lock()
        defer { lock.unlock() }
        for eventType in eventTypes {
            decoders[eventType] = { data in
                try JSONDecoder().decode(E.self, from: data)
            }
        }
    }

    public func decode(_ recorded: RecordedEvent) throws -> any Event {
        lock.lock()
        let decoder = decoders[recorded.eventType]
        lock.unlock()

        guard let decoder else {
            throw EventTypeRegistryError.unregisteredEventType(recorded.eventType)
        }
        return try decoder(recorded.data)
    }
}
```

**Step 3: Modify `Sources/SongbirdTesting/InMemoryEventStore.swift`**

Line 39: change `type(of: event).eventType` to `event.eventType`.

Replace the entire file with:

```swift
import Foundation
import Songbird

public actor InMemoryEventStore: EventStore {
    private var events: [RecordedEvent] = []
    private var streamPositions: [StreamName: Int64] = [:]
    private var nextGlobalPosition: Int64 = 0
    private let registry: EventTypeRegistry

    public init(registry: EventTypeRegistry = EventTypeRegistry()) {
        self.registry = registry
    }

    public func append(
        _ event: some Event,
        to stream: StreamName,
        metadata: EventMetadata,
        expectedVersion: Int64?
    ) async throws -> RecordedEvent {
        let currentVersion = streamPositions[stream] ?? Int64(-1)

        if let expected = expectedVersion, expected != currentVersion {
            throw VersionConflictError(
                streamName: stream,
                expectedVersion: expected,
                actualVersion: currentVersion
            )
        }

        let position = currentVersion + 1
        let globalPosition = nextGlobalPosition
        let data = try JSONEncoder().encode(event)

        let recorded = RecordedEvent(
            id: UUID(),
            streamName: stream,
            position: position,
            globalPosition: globalPosition,
            eventType: event.eventType,
            data: data,
            metadata: metadata,
            timestamp: Date()
        )

        events.append(recorded)
        streamPositions[stream] = position
        nextGlobalPosition += 1

        return recorded
    }

    public func readStream(
        _ stream: StreamName,
        from position: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        Array(
            events
                .filter { $0.streamName == stream && $0.position >= position }
                .prefix(maxCount)
        )
    }

    public func readCategory(
        _ category: String,
        from globalPosition: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        Array(
            events
                .filter { $0.streamName.category == category && $0.globalPosition >= globalPosition }
                .prefix(maxCount)
        )
    }

    public func readLastEvent(
        in stream: StreamName
    ) async throws -> RecordedEvent? {
        events.last { $0.streamName == stream }
    }

    public func streamVersion(
        _ stream: StreamName
    ) async throws -> Int64 {
        streamPositions[stream] ?? -1
    }
}
```

**Step 4: Modify `Sources/SongbirdSQLite/SQLiteEventStore.swift`**

Line 107: change `type(of: event).eventType` to `event.eventType`.

Replace line 107 only. The line currently reads:

```swift
        let eventType = type(of: event).eventType
```

Change it to:

```swift
        let eventType = event.eventType
```

No other changes to this file.

**Step 5: Modify `Tests/SongbirdTests/EventTests.swift`**

Replace the two struct event types with a single enum. Update all tests accordingly.

Replace the entire file with:

```swift
import Foundation
import Testing

@testable import Songbird

enum CounterEvent: Event {
    case incremented(amount: Int)
    case decremented(amount: Int, reason: String)

    var eventType: String {
        switch self {
        case .incremented: "CounterIncremented"
        case .decremented: "CounterDecremented"
        }
    }
}

@Suite("Event")
struct EventTests {
    @Test func eventTypeIsAccessible() {
        #expect(CounterEvent.incremented(amount: 1).eventType == "CounterIncremented")
        #expect(CounterEvent.decremented(amount: 1, reason: "test").eventType == "CounterDecremented")
    }

    @Test func eventIsCodable() throws {
        let event = CounterEvent.incremented(amount: 5)
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(CounterEvent.self, from: data)
        #expect(event == decoded)
    }

    @Test func eventIsEquatable() {
        let a = CounterEvent.incremented(amount: 5)
        let b = CounterEvent.incremented(amount: 5)
        let c = CounterEvent.incremented(amount: 10)
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

    @Test func equalityDiffersOnSingleField() {
        let a = EventMetadata(traceId: "t1", userId: "u1")
        let b = EventMetadata(traceId: "t1", userId: "u2")
        #expect(a != b)
    }
}

@Suite("RecordedEvent")
struct RecordedEventTests {
    @Test func decodesToTypedEnvelope() throws {
        let event = CounterEvent.incremented(amount: 5)
        let data = try JSONEncoder().encode(event)
        let stream = StreamName(category: "counter", id: "abc")
        let now = Date()
        let id = UUID()

        let recorded = RecordedEvent(
            id: id,
            streamName: stream,
            position: 0,
            globalPosition: 42,
            eventType: event.eventType,
            data: data,
            metadata: EventMetadata(traceId: "t1"),
            timestamp: now
        )

        let envelope = try recorded.decode(CounterEvent.self)
        #expect(envelope.id == id)
        #expect(envelope.streamName == stream)
        #expect(envelope.position == 0)
        #expect(envelope.globalPosition == 42)
        #expect(envelope.event == event)
        #expect(envelope.metadata.traceId == "t1")
        #expect(envelope.timestamp == now)
    }

    @Test func decodeThrowsForCorruptedJSON() {
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "counter", id: "abc"),
            position: 0,
            globalPosition: 0,
            eventType: "CounterIncremented",
            data: Data("not valid json".utf8),
            metadata: EventMetadata(),
            timestamp: Date()
        )

        #expect(throws: (any Error).self) {
            _ = try recorded.decode(CounterEvent.self)
        }
    }
}

@Suite("EventEnvelope")
struct EventEnvelopeTests {
    @Test func preservesAllFields() {
        let id = UUID()
        let stream = StreamName(category: "counter", id: "x")
        let now = Date()
        let meta = EventMetadata(traceId: "t1", userId: "u1")
        let event = CounterEvent.incremented(amount: 7)

        let envelope = EventEnvelope(
            id: id,
            streamName: stream,
            position: 3,
            globalPosition: 42,
            event: event,
            metadata: meta,
            timestamp: now
        )

        #expect(envelope.id == id)
        #expect(envelope.streamName == stream)
        #expect(envelope.position == 3)
        #expect(envelope.globalPosition == 42)
        #expect(envelope.event == event)
        #expect(envelope.metadata.traceId == "t1")
        #expect(envelope.metadata.userId == "u1")
        #expect(envelope.timestamp == now)
    }
}
```

Note: The old `decodeThrowsForWrongType` test is removed because with enum events, there is no "wrong type" scenario at the `RecordedEvent.decode` level -- you decode the enum type itself. The scenario of an unexpected event type in a stream is now tested at the AggregateRepository level (Task 3).

**Step 6: Modify `Tests/SongbirdTests/EventTypeRegistryTests.swift`**

Replace the two struct event types with an enum. Update the register calls to use the new API.

Replace the entire file with:

```swift
import Foundation
import Testing

@testable import Songbird

enum AccountEvent: Event {
    case deposited(amount: Int)
    case withdrawn(amount: Int, reason: String)

    var eventType: String {
        switch self {
        case .deposited: "Deposited"
        case .withdrawn: "Withdrawn"
        }
    }
}

@Suite("EventTypeRegistry")
struct EventTypeRegistryTests {
    @Test func registerAndDecode() throws {
        let registry = EventTypeRegistry()
        registry.register(AccountEvent.self, eventTypes: ["Deposited", "Withdrawn"])

        let event = AccountEvent.deposited(amount: 100)
        let data = try JSONEncoder().encode(event)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "account", id: "1"),
            position: 0,
            globalPosition: 0,
            eventType: "Deposited",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let decoded = try registry.decode(recorded)
        let typed = decoded as! AccountEvent
        #expect(typed == .deposited(amount: 100))
    }

    @Test func decodeUnregisteredTypeThrows() throws {
        let registry = EventTypeRegistry()

        let data = try JSONEncoder().encode(AccountEvent.deposited(amount: 50))
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "account", id: "1"),
            position: 0,
            globalPosition: 0,
            eventType: "Deposited",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        #expect(throws: (any Error).self) {
            _ = try registry.decode(recorded)
        }
    }

    @Test func registerMultipleTypes() throws {
        let registry = EventTypeRegistry()
        registry.register(AccountEvent.self, eventTypes: ["Deposited", "Withdrawn"])

        let depositData = try JSONEncoder().encode(AccountEvent.deposited(amount: 100))
        let withdrawData = try JSONEncoder().encode(AccountEvent.withdrawn(amount: 50, reason: "ATM"))

        let depositRecorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "account", id: "1"),
            position: 0,
            globalPosition: 0,
            eventType: "Deposited",
            data: depositData,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let withdrawRecorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "account", id: "1"),
            position: 1,
            globalPosition: 1,
            eventType: "Withdrawn",
            data: withdrawData,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let d = try registry.decode(depositRecorded) as! AccountEvent
        let w = try registry.decode(withdrawRecorded) as! AccountEvent
        #expect(d == .deposited(amount: 100))
        #expect(w == .withdrawn(amount: 50, reason: "ATM"))
    }
}
```

**Step 7: Modify `Tests/SongbirdTests/AggregateTests.swift`**

Update CounterAggregate to use the enum-based event pattern with instance eventType.

Replace the entire file with:

```swift
import Testing

@testable import Songbird

enum CounterAggregate: Aggregate {
    struct State: Sendable, Equatable {
        var count: Int
    }

    enum Event: Songbird.Event {
        case incremented
        case decremented

        var eventType: String {
            switch self {
            case .incremented: "CounterIncremented"
            case .decremented: "CounterDecremented"
            }
        }
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

**Step 8: Modify `Tests/SongbirdTests/ProcessManagerTests.swift`**

Replace the struct-based ItemReserved event with an enum.

Replace the entire file with:

```swift
import Testing

@testable import Songbird

enum OrderEvent: Event {
    case itemReserved(orderId: String)

    var eventType: String {
        switch self {
        case .itemReserved: "ItemReserved"
        }
    }
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

    typealias InputEvent = OrderEvent
    typealias OutputCommand = ChargePayment

    static let processId = "fulfillment"
    static let initialState = State(reserved: false)

    static func apply(_ state: State, _ event: OrderEvent) -> State {
        switch event {
        case .itemReserved: State(reserved: true)
        }
    }

    static func commands(_ state: State, _ event: OrderEvent) -> [ChargePayment] {
        switch event {
        case .itemReserved(let orderId):
            [ChargePayment(orderId: orderId, amount: 100)]
        }
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
            .itemReserved(orderId: "o1")
        )
        #expect(state.reserved == true)
    }

    @Test func commandsProducesOutput() {
        let commands = FulfillmentProcess.commands(
            FulfillmentProcess.initialState,
            .itemReserved(orderId: "o1")
        )
        #expect(commands.count == 1)
        #expect(commands[0].orderId == "o1")
    }
}
```

**Step 9: Modify `Tests/SongbirdTestingTests/InMemoryEventStoreTests.swift`**

Replace the struct-based Deposited/Withdrawn events with an AccountEvent enum. Update `makeStore()` to use the new register API.

Replace the entire file with:

```swift
import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

enum AccountEvent: Event {
    case deposited(amount: Int)
    case withdrawn(amount: Int, reason: String)

    var eventType: String {
        switch self {
        case .deposited: "Deposited"
        case .withdrawn: "Withdrawn"
        }
    }
}

@Suite("InMemoryEventStore")
struct InMemoryEventStoreTests {
    func makeStore() -> InMemoryEventStore {
        let registry = EventTypeRegistry()
        registry.register(AccountEvent.self, eventTypes: ["Deposited", "Withdrawn"])
        return InMemoryEventStore(registry: registry)
    }

    let stream = StreamName(category: "account", id: "123")

    // MARK: - Append

    @Test func appendReturnsRecordedEvent() async throws {
        let store = makeStore()
        let recorded = try await store.append(
            AccountEvent.deposited(amount: 100),
            to: stream,
            metadata: EventMetadata(traceId: "t1"),
            expectedVersion: nil
        )
        #expect(recorded.streamName == stream)
        #expect(recorded.position == 0)
        #expect(recorded.globalPosition == 0)
        #expect(recorded.eventType == "Deposited")
        #expect(recorded.metadata.traceId == "t1")
    }

    @Test func appendIncrementsPositions() async throws {
        let store = makeStore()
        let r1 = try await store.append(AccountEvent.deposited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        let r2 = try await store.append(AccountEvent.deposited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        #expect(r1.position == 0)
        #expect(r1.globalPosition == 0)
        #expect(r2.position == 1)
        #expect(r2.globalPosition == 1)
    }

    @Test func appendToMultipleStreams() async throws {
        let store = makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "account", id: "b")
        let r1 = try await store.append(AccountEvent.deposited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        let r2 = try await store.append(AccountEvent.deposited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
        #expect(r1.position == 0)
        #expect(r2.position == 0)
        #expect(r1.globalPosition == 0)
        #expect(r2.globalPosition == 1)
    }

    @Test func appendedDataIsDecodable() async throws {
        let store = makeStore()
        let recorded = try await store.append(AccountEvent.deposited(amount: 42), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        let envelope = try recorded.decode(AccountEvent.self)
        #expect(envelope.event == .deposited(amount: 42))
    }

    // MARK: - Optimistic Concurrency

    @Test func appendWithCorrectExpectedVersion() async throws {
        let store = makeStore()
        _ = try await store.append(AccountEvent.deposited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        let r2 = try await store.append(AccountEvent.deposited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: 0)
        #expect(r2.position == 1)
    }

    @Test func appendWithWrongExpectedVersionThrows() async throws {
        let store = makeStore()
        _ = try await store.append(AccountEvent.deposited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        await #expect(throws: VersionConflictError.self) {
            _ = try await store.append(AccountEvent.deposited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: 5)
        }
    }

    @Test func appendWithExpectedVersionOnEmptyStreamThrows() async throws {
        let store = makeStore()
        await #expect(throws: VersionConflictError.self) {
            _ = try await store.append(AccountEvent.deposited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: 0)
        }
    }

    // MARK: - Read Stream

    @Test func readStreamReturnsEventsInOrder() async throws {
        let store = makeStore()
        _ = try await store.append(AccountEvent.deposited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.deposited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.withdrawn(amount: 50, reason: "ATM"), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readStream(stream, from: 0, maxCount: 100)
        #expect(events.count == 3)
        #expect(events[0].position == 0)
        #expect(events[1].position == 1)
        #expect(events[2].position == 2)
        #expect(events[0].eventType == "Deposited")
        #expect(events[2].eventType == "Withdrawn")
    }

    @Test func readStreamFromPosition() async throws {
        let store = makeStore()
        _ = try await store.append(AccountEvent.deposited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.deposited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.deposited(amount: 300), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readStream(stream, from: 1, maxCount: 100)
        #expect(events.count == 2)
        #expect(events[0].position == 1)
    }

    @Test func readStreamWithMaxCount() async throws {
        let store = makeStore()
        for i in 0..<10 {
            _ = try await store.append(AccountEvent.deposited(amount: i), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        }
        let events = try await store.readStream(stream, from: 0, maxCount: 3)
        #expect(events.count == 3)
    }

    @Test func readStreamReturnsEmptyForUnknownStream() async throws {
        let store = makeStore()
        let events = try await store.readStream(StreamName(category: "nope", id: "x"), from: 0, maxCount: 100)
        #expect(events.isEmpty)
    }

    // MARK: - Read Category

    @Test func readCategoryAcrossStreams() async throws {
        let store = makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "account", id: "b")
        let s3 = StreamName(category: "other", id: "c")
        _ = try await store.append(AccountEvent.deposited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.deposited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.deposited(amount: 300), to: s3, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readCategory("account", from: 0, maxCount: 100)
        #expect(events.count == 2)
        #expect(events[0].streamName == s1)
        #expect(events[1].streamName == s2)
    }

    @Test func readCategoryFromGlobalPosition() async throws {
        let store = makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "account", id: "b")
        _ = try await store.append(AccountEvent.deposited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.deposited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readCategory("account", from: 1, maxCount: 100)
        #expect(events.count == 1)
        #expect(events[0].globalPosition == 1)
    }

    // MARK: - Read Last Event

    @Test func readLastEvent() async throws {
        let store = makeStore()
        _ = try await store.append(AccountEvent.deposited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.deposited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let last = try await store.readLastEvent(in: stream)
        #expect(last != nil)
        #expect(last!.position == 1)
    }

    @Test func readLastEventReturnsNilForEmptyStream() async throws {
        let store = makeStore()
        let last = try await store.readLastEvent(in: stream)
        #expect(last == nil)
    }

    // MARK: - Stream Version

    @Test func streamVersionReturnsLatestPosition() async throws {
        let store = makeStore()
        _ = try await store.append(AccountEvent.deposited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.deposited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let version = try await store.streamVersion(stream)
        #expect(version == 1)
    }

    @Test func streamVersionReturnsNegativeOneForEmpty() async throws {
        let store = makeStore()
        let version = try await store.streamVersion(stream)
        #expect(version == -1)
    }
}
```

**Step 10: Modify `Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift`**

Replace the struct-based Credited/Debited events with an AccountEvent enum. Update `makeStore()` to use the new register API.

Replace the entire file with:

```swift
import Foundation
import Testing

@testable import Songbird
@testable import SongbirdSQLite
@testable import SongbirdTesting

enum AccountEvent: Event {
    case credited(amount: Int)
    case debited(amount: Int, note: String)

    var eventType: String {
        switch self {
        case .credited: "Credited"
        case .debited: "Debited"
        }
    }
}

@Suite("SQLiteEventStore")
struct SQLiteEventStoreTests {
    func makeStore() throws -> SQLiteEventStore {
        let registry = EventTypeRegistry()
        registry.register(AccountEvent.self, eventTypes: ["Credited", "Debited"])
        return try SQLiteEventStore(path: ":memory:", registry: registry)
    }

    let stream = StreamName(category: "account", id: "abc")

    // MARK: - Append

    @Test func appendReturnsRecordedEvent() async throws {
        let store = try makeStore()
        let recorded = try await store.append(
            AccountEvent.credited(amount: 100),
            to: stream,
            metadata: EventMetadata(traceId: "t1"),
            expectedVersion: nil
        )
        #expect(recorded.streamName == stream)
        #expect(recorded.position == 0)
        #expect(recorded.globalPosition == 0)
        #expect(recorded.eventType == "Credited")
        #expect(recorded.metadata.traceId == "t1")
    }

    @Test func appendIncrementsPositions() async throws {
        let store = try makeStore()
        let r1 = try await store.append(AccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        let r2 = try await store.append(AccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        #expect(r1.position == 0)
        #expect(r1.globalPosition == 0)
        #expect(r2.position == 1)
        #expect(r2.globalPosition == 1)
    }

    @Test func appendToMultipleStreams() async throws {
        let store = try makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "account", id: "b")
        let r1 = try await store.append(AccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        let r2 = try await store.append(AccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
        #expect(r1.position == 0)
        #expect(r2.position == 0)
        #expect(r1.globalPosition == 0)
        #expect(r2.globalPosition == 1)
    }

    @Test func appendedDataIsDecodable() async throws {
        let store = try makeStore()
        let recorded = try await store.append(AccountEvent.credited(amount: 42), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        let envelope = try recorded.decode(AccountEvent.self)
        #expect(envelope.event == .credited(amount: 42))
    }

    // MARK: - Optimistic Concurrency

    @Test func appendWithCorrectExpectedVersion() async throws {
        let store = try makeStore()
        _ = try await store.append(AccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        let r2 = try await store.append(AccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: 0)
        #expect(r2.position == 1)
    }

    @Test func appendWithWrongExpectedVersionThrows() async throws {
        let store = try makeStore()
        _ = try await store.append(AccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        await #expect(throws: VersionConflictError.self) {
            _ = try await store.append(AccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: 5)
        }
    }

    @Test func appendWithExpectedVersionOnEmptyStreamThrows() async throws {
        let store = try makeStore()
        await #expect(throws: VersionConflictError.self) {
            _ = try await store.append(AccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: 0)
        }
    }

    // MARK: - Read Stream

    @Test func readStreamReturnsEventsInOrder() async throws {
        let store = try makeStore()
        _ = try await store.append(AccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.debited(amount: 50, note: "ATM"), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readStream(stream, from: 0, maxCount: 100)
        #expect(events.count == 3)
        #expect(events[0].position == 0)
        #expect(events[1].position == 1)
        #expect(events[2].position == 2)
        #expect(events[0].eventType == "Credited")
        #expect(events[2].eventType == "Debited")
    }

    @Test func readStreamFromPosition() async throws {
        let store = try makeStore()
        _ = try await store.append(AccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 300), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readStream(stream, from: 1, maxCount: 100)
        #expect(events.count == 2)
        #expect(events[0].position == 1)
    }

    @Test func readStreamWithMaxCount() async throws {
        let store = try makeStore()
        for i in 0..<10 {
            _ = try await store.append(AccountEvent.credited(amount: i), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        }
        let events = try await store.readStream(stream, from: 0, maxCount: 3)
        #expect(events.count == 3)
    }

    @Test func readStreamReturnsEmptyForUnknownStream() async throws {
        let store = try makeStore()
        let events = try await store.readStream(StreamName(category: "nope", id: "x"), from: 0, maxCount: 100)
        #expect(events.isEmpty)
    }

    // MARK: - Read Category

    @Test func readCategoryAcrossStreams() async throws {
        let store = try makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "account", id: "b")
        let s3 = StreamName(category: "other", id: "c")
        _ = try await store.append(AccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 300), to: s3, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readCategory("account", from: 0, maxCount: 100)
        #expect(events.count == 2)
    }

    @Test func readCategoryFromGlobalPosition() async throws {
        let store = try makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "account", id: "b")
        _ = try await store.append(AccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readCategory("account", from: 1, maxCount: 100)
        #expect(events.count == 1)
        #expect(events[0].globalPosition == 1)
    }

    // MARK: - Read Last / Version

    @Test func readLastEvent() async throws {
        let store = try makeStore()
        _ = try await store.append(AccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let last = try await store.readLastEvent(in: stream)
        #expect(last != nil)
        #expect(last!.position == 1)
    }

    @Test func readLastEventReturnsNilForEmptyStream() async throws {
        let store = try makeStore()
        let last = try await store.readLastEvent(in: stream)
        #expect(last == nil)
    }

    @Test func streamVersionReturnsLatestPosition() async throws {
        let store = try makeStore()
        _ = try await store.append(AccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let version = try await store.streamVersion(stream)
        #expect(version == 1)
    }

    @Test func streamVersionReturnsNegativeOneForEmpty() async throws {
        let store = try makeStore()
        let version = try await store.streamVersion(stream)
        #expect(version == -1)
    }

    // MARK: - Hash Chain

    @Test func hashChainIsIntactAfterAppends() async throws {
        let store = try makeStore()
        _ = try await store.append(AccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.debited(amount: 50, note: "fee"), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let result = try await store.verifyChain()
        #expect(result.intact == true)
        #expect(result.eventsVerified == 3)
        #expect(result.brokenAtSequence == nil)
    }

    @Test func emptyStoreChainIsIntact() async throws {
        let store = try makeStore()
        let result = try await store.verifyChain()
        #expect(result.intact == true)
        #expect(result.eventsVerified == 0)
    }

    @Test func tamperedEventBreaksChain() async throws {
        let store = try makeStore()
        _ = try await store.append(AccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 300), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        // Tamper with the second event's data
        try await store.rawExecute(
            "UPDATE events SET data = '{\"amount\":999}' WHERE global_position = 2"
        )

        let result = try await store.verifyChain()
        #expect(result.intact == false)
        #expect(result.eventsVerified == 1)
        #expect(result.brokenAtSequence == 2)
    }
}
```

Note: The `tamperedEventBreaksChain` test changes `data` to `'{"amount":999}'`. With enum events, the JSON for `AccountEvent.credited(amount: 300)` will be `{"credited":{"amount":300}}` (enum discriminated encoding). The tampered data `{"amount":999}` will fail to decode as a valid `AccountEvent` case AND break the hash chain. The hash chain verification operates on raw strings, not decoded events, so the chain break still works exactly as before -- the stored hash no longer matches the recomputed hash. The stored data string changes but the hash stored in the row remains the old one.

**Step 11: Modify `Package.swift`**

Add `SongbirdTesting` as a dependency for `SongbirdTests` (needed for Task 3, but done here so we have a clean build after Task 1).

Replace the entire file with:

```swift
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Songbird",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "Songbird", targets: ["Songbird"]),
        .library(name: "SongbirdTesting", targets: ["SongbirdTesting"]),
        .library(name: "SongbirdSQLite", targets: ["SongbirdSQLite"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", exact: "0.15.3"),
    ],
    targets: [
        // MARK: - Core

        .target(
            name: "Songbird"
        ),

        // MARK: - Testing

        .target(
            name: "SongbirdTesting",
            dependencies: ["Songbird"]
        ),

        // MARK: - SQLite

        .target(
            name: "SongbirdSQLite",
            dependencies: [
                "Songbird",
                .product(name: "SQLite", package: "SQLite.swift"),
            ]
        ),

        // MARK: - Tests

        .testTarget(
            name: "SongbirdTests",
            dependencies: ["Songbird", "SongbirdTesting"]
        ),

        .testTarget(
            name: "SongbirdTestingTests",
            dependencies: ["SongbirdTesting"]
        ),

        .testTarget(
            name: "SongbirdSQLiteTests",
            dependencies: ["SongbirdSQLite", "SongbirdTesting"]
        ),
    ]
)
```

**Verify:**

```bash
swift build 2>&1
```

Then:

```bash
swift test 2>&1
```

All existing tests must pass. Zero warnings, zero errors.

**Commit:**

```
Event protocol: change eventType from static to instance property

Enables enum-based events where each case has its own eventType string.
Updates EventTypeRegistry to accept explicit eventType arrays.
Migrates all test events from structs to enums.
Adds SongbirdTesting dependency to SongbirdTests target.
```

---

### Task 2: CommandHandler protocol

**Files:**
- Create: `Sources/Songbird/CommandHandler.swift`

**Step 1: Write the failing test**

There is no separate test file for CommandHandler. It is a protocol with no default implementations -- it will be exercised through AggregateRepository tests in Task 3. The protocol itself must compile and be usable.

**Step 2: Create `Sources/Songbird/CommandHandler.swift`**

```swift
public protocol CommandHandler {
    associatedtype Agg: Aggregate
    associatedtype Cmd: Command

    static func handle(
        _ command: Cmd,
        given state: Agg.State
    ) throws(Agg.Failure) -> [Agg.Event]
}
```

**Verify:**

```bash
swift build 2>&1
```

Zero warnings, zero errors.

**Commit:**

```
Add CommandHandler protocol

Type-safe protocol for handling commands against aggregate state.
Returns typed events and throws typed aggregate failures.
```

---

### Task 3: AggregateRepository + tests

**Files:**
- Create: `Sources/Songbird/AggregateRepository.swift`
- Create: `Tests/SongbirdTests/AggregateRepositoryTests.swift`

**Step 1: Write the failing test first**

Create `Tests/SongbirdTests/AggregateRepositoryTests.swift` with the complete test suite. This will fail to compile because `AggregateRepository` and `AggregateError` don't exist yet.

```swift
import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

// MARK: - Test Domain

enum AccountEvent: Event {
    case opened(name: String)
    case deposited(amount: Int)
    case withdrawn(amount: Int)

    var eventType: String {
        switch self {
        case .opened: "AccountOpened"
        case .deposited: "AccountDeposited"
        case .withdrawn: "AccountWithdrawn"
        }
    }
}

struct OpenAccount: Command {
    static let commandType = "OpenAccount"
    let name: String
}

struct Deposit: Command {
    static let commandType = "Deposit"
    let amount: Int
}

struct Withdraw: Command {
    static let commandType = "Withdraw"
    let amount: Int
}

enum BankAccountAggregate: Aggregate {
    struct State: Sendable, Equatable {
        var isOpen: Bool = false
        var balance: Int = 0
        var name: String = ""
    }

    typealias Event = AccountEvent
    enum Failure: Error { case notOpen, alreadyOpen, insufficientFunds }

    static let category = "account"
    static let initialState = State()

    static func apply(_ state: State, _ event: AccountEvent) -> State {
        switch event {
        case .opened(let name):
            State(isOpen: true, balance: 0, name: name)
        case .deposited(let amount):
            State(isOpen: state.isOpen, balance: state.balance + amount, name: state.name)
        case .withdrawn(let amount):
            State(isOpen: state.isOpen, balance: state.balance - amount, name: state.name)
        }
    }
}

enum OpenAccountHandler: CommandHandler {
    typealias Agg = BankAccountAggregate
    typealias Cmd = OpenAccount

    static func handle(
        _ command: OpenAccount,
        given state: BankAccountAggregate.State
    ) throws(BankAccountAggregate.Failure) -> [AccountEvent] {
        guard !state.isOpen else { throw .alreadyOpen }
        return [.opened(name: command.name)]
    }
}

enum DepositHandler: CommandHandler {
    typealias Agg = BankAccountAggregate
    typealias Cmd = Deposit

    static func handle(
        _ command: Deposit,
        given state: BankAccountAggregate.State
    ) throws(BankAccountAggregate.Failure) -> [AccountEvent] {
        guard state.isOpen else { throw .notOpen }
        return [.deposited(amount: command.amount)]
    }
}

enum WithdrawHandler: CommandHandler {
    typealias Agg = BankAccountAggregate
    typealias Cmd = Withdraw

    static func handle(
        _ command: Withdraw,
        given state: BankAccountAggregate.State
    ) throws(BankAccountAggregate.Failure) -> [AccountEvent] {
        guard state.isOpen else { throw .notOpen }
        guard state.balance >= command.amount else { throw .insufficientFunds }
        return [.withdrawn(amount: command.amount)]
    }
}

// MARK: - Tests

@Suite("AggregateRepository")
struct AggregateRepositoryTests {
    func makeRepo() -> (AggregateRepository<BankAccountAggregate>, InMemoryEventStore) {
        let registry = EventTypeRegistry()
        registry.register(AccountEvent.self, eventTypes: ["AccountOpened", "AccountDeposited", "AccountWithdrawn"])
        let store = InMemoryEventStore(registry: registry)
        let repo = AggregateRepository<BankAccountAggregate>(store: store, registry: registry)
        return (repo, store)
    }

    let meta = EventMetadata(traceId: "test")

    // MARK: - Load

    @Test func loadEmptyStream() async throws {
        let (repo, _) = makeRepo()
        let (state, version) = try await repo.load(id: "acct-1")
        #expect(state == BankAccountAggregate.initialState)
        #expect(version == -1)
    }

    @Test func loadWithEvents() async throws {
        let (repo, store) = makeRepo()
        let stream = StreamName(category: "account", id: "acct-1")
        _ = try await store.append(AccountEvent.opened(name: "Alice"), to: stream, metadata: meta, expectedVersion: nil)
        _ = try await store.append(AccountEvent.deposited(amount: 100), to: stream, metadata: meta, expectedVersion: nil)
        _ = try await store.append(AccountEvent.withdrawn(amount: 30), to: stream, metadata: meta, expectedVersion: nil)

        let (state, version) = try await repo.load(id: "acct-1")
        #expect(state == BankAccountAggregate.State(isOpen: true, balance: 70, name: "Alice"))
        #expect(version == 2)
    }

    // MARK: - Execute

    @Test func executeAppendsEvents() async throws {
        let (repo, store) = makeRepo()
        let recorded = try await repo.execute(
            OpenAccount(name: "Bob"),
            on: "acct-1",
            metadata: meta,
            using: OpenAccountHandler.self
        )
        #expect(recorded.count == 1)
        #expect(recorded[0].eventType == "AccountOpened")
        #expect(recorded[0].streamName == StreamName(category: "account", id: "acct-1"))

        let events = try await store.readStream(StreamName(category: "account", id: "acct-1"), from: 0, maxCount: 100)
        #expect(events.count == 1)
    }

    @Test func executeUsesOptimisticConcurrency() async throws {
        let (repo, store) = makeRepo()
        // Open the account first
        _ = try await repo.execute(OpenAccount(name: "Carol"), on: "acct-1", metadata: meta, using: OpenAccountHandler.self)

        // Deposit -- this should pass optimistic concurrency (expectedVersion: 0)
        let recorded = try await repo.execute(Deposit(amount: 50), on: "acct-1", metadata: meta, using: DepositHandler.self)
        #expect(recorded[0].position == 1)

        // Verify there are now 2 events in the stream
        let events = try await store.readStream(StreamName(category: "account", id: "acct-1"), from: 0, maxCount: 100)
        #expect(events.count == 2)
    }

    @Test func executeWithFailedValidation() async throws {
        let (repo, store) = makeRepo()
        // Try to deposit without opening -- should throw .notOpen
        do {
            _ = try await repo.execute(Deposit(amount: 100), on: "acct-1", metadata: meta, using: DepositHandler.self)
            Issue.record("Expected error to be thrown")
        } catch {
            // Error was thrown as expected
        }

        // No events should have been appended
        let events = try await store.readStream(StreamName(category: "account", id: "acct-1"), from: 0, maxCount: 100)
        #expect(events.isEmpty)
    }

    @Test func executeMultipleCommands() async throws {
        let (repo, _) = makeRepo()
        _ = try await repo.execute(OpenAccount(name: "Dave"), on: "acct-1", metadata: meta, using: OpenAccountHandler.self)
        _ = try await repo.execute(Deposit(amount: 200), on: "acct-1", metadata: meta, using: DepositHandler.self)
        _ = try await repo.execute(Withdraw(amount: 75), on: "acct-1", metadata: meta, using: WithdrawHandler.self)

        let (state, version) = try await repo.load(id: "acct-1")
        #expect(state == BankAccountAggregate.State(isOpen: true, balance: 125, name: "Dave"))
        #expect(version == 2)
    }

    @Test func handlerCanReturnMultipleEvents() async throws {
        // Define a handler that returns multiple events from a single command
        enum BulkDepositHandler: CommandHandler {
            typealias Agg = BankAccountAggregate
            typealias Cmd = Deposit

            static func handle(
                _ command: Deposit,
                given state: BankAccountAggregate.State
            ) throws(BankAccountAggregate.Failure) -> [AccountEvent] {
                guard state.isOpen else { throw .notOpen }
                // Split deposit into two events
                let half = command.amount / 2
                let remainder = command.amount - half
                return [.deposited(amount: half), .deposited(amount: remainder)]
            }
        }

        let registry = EventTypeRegistry()
        registry.register(AccountEvent.self, eventTypes: ["AccountOpened", "AccountDeposited", "AccountWithdrawn"])
        let store = InMemoryEventStore(registry: registry)
        let repo = AggregateRepository<BankAccountAggregate>(store: store, registry: registry)

        _ = try await repo.execute(OpenAccount(name: "Eve"), on: "acct-1", metadata: meta, using: OpenAccountHandler.self)
        let recorded = try await repo.execute(Deposit(amount: 100), on: "acct-1", metadata: meta, using: BulkDepositHandler.self)

        #expect(recorded.count == 2)
        #expect(recorded[0].eventType == "AccountDeposited")
        #expect(recorded[1].eventType == "AccountDeposited")

        let (state, _) = try await repo.load(id: "acct-1")
        #expect(state.balance == 100)
    }
}
```

**Verify this fails to compile:**

```bash
swift build 2>&1
```

Expected: compilation error because `AggregateRepository` and `AggregateError` don't exist.

**Step 2: Create `Sources/Songbird/AggregateRepository.swift`**

```swift
public struct AggregateRepository<A: Aggregate>: Sendable {
    public let store: any EventStore
    public let registry: EventTypeRegistry

    public init(store: any EventStore, registry: EventTypeRegistry) {
        self.store = store
        self.registry = registry
    }

    public func load(id: String) async throws -> (state: A.State, version: Int64) {
        let stream = StreamName(category: A.category, id: id)
        let records = try await store.readStream(stream, from: 0, maxCount: Int.max)
        var state = A.initialState
        for record in records {
            let decoded = try registry.decode(record)
            guard let event = decoded as? A.Event else {
                throw AggregateError.unexpectedEventType(record.eventType)
            }
            state = A.apply(state, event)
        }
        let version = records.last?.position ?? -1
        return (state, version)
    }

    public func execute<H: CommandHandler>(
        _ command: H.Cmd,
        on id: String,
        metadata: EventMetadata,
        using handler: H.Type
    ) async throws -> [RecordedEvent] where H.Agg == A {
        let (state, version) = try await load(id: id)
        let events = try handler.handle(command, given: state)
        let stream = StreamName(category: A.category, id: id)
        var recorded: [RecordedEvent] = []
        for (index, event) in events.enumerated() {
            let expectedVersion: Int64? = index == 0 ? version : nil
            let result = try await store.append(
                event,
                to: stream,
                metadata: metadata,
                expectedVersion: expectedVersion
            )
            recorded.append(result)
        }
        return recorded
    }
}

public enum AggregateError: Error {
    case unexpectedEventType(String)
}
```

**Verify:**

```bash
swift build 2>&1
```

Then:

```bash
swift test 2>&1
```

All tests pass. Zero warnings, zero errors.

**Commit:**

```
Add AggregateRepository and CommandHandler-based execution

AggregateRepository loads aggregate state by folding events from the
store and executes commands via CommandHandler with optimistic
concurrency. Full test suite covers load, execute, validation failure,
multi-command sequences, and multi-event handlers.
```

---

### Task 4: Final review, changelog, commit

**Files:**
- Create: `changelog/0004-aggregate-execution.md`

**Step 1: Run full test suite**

```bash
swift test 2>&1
```

Verify: all tests pass, zero warnings, zero errors.

**Step 2: Create `changelog/0004-aggregate-execution.md`**

```markdown
# 0004 — Aggregate Execution

Implemented Phase 3 of Songbird:

**Breaking change:**
- **Event protocol** -- `eventType` changed from static property to instance property, enabling enum-based events with per-case eventType strings
- **EventTypeRegistry** -- `register` API now takes explicit `eventTypes: [String]` array instead of using static `E.eventType`
- All test events migrated from structs to enums

**New types:**
- **CommandHandler** -- Protocol for type-safe command handling against aggregate state. Returns typed events, throws typed aggregate failures.
- **AggregateRepository** -- Generic struct that loads aggregate state by folding events from the store and executes commands via CommandHandler with optimistic concurrency control.
- **AggregateError** -- Error enum for unexpected event types during aggregate loading.

**Package.swift:**
- SongbirdTests now depends on SongbirdTesting (for InMemoryEventStore in repository tests)
```

**Commit:**

```
Add changelog for Phase 3: Aggregate Execution
```

**Step 3: Verify clean build one final time**

```bash
swift build 2>&1
swift test 2>&1
```

Zero warnings, zero errors, all tests pass.
