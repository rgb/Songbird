# Phase 6: Message Hierarchy, Store Generalization & Reactive Streams — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Introduce the `Message` base protocol unifying `Event` and `Command`, generalize `EventStore.readCategory` to multi-category `readCategories`, rename `CategorySubscription` to `EventSubscription` with multi-category support, add `StreamSubscription` for entity-level polling, and add `AggregateStateStream` for reactive aggregate state observation.

**Architecture:** `Message` is the shared base protocol (`Sendable`, `Codable`, `Equatable`) that both `Event` and `Command` extend. `EventStore` gains a `readCategories([String], ...)` method (empty = all events) with convenience extensions for single-category and all-events reads. `EventSubscription` replaces `CategorySubscription` using `readCategories` internally. `StreamSubscription` polls `readStream` for a single entity stream without position persistence. `AggregateStateStream` folds events through `Aggregate.apply` and yields state updates reactively.

**Tech Stack:** Swift 6.2+, macOS 14+, Swift Testing, AsyncSequence/AsyncIteratorProtocol, DispatchSerialQueue custom executor (SQLite), SQLite.swift

**Test command:** `swift test 2>&1`

**Build command:** `swift build 2>&1`

**Design doc:** `docs/plans/2026-03-03-phase6-message-hierarchy-design.md`

---

### Task 1: Message protocol hierarchy + Command update (ATOMIC)

This is an atomic change -- Message protocol, Event conformance, Command conformance, and all test Command updates must happen together so the project compiles.

**Files:**
- Create: `Sources/Songbird/Message.swift`
- Create: `Tests/SongbirdTests/MessageTests.swift`
- Modify: `Sources/Songbird/Event.swift`
- Modify: `Sources/Songbird/Command.swift`
- Modify: `Tests/SongbirdTests/CommandTests.swift`
- Modify: `Tests/SongbirdTests/ProcessManagerTests.swift`
- Modify: `Tests/SongbirdTests/AggregateRepositoryTests.swift`

**Step 1: Write the tests**

Create `Tests/SongbirdTests/MessageTests.swift`:

```swift
import Foundation
import Testing

@testable import Songbird

// MARK: - Test Types

enum TestEvent: Event {
    case happened(value: Int)

    var eventType: String {
        switch self {
        case .happened: "Happened"
        }
    }
}

struct TestCommand: Command {
    var commandType: String { "TestCommand" }
    let target: String
}

// MARK: - Tests

@Suite("Message")
struct MessageTests {

    // MARK: - Event conforms to Message

    @Test func eventConformsToMessage() {
        let event: any Message = TestEvent.happened(value: 42)
        #expect(event.messageType == "Happened")
    }

    @Test func eventMessageTypeMatchesEventType() {
        let event = TestEvent.happened(value: 7)
        #expect(event.messageType == event.eventType)
    }

    // MARK: - Command conforms to Message

    @Test func commandConformsToMessage() {
        let command: any Message = TestCommand(target: "x")
        #expect(command.messageType == "TestCommand")
    }

    @Test func commandMessageTypeMatchesCommandType() {
        let command = TestCommand(target: "y")
        #expect(command.messageType == command.commandType)
    }

    // MARK: - Command is Codable

    @Test func commandIsCodable() throws {
        let command = TestCommand(target: "hello")
        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(TestCommand.self, from: data)
        #expect(decoded == command)
    }

    // MARK: - Command is Equatable

    @Test func commandIsEquatable() {
        let a = TestCommand(target: "a")
        let b = TestCommand(target: "a")
        let c = TestCommand(target: "b")
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - Command commandType is instance property

    @Test func commandTypeIsInstanceProperty() {
        let command = TestCommand(target: "z")
        #expect(command.commandType == "TestCommand")
    }
}
```

**Step 2: Create Message protocol**

Create `Sources/Songbird/Message.swift`:

```swift
public protocol Message: Sendable, Codable, Equatable {
    var messageType: String { get }
}
```

**Step 3: Update Event to extend Message**

Replace the contents of `Sources/Songbird/Event.swift` with:

```swift
import Foundation

public protocol Event: Message {
    var eventType: String { get }
}

extension Event {
    public var messageType: String { eventType }
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

**Step 4: Update Command to extend Message**

Replace the contents of `Sources/Songbird/Command.swift` with:

```swift
public protocol Command: Message {
    var commandType: String { get }
}

extension Command {
    public var messageType: String { commandType }
}
```

**Step 5: Update test Command conformances**

Update `Tests/SongbirdTests/CommandTests.swift` -- replace the entire file with:

```swift
import Testing

@testable import Songbird

struct IncrementCounter: Command {
    var commandType: String { "IncrementCounter" }
    let amount: Int
}

@Suite("Command")
struct CommandTests {
    @Test func commandTypeIsAccessible() {
        let cmd = IncrementCounter(amount: 1)
        #expect(cmd.commandType == "IncrementCounter")
    }

    @Test func commandIsSendable() {
        let cmd = IncrementCounter(amount: 5)
        let closure: @Sendable () -> Void = { _ = cmd.amount }
        _ = closure
    }
}
```

Update `Tests/SongbirdTests/ProcessManagerTests.swift` -- replace the entire file with:

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
    var commandType: String { "ChargePayment" }
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

Update `Tests/SongbirdTests/AggregateRepositoryTests.swift` -- change only the three Command structs. Replace:

```swift
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
```

with:

```swift
struct OpenAccount: Command {
    var commandType: String { "OpenAccount" }
    let name: String
}

struct Deposit: Command {
    var commandType: String { "Deposit" }
    let amount: Int
}

struct Withdraw: Command {
    var commandType: String { "Withdraw" }
    let amount: Int
}
```

**Step 6: Run tests**

Run: `swift test 2>&1`
Expected: All tests pass, zero warnings.

**Step 7: Commit**

```bash
git add Sources/Songbird/Message.swift Sources/Songbird/Event.swift Sources/Songbird/Command.swift Tests/SongbirdTests/MessageTests.swift Tests/SongbirdTests/CommandTests.swift Tests/SongbirdTests/ProcessManagerTests.swift Tests/SongbirdTests/AggregateRepositoryTests.swift
git commit -m "Add Message protocol hierarchy unifying Event and Command

Message is the shared base (Sendable, Codable, Equatable) that both
Event and Command extend. Command.commandType is now an instance
property matching Event.eventType. 7 new MessageTests covering
conformance, Codable round-trip, Equatable, and messageType routing."
```

---

### Task 2: EventStore readCategories (ATOMIC)

Replaces the single-category `readCategory` protocol requirement with `readCategories([String], ...)` and adds convenience extensions. Both InMemoryEventStore and SQLiteEventStore implementations are updated atomically.

**Files:**
- Modify: `Sources/Songbird/EventStore.swift`
- Modify: `Sources/SongbirdTesting/InMemoryEventStore.swift`
- Modify: `Sources/SongbirdSQLite/SQLiteEventStore.swift`
- Modify: `Tests/SongbirdTestingTests/InMemoryEventStoreTests.swift`
- Modify: `Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift`

**Step 1: Write the tests**

Add the following tests to the end of `Tests/SongbirdTestingTests/InMemoryEventStoreTests.swift` (before the final closing brace):

```swift
    // MARK: - Read Categories (Multi-Category)

    @Test func readCategoriesWithMultipleCategories() async throws {
        let store = makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "invoice", id: "b")
        let s3 = StreamName(category: "order", id: "c")
        _ = try await store.append(AccountEvent.deposited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.deposited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.deposited(amount: 300), to: s3, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readCategories(["account", "invoice"], from: 0, maxCount: 100)
        #expect(events.count == 2)
        #expect(events[0].streamName == s1)
        #expect(events[1].streamName == s2)
    }

    @Test func readAllReturnsAllCategories() async throws {
        let store = makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "invoice", id: "b")
        let s3 = StreamName(category: "order", id: "c")
        _ = try await store.append(AccountEvent.deposited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.deposited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.deposited(amount: 300), to: s3, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readAll(from: 0, maxCount: 100)
        #expect(events.count == 3)
    }

    @Test func readAllFromGlobalPosition() async throws {
        let store = makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "invoice", id: "b")
        _ = try await store.append(AccountEvent.deposited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.deposited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readAll(from: 1, maxCount: 100)
        #expect(events.count == 1)
        #expect(events[0].globalPosition == 1)
    }

    @Test func readCategoriesWithEmptyArrayReturnsAllEvents() async throws {
        let store = makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "invoice", id: "b")
        _ = try await store.append(AccountEvent.deposited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.deposited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readCategories([], from: 0, maxCount: 100)
        #expect(events.count == 2)
    }

    @Test func readCategoryConvenienceStillWorks() async throws {
        let store = makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "other", id: "b")
        _ = try await store.append(AccountEvent.deposited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.deposited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readCategory("account", from: 0, maxCount: 100)
        #expect(events.count == 1)
        #expect(events[0].streamName == s1)
    }
```

Add the following tests to the end of `Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift` (before the final closing brace):

```swift
    // MARK: - Read Categories (Multi-Category)

    @Test func readCategoriesWithMultipleCategories() async throws {
        let store = try makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "invoice", id: "b")
        let s3 = StreamName(category: "order", id: "c")
        _ = try await store.append(AccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 300), to: s3, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readCategories(["account", "invoice"], from: 0, maxCount: 100)
        #expect(events.count == 2)
        #expect(events[0].streamName == s1)
        #expect(events[1].streamName == s2)
    }

    @Test func readAllReturnsAllCategories() async throws {
        let store = try makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "invoice", id: "b")
        let s3 = StreamName(category: "order", id: "c")
        _ = try await store.append(AccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 300), to: s3, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readAll(from: 0, maxCount: 100)
        #expect(events.count == 3)
    }

    @Test func readAllFromGlobalPosition() async throws {
        let store = try makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "invoice", id: "b")
        _ = try await store.append(AccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readAll(from: 1, maxCount: 100)
        #expect(events.count == 1)
        #expect(events[0].globalPosition == 1)
    }

    @Test func readCategoriesWithEmptyArrayReturnsAllEvents() async throws {
        let store = try makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "invoice", id: "b")
        _ = try await store.append(AccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readCategories([], from: 0, maxCount: 100)
        #expect(events.count == 2)
    }

    @Test func readCategoryConvenienceStillWorks() async throws {
        let store = try makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "other", id: "b")
        _ = try await store.append(AccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readCategory("account", from: 0, maxCount: 100)
        #expect(events.count == 1)
        #expect(events[0].streamName == s1)
    }
```

**Step 2: Update EventStore protocol**

Replace the contents of `Sources/Songbird/EventStore.swift` with:

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

    func readCategories(
        _ categories: [String],
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

extension EventStore {
    public func readCategory(
        _ category: String,
        from globalPosition: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        try await readCategories([category], from: globalPosition, maxCount: maxCount)
    }

    public func readAll(
        from globalPosition: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        try await readCategories([], from: globalPosition, maxCount: maxCount)
    }
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

**Step 3: Update InMemoryEventStore**

In `Sources/SongbirdTesting/InMemoryEventStore.swift`, replace the `readCategory` method with `readCategories`:

Replace:

```swift
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
```

with:

```swift
    public func readCategories(
        _ categories: [String],
        from globalPosition: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        let categorySet = Set(categories)
        return Array(
            events
                .filter { $0.globalPosition >= globalPosition && (categorySet.isEmpty || categorySet.contains($0.streamName.category)) }
                .prefix(maxCount)
        )
    }
```

**Step 4: Update SQLiteEventStore**

In `Sources/SongbirdSQLite/SQLiteEventStore.swift`, replace the `readCategory` method and its `// MARK: - Read Category` comment with `readCategories`:

Replace:

```swift
    // MARK: - Read Category

    public func readCategory(
        _ category: String,
        from globalPosition: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        let rows = try db.prepare("""
            SELECT global_position, stream_name, stream_category, position, event_type, data, metadata, event_id, timestamp
            FROM events
            WHERE stream_category = ? AND (global_position - 1) >= ?
            ORDER BY global_position ASC
            LIMIT ?
        """, category, globalPosition, maxCount)

        return try rows.map { row in try recordedEvent(from: row) }
    }
```

with:

```swift
    // MARK: - Read Categories

    public func readCategories(
        _ categories: [String],
        from globalPosition: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        let rows: Statement
        if categories.isEmpty {
            rows = try db.prepare("""
                SELECT global_position, stream_name, stream_category, position, event_type, data, metadata, event_id, timestamp
                FROM events
                WHERE (global_position - 1) >= ?
                ORDER BY global_position ASC
                LIMIT ?
            """, globalPosition, maxCount)
        } else if categories.count == 1 {
            rows = try db.prepare("""
                SELECT global_position, stream_name, stream_category, position, event_type, data, metadata, event_id, timestamp
                FROM events
                WHERE stream_category = ? AND (global_position - 1) >= ?
                ORDER BY global_position ASC
                LIMIT ?
            """, categories[0], globalPosition, maxCount)
        } else {
            let placeholders = categories.map { _ in "?" }.joined(separator: ", ")
            let bindings: [Binding?] = categories.map { $0 as Binding? } + [globalPosition as Binding?, maxCount as Binding?]
            rows = try db.prepare("""
                SELECT global_position, stream_name, stream_category, position, event_type, data, metadata, event_id, timestamp
                FROM events
                WHERE stream_category IN (\(placeholders)) AND (global_position - 1) >= ?
                ORDER BY global_position ASC
                LIMIT ?
            """, bindings)
        }

        return try rows.map { row in try recordedEvent(from: row) }
    }
```

**Step 5: Run tests**

Run: `swift test 2>&1`
Expected: All tests pass, zero warnings. Existing `readCategory` tests pass via the convenience extension.

**Step 6: Commit**

```bash
git add Sources/Songbird/EventStore.swift Sources/SongbirdTesting/InMemoryEventStore.swift Sources/SongbirdSQLite/SQLiteEventStore.swift Tests/SongbirdTestingTests/InMemoryEventStoreTests.swift Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift
git commit -m "Generalize EventStore readCategory to readCategories

Replace the single-category readCategory protocol requirement with
readCategories([String], ...). Empty array returns all events. Convenience
extensions readCategory and readAll delegate to readCategories.
InMemoryEventStore uses Set-based filter, SQLiteEventStore uses dynamic
SQL (no WHERE / single WHERE / WHERE IN). 10 new tests across both
store implementations."
```

---

### Task 3: Rename CategorySubscription to EventSubscription

Renames the type and file, changes `category: String` to `categories: [String]`, and uses `readCategories` internally. Existing test file is renamed and updated, with new tests for multi-category and all-events subscriptions.

**Files:**
- Rename: `Sources/Songbird/CategorySubscription.swift` -> `Sources/Songbird/EventSubscription.swift`
- Rename: `Tests/SongbirdTests/CategorySubscriptionTests.swift` -> `Tests/SongbirdTests/EventSubscriptionTests.swift`

**Step 1: Rename files**

```bash
cd /Users/greg/Development/Songbird
git mv Sources/Songbird/CategorySubscription.swift Sources/Songbird/EventSubscription.swift
git mv Tests/SongbirdTests/CategorySubscriptionTests.swift Tests/SongbirdTests/EventSubscriptionTests.swift
```

**Step 2: Write updated implementation**

Replace the contents of `Sources/Songbird/EventSubscription.swift` with:

```swift
import Foundation

/// A polling-based subscription that reads events from one or more categories as an `AsyncSequence`.
///
/// The subscription polls `EventStore.readCategories` in batches and yields events one at a time.
/// Position is persisted to a `PositionStore` after each batch is fully consumed, enabling
/// restartability. When caught up (no new events), the subscription sleeps for `tickInterval`
/// before polling again. The sequence ends when the enclosing `Task` is cancelled.
///
/// When `categories` is empty, the subscription reads all events across all categories.
///
/// Usage:
/// ```swift
/// // Single category
/// let subscription = EventSubscription(
///     subscriberId: "order-projector",
///     categories: ["order"],
///     store: eventStore,
///     positionStore: positionStore
/// )
///
/// // Multiple categories
/// let subscription = EventSubscription(
///     subscriberId: "cross-domain-projector",
///     categories: ["order", "invoice"],
///     store: eventStore,
///     positionStore: positionStore
/// )
///
/// // All events
/// let subscription = EventSubscription(
///     subscriberId: "audit-log",
///     categories: [],
///     store: eventStore,
///     positionStore: positionStore
/// )
///
/// let task = Task {
///     for try await event in subscription {
///         try await projector.apply(event)
///     }
/// }
///
/// // Later: cancel stops the polling loop
/// task.cancel()
/// ```
public struct EventSubscription: AsyncSequence, Sendable {
    public typealias Element = RecordedEvent

    public let subscriberId: String
    public let categories: [String]
    public let store: any EventStore
    public let positionStore: any PositionStore
    public let batchSize: Int
    public let tickInterval: Duration

    public init(
        subscriberId: String,
        categories: [String],
        store: any EventStore,
        positionStore: any PositionStore,
        batchSize: Int = 100,
        tickInterval: Duration = .milliseconds(100)
    ) {
        self.subscriberId = subscriberId
        self.categories = categories
        self.store = store
        self.positionStore = positionStore
        self.batchSize = batchSize
        self.tickInterval = tickInterval
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(
            subscriberId: subscriberId,
            categories: categories,
            store: store,
            positionStore: positionStore,
            batchSize: batchSize,
            tickInterval: tickInterval
        )
    }

    public struct Iterator: AsyncIteratorProtocol {
        let subscriberId: String
        let categories: [String]
        let store: any EventStore
        let positionStore: any PositionStore
        let batchSize: Int
        let tickInterval: Duration
        private var currentBatch: [RecordedEvent] = []
        private var batchIndex: Int = 0
        private var globalPosition: Int64 = -1
        private var positionLoaded: Bool = false

        init(
            subscriberId: String,
            categories: [String],
            store: any EventStore,
            positionStore: any PositionStore,
            batchSize: Int,
            tickInterval: Duration
        ) {
            self.subscriberId = subscriberId
            self.categories = categories
            self.store = store
            self.positionStore = positionStore
            self.batchSize = batchSize
            self.tickInterval = tickInterval
        }

        public mutating func next() async throws -> RecordedEvent? {
            // Load persisted position on first call
            if !positionLoaded {
                globalPosition = try await positionStore.load(subscriberId: subscriberId) ?? -1
                positionLoaded = true
            }

            // Return next event from current batch if available
            if batchIndex < currentBatch.count {
                let event = currentBatch[batchIndex]
                batchIndex += 1
                return event
            }

            // Current batch exhausted -- save position if we had events
            if !currentBatch.isEmpty {
                let lastPosition = currentBatch[currentBatch.count - 1].globalPosition
                try await positionStore.save(
                    subscriberId: subscriberId,
                    globalPosition: lastPosition
                )
                globalPosition = lastPosition
            }

            // Poll for next batch
            while !Task.isCancelled {
                try Task.checkCancellation()

                let batch = try await store.readCategories(
                    categories,
                    from: globalPosition + 1,
                    maxCount: batchSize
                )

                if !batch.isEmpty {
                    currentBatch = batch
                    batchIndex = 1  // return first element now, start from second next time
                    return batch[0]
                }

                // Caught up -- sleep before polling again
                try await Task.sleep(for: tickInterval)
            }

            return nil  // cancelled
        }
    }
}
```

**Step 3: Write updated tests**

Replace the contents of `Tests/SongbirdTests/EventSubscriptionTests.swift` with:

```swift
import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

// Simple test event for subscription tests
enum SubscriptionTestEvent: Event {
    case occurred(value: Int)

    var eventType: String {
        switch self {
        case .occurred: "Occurred"
        }
    }
}

/// Actor to safely collect events across task boundaries in tests.
actor EventCollector {
    private(set) var events: [RecordedEvent] = []

    func append(_ event: RecordedEvent) {
        events.append(event)
    }

    var count: Int { events.count }
}

@Suite("EventSubscription")
struct EventSubscriptionTests {

    let category = "order"

    func makeStores() -> (InMemoryEventStore, InMemoryPositionStore) {
        let registry = EventTypeRegistry()
        registry.register(SubscriptionTestEvent.self, eventTypes: ["Occurred"])
        return (InMemoryEventStore(registry: registry), InMemoryPositionStore())
    }

    func appendEvents(
        to store: InMemoryEventStore,
        category: String,
        count: Int,
        startId: Int = 1
    ) async throws {
        for i in startId..<(startId + count) {
            let stream = StreamName(category: category, id: "\(i)")
            _ = try await store.append(
                SubscriptionTestEvent.occurred(value: i),
                to: stream,
                metadata: EventMetadata(),
                expectedVersion: nil
            )
        }
    }

    // MARK: - Basic Consumption

    @Test func subscribesToCategoryEvents() async throws {
        let (eventStore, positionStore) = makeStores()
        try await appendEvents(to: eventStore, category: category, count: 3)

        let subscription = EventSubscription(
            subscriberId: "test-sub",
            categories: [category],
            store: eventStore,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        )

        let collector = EventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                if await collector.count == 3 { break }
            }
        }

        try await task.value
        let received = await collector.events
        #expect(received.count == 3)
        #expect(received[0].globalPosition == 0)
        #expect(received[1].globalPosition == 1)
        #expect(received[2].globalPosition == 2)
    }

    @Test func skipsOtherCategories() async throws {
        let (eventStore, positionStore) = makeStores()

        // Append to "order" category
        let orderStream = StreamName(category: "order", id: "1")
        _ = try await eventStore.append(
            SubscriptionTestEvent.occurred(value: 1),
            to: orderStream,
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Append to "invoice" category
        let invoiceStream = StreamName(category: "invoice", id: "1")
        _ = try await eventStore.append(
            SubscriptionTestEvent.occurred(value: 2),
            to: invoiceStream,
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Append another to "order" category
        let orderStream2 = StreamName(category: "order", id: "2")
        _ = try await eventStore.append(
            SubscriptionTestEvent.occurred(value: 3),
            to: orderStream2,
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        let subscription = EventSubscription(
            subscriberId: "test-sub",
            categories: ["order"],
            store: eventStore,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        )

        let collector = EventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                if await collector.count == 2 { break }
            }
        }

        try await task.value
        let received = await collector.events
        #expect(received.count == 2)
        #expect(received[0].streamName.category == "order")
        #expect(received[1].streamName.category == "order")
    }

    // MARK: - Position Persistence

    @Test func resumesFromPersistedPosition() async throws {
        let (eventStore, positionStore) = makeStores()

        // Append 5 events (global positions 0..4)
        try await appendEvents(to: eventStore, category: category, count: 5)

        // Pre-set position to 2 (already processed through global position 2)
        try await positionStore.save(subscriberId: "test-sub", globalPosition: 2)

        let subscription = EventSubscription(
            subscriberId: "test-sub",
            categories: [category],
            store: eventStore,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        )

        let collector = EventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                if await collector.count == 2 { break }
            }
        }

        try await task.value
        let received = await collector.events
        #expect(received.count == 2)
        // Should start from position 3 (after persisted position 2)
        #expect(received[0].globalPosition == 3)
        #expect(received[1].globalPosition == 4)
    }

    @Test func savesPositionAfterBatch() async throws {
        let (eventStore, positionStore) = makeStores()

        // Append 5 events with batch size 3
        try await appendEvents(to: eventStore, category: category, count: 5)

        let subscription = EventSubscription(
            subscriberId: "test-sub",
            categories: [category],
            store: eventStore,
            positionStore: positionStore,
            batchSize: 3,
            tickInterval: .milliseconds(10)
        )

        let collector = EventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                // Consume all 5 events (first batch of 3, then batch of 2)
                if await collector.count == 5 { break }
            }
        }

        try await task.value

        // Position should be saved after batches are exhausted.
        // After consuming all events and breaking, the last fully-consumed batch
        // had its position saved. The position saved is the last event of the
        // most recently exhausted batch.
        let savedPosition = try await positionStore.load(subscriberId: "test-sub")
        #expect(savedPosition != nil)
        // After first batch (0,1,2) is exhausted, position 2 is saved.
        // Then second batch (3,4) starts yielding. We break after event 4.
        // The second batch was exhausted at index 2 (batchIndex == currentBatch.count)
        // which triggers position save for the first batch only if we re-enter next().
        // Actually: after yielding all 3 from first batch, next() saves position 2,
        // then fetches second batch (3,4), yields 3, then 4. After 4, we break.
        // Position 2 was saved when first batch was exhausted. Position 4 is NOT saved
        // yet because we broke before exhausting the iterator's internal state.
        // The saved position should be 2 (from the first batch completion).
        #expect(savedPosition == 2)
    }

    // MARK: - Cancellation

    @Test func stopsOnTaskCancellation() async throws {
        let (eventStore, positionStore) = makeStores()

        // Append a few events so the subscription has something to start with
        try await appendEvents(to: eventStore, category: category, count: 2)

        let subscription = EventSubscription(
            subscriberId: "test-sub",
            categories: [category],
            store: eventStore,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        )

        let collector = EventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                // Don't break -- let it poll forever
            }
        }

        // Let the subscription process existing events
        try await Task.sleep(for: .milliseconds(50))

        // Cancel the task
        task.cancel()

        // The task should finish without hanging.
        // Cancellation may cause CancellationError from Task.sleep, which is expected.
        let result = await task.result
        switch result {
        case .success:
            break  // clean exit via nil return
        case .failure(let error):
            #expect(error is CancellationError)
        }
        let count = await collector.count
        #expect(count == 2)
    }

    // MARK: - Polling

    @Test func pollsForNewEvents() async throws {
        let (eventStore, positionStore) = makeStores()

        let subscription = EventSubscription(
            subscriberId: "test-sub",
            categories: [category],
            store: eventStore,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        )

        let collector = EventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                if await collector.count == 3 { break }
            }
        }

        // Give the subscription time to start polling on an empty store
        try await Task.sleep(for: .milliseconds(30))
        let earlyCount = await collector.count
        #expect(earlyCount == 0)

        // Now append events -- the subscription should pick them up
        try await appendEvents(to: eventStore, category: category, count: 3)

        try await task.value
        let finalCount = await collector.count
        #expect(finalCount == 3)
    }

    @Test func handlesEmptyStore() async throws {
        let (eventStore, positionStore) = makeStores()

        let subscription = EventSubscription(
            subscriberId: "test-sub",
            categories: [category],
            store: eventStore,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        )

        let task = Task {
            for try await _ in subscription {
                // Should never get here
            }
        }

        // Let it poll a few times on the empty store
        try await Task.sleep(for: .milliseconds(50))

        // Cancel -- should not crash
        task.cancel()

        // Await completion. Cancellation may cause CancellationError, which is expected.
        let result = await task.result
        switch result {
        case .success:
            break  // clean exit via nil return
        case .failure(let error):
            #expect(error is CancellationError)
        }
    }

    // MARK: - Multi-Category Subscription

    @Test func subscribesToMultipleCategories() async throws {
        let (eventStore, positionStore) = makeStores()

        // Append events to different categories
        let orderStream = StreamName(category: "order", id: "1")
        let invoiceStream = StreamName(category: "invoice", id: "1")
        let shipmentStream = StreamName(category: "shipment", id: "1")
        _ = try await eventStore.append(SubscriptionTestEvent.occurred(value: 1), to: orderStream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await eventStore.append(SubscriptionTestEvent.occurred(value: 2), to: invoiceStream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await eventStore.append(SubscriptionTestEvent.occurred(value: 3), to: shipmentStream, metadata: EventMetadata(), expectedVersion: nil)

        let subscription = EventSubscription(
            subscriberId: "test-sub",
            categories: ["order", "invoice"],
            store: eventStore,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        )

        let collector = EventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                if await collector.count == 2 { break }
            }
        }

        try await task.value
        let received = await collector.events
        #expect(received.count == 2)
        // Should get order and invoice, but not shipment
        let categories = Set(received.map(\.streamName.category))
        #expect(categories == ["order", "invoice"])
    }

    // MARK: - All-Events Subscription

    @Test func subscribesToAllEventsWithEmptyCategories() async throws {
        let (eventStore, positionStore) = makeStores()

        // Append events to different categories
        let orderStream = StreamName(category: "order", id: "1")
        let invoiceStream = StreamName(category: "invoice", id: "1")
        let shipmentStream = StreamName(category: "shipment", id: "1")
        _ = try await eventStore.append(SubscriptionTestEvent.occurred(value: 1), to: orderStream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await eventStore.append(SubscriptionTestEvent.occurred(value: 2), to: invoiceStream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await eventStore.append(SubscriptionTestEvent.occurred(value: 3), to: shipmentStream, metadata: EventMetadata(), expectedVersion: nil)

        let subscription = EventSubscription(
            subscriberId: "test-sub",
            categories: [],
            store: eventStore,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        )

        let collector = EventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                if await collector.count == 3 { break }
            }
        }

        try await task.value
        let received = await collector.events
        #expect(received.count == 3)
        let categories = Set(received.map(\.streamName.category))
        #expect(categories == ["order", "invoice", "shipment"])
    }
}
```

**Step 4: Run tests**

Run: `swift test 2>&1`
Expected: All tests pass, zero warnings.

**Step 5: Commit**

```bash
git add Sources/Songbird/EventSubscription.swift Tests/SongbirdTests/EventSubscriptionTests.swift
git commit -m "Rename CategorySubscription to EventSubscription with multi-category support

Replace category: String with categories: [String]. Empty array subscribes
to all events. Uses readCategories internally. File and type renamed.
2 new tests for multi-category and all-events subscriptions. All existing
subscription behavior preserved."
```

---

### Task 4: StreamSubscription (entity-level)

A new polling-based `AsyncSequence` that reads events from a single entity stream (e.g., `account-123`). Unlike `EventSubscription`, this does not persist position -- it is designed for reactive use (fold from start, track live updates).

**Files:**
- Create: `Sources/Songbird/StreamSubscription.swift`
- Create: `Tests/SongbirdTests/StreamSubscriptionTests.swift`

**Step 1: Write the tests**

Create `Tests/SongbirdTests/StreamSubscriptionTests.swift`:

```swift
import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

// Test event type for stream subscription tests
enum StreamTestEvent: Event {
    case updated(value: Int)

    var eventType: String {
        switch self {
        case .updated: "Updated"
        }
    }
}

/// Actor to safely collect events across task boundaries in tests.
private actor StreamEventCollector {
    private(set) var events: [RecordedEvent] = []

    func append(_ event: RecordedEvent) {
        events.append(event)
    }

    var count: Int { events.count }
}

@Suite("StreamSubscription")
struct StreamSubscriptionTests {

    let stream = StreamName(category: "widget", id: "42")

    func makeStore() -> InMemoryEventStore {
        let registry = EventTypeRegistry()
        registry.register(StreamTestEvent.self, eventTypes: ["Updated"])
        return InMemoryEventStore(registry: registry)
    }

    // MARK: - Basic Consumption

    @Test func consumesEventsFromStream() async throws {
        let store = makeStore()
        _ = try await store.append(StreamTestEvent.updated(value: 1), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(StreamTestEvent.updated(value: 2), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(StreamTestEvent.updated(value: 3), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let subscription = StreamSubscription(
            stream: stream,
            store: store,
            tickInterval: .milliseconds(10)
        )

        let collector = StreamEventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                if await collector.count == 3 { break }
            }
        }

        try await task.value
        let received = await collector.events
        #expect(received.count == 3)
        #expect(received[0].position == 0)
        #expect(received[1].position == 1)
        #expect(received[2].position == 2)
    }

    // MARK: - Start Position

    @Test func startsFromSpecifiedPosition() async throws {
        let store = makeStore()
        _ = try await store.append(StreamTestEvent.updated(value: 1), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(StreamTestEvent.updated(value: 2), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(StreamTestEvent.updated(value: 3), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let subscription = StreamSubscription(
            stream: stream,
            store: store,
            startPosition: 2,
            tickInterval: .milliseconds(10)
        )

        let collector = StreamEventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                if await collector.count == 1 { break }
            }
        }

        try await task.value
        let received = await collector.events
        #expect(received.count == 1)
        #expect(received[0].position == 2)
    }

    // MARK: - Stream Isolation

    @Test func onlyReadsFromTargetStream() async throws {
        let store = makeStore()
        let otherStream = StreamName(category: "widget", id: "99")
        _ = try await store.append(StreamTestEvent.updated(value: 1), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(StreamTestEvent.updated(value: 2), to: otherStream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(StreamTestEvent.updated(value: 3), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let subscription = StreamSubscription(
            stream: stream,
            store: store,
            tickInterval: .milliseconds(10)
        )

        let collector = StreamEventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                if await collector.count == 2 { break }
            }
        }

        try await task.value
        let received = await collector.events
        #expect(received.count == 2)
        #expect(received[0].streamName == stream)
        #expect(received[1].streamName == stream)
    }

    // MARK: - Polling for New Events

    @Test func pollsForNewEvents() async throws {
        let store = makeStore()

        let subscription = StreamSubscription(
            stream: stream,
            store: store,
            tickInterval: .milliseconds(10)
        )

        let collector = StreamEventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                if await collector.count == 2 { break }
            }
        }

        // Give the subscription time to start polling on an empty stream
        try await Task.sleep(for: .milliseconds(30))
        let earlyCount = await collector.count
        #expect(earlyCount == 0)

        // Append events -- the subscription should pick them up
        _ = try await store.append(StreamTestEvent.updated(value: 1), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(StreamTestEvent.updated(value: 2), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        try await task.value
        let finalCount = await collector.count
        #expect(finalCount == 2)
    }

    // MARK: - Cancellation

    @Test func stopsOnTaskCancellation() async throws {
        let store = makeStore()
        _ = try await store.append(StreamTestEvent.updated(value: 1), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let subscription = StreamSubscription(
            stream: stream,
            store: store,
            tickInterval: .milliseconds(10)
        )

        let collector = StreamEventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                // Don't break -- let it poll forever
            }
        }

        // Let the subscription process existing events
        try await Task.sleep(for: .milliseconds(50))

        // Cancel the task
        task.cancel()

        // The task should finish without hanging.
        let result = await task.result
        switch result {
        case .success:
            break
        case .failure(let error):
            #expect(error is CancellationError)
        }
        let count = await collector.count
        #expect(count == 1)
    }

    // MARK: - Batch Size

    @Test func respectsBatchSize() async throws {
        let store = makeStore()
        for i in 0..<10 {
            _ = try await store.append(StreamTestEvent.updated(value: i), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        }

        let subscription = StreamSubscription(
            stream: stream,
            store: store,
            batchSize: 3,
            tickInterval: .milliseconds(10)
        )

        let collector = StreamEventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                if await collector.count == 10 { break }
            }
        }

        try await task.value
        let received = await collector.events
        #expect(received.count == 10)
        // Events should be in order regardless of batch boundaries
        for i in 0..<10 {
            #expect(received[i].position == Int64(i))
        }
    }
}
```

**Step 2: Implement StreamSubscription**

Create `Sources/Songbird/StreamSubscription.swift`:

```swift
import Foundation

/// A polling-based subscription that reads events from a single entity stream as an `AsyncSequence`.
///
/// The subscription polls `EventStore.readStream` in batches and yields events one at a time.
/// Unlike `EventSubscription`, `StreamSubscription` does not persist position -- it is designed
/// for reactive use cases where you fold events from a known start position and track live updates.
///
/// When caught up (no new events), the subscription sleeps for `tickInterval` before polling again.
/// The sequence ends when the enclosing `Task` is cancelled.
///
/// Usage:
/// ```swift
/// let subscription = StreamSubscription(
///     stream: StreamName(category: "account", id: "123"),
///     store: eventStore
/// )
///
/// let task = Task {
///     for try await event in subscription {
///         // process event
///     }
/// }
///
/// // Later: cancel stops the polling loop
/// task.cancel()
/// ```
public struct StreamSubscription: AsyncSequence, Sendable {
    public typealias Element = RecordedEvent

    public let stream: StreamName
    public let store: any EventStore
    public let startPosition: Int64
    public let batchSize: Int
    public let tickInterval: Duration

    public init(
        stream: StreamName,
        store: any EventStore,
        startPosition: Int64 = 0,
        batchSize: Int = 100,
        tickInterval: Duration = .milliseconds(100)
    ) {
        self.stream = stream
        self.store = store
        self.startPosition = startPosition
        self.batchSize = batchSize
        self.tickInterval = tickInterval
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(
            stream: stream,
            store: store,
            position: startPosition,
            batchSize: batchSize,
            tickInterval: tickInterval
        )
    }

    public struct Iterator: AsyncIteratorProtocol {
        let stream: StreamName
        let store: any EventStore
        let batchSize: Int
        let tickInterval: Duration
        private var currentBatch: [RecordedEvent] = []
        private var batchIndex: Int = 0
        private var position: Int64

        init(
            stream: StreamName,
            store: any EventStore,
            position: Int64,
            batchSize: Int,
            tickInterval: Duration
        ) {
            self.stream = stream
            self.store = store
            self.position = position
            self.batchSize = batchSize
            self.tickInterval = tickInterval
        }

        public mutating func next() async throws -> RecordedEvent? {
            // Return next event from current batch if available
            if batchIndex < currentBatch.count {
                let event = currentBatch[batchIndex]
                batchIndex += 1
                return event
            }

            // Current batch exhausted -- advance position
            if !currentBatch.isEmpty {
                position = currentBatch[currentBatch.count - 1].position + 1
            }

            // Poll for next batch
            while !Task.isCancelled {
                try Task.checkCancellation()

                let batch = try await store.readStream(
                    stream,
                    from: position,
                    maxCount: batchSize
                )

                if !batch.isEmpty {
                    currentBatch = batch
                    batchIndex = 1  // return first element now, start from second next time
                    return batch[0]
                }

                // Caught up -- sleep before polling again
                try await Task.sleep(for: tickInterval)
            }

            return nil  // cancelled
        }
    }
}
```

**Step 3: Run tests**

Run: `swift test 2>&1`
Expected: All tests pass, zero warnings.

**Step 4: Commit**

```bash
git add Sources/Songbird/StreamSubscription.swift Tests/SongbirdTests/StreamSubscriptionTests.swift
git commit -m "Add StreamSubscription for entity-level event polling

Polls EventStore.readStream for a single entity stream. No position
persistence -- designed for reactive use cases that fold from a known
start position and track live updates. Configurable start position,
batch size, and tick interval. Cooperative cancellation. 6 tests
covering consumption, start position, stream isolation, polling,
cancellation, and batch size."
```

---

### Task 5: AggregateStateStream

A reactive `AsyncSequence` that yields the current state of an aggregate, updating live as new events arrive. On first iteration, it reads all existing events, folds them through `Aggregate.apply`, and yields the resulting state (or `initialState` if no events exist). Then it polls for new events and yields updated state on each change.

**Files:**
- Create: `Sources/Songbird/AggregateStateStream.swift`
- Create: `Tests/SongbirdTests/AggregateStateStreamTests.swift`

**Step 1: Write the tests**

Create `Tests/SongbirdTests/AggregateStateStreamTests.swift`:

```swift
import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

// MARK: - Test Aggregate

enum BalanceAggregate: Aggregate {
    struct State: Sendable, Equatable {
        var balance: Int
    }

    enum Event: Songbird.Event {
        case credited(amount: Int)
        case debited(amount: Int)

        var eventType: String {
            switch self {
            case .credited: "BalanceCredited"
            case .debited: "BalanceDebited"
            }
        }
    }

    enum Failure: Error {
        case insufficientFunds
    }

    static let category = "balance"
    static let initialState = State(balance: 0)

    static func apply(_ state: State, _ event: Event) -> State {
        switch event {
        case .credited(let amount): State(balance: state.balance + amount)
        case .debited(let amount): State(balance: state.balance - amount)
        }
    }
}

/// Actor to safely collect states across task boundaries in tests.
private actor StateCollector<S: Sendable> {
    private(set) var states: [S] = []

    func append(_ state: S) {
        states.append(state)
    }

    var count: Int { states.count }
}

@Suite("AggregateStateStream")
struct AggregateStateStreamTests {

    func makeStore() -> (InMemoryEventStore, EventTypeRegistry) {
        let registry = EventTypeRegistry()
        registry.register(BalanceAggregate.Event.self, eventTypes: ["BalanceCredited", "BalanceDebited"])
        return (InMemoryEventStore(registry: registry), registry)
    }

    let stream = StreamName(category: "balance", id: "acct-1")

    // MARK: - Empty Stream Yields Initial State

    @Test func emptyStreamYieldsInitialState() async throws {
        let (store, registry) = makeStore()

        let stateStream = AggregateStateStream<BalanceAggregate>(
            id: "acct-1",
            store: store,
            registry: registry,
            tickInterval: .milliseconds(10)
        )

        let collector = StateCollector<BalanceAggregate.State>()
        let task = Task {
            for try await state in stateStream {
                await collector.append(state)
                if await collector.count == 1 { break }
            }
        }

        try await task.value
        let states = await collector.states
        #expect(states.count == 1)
        #expect(states[0] == BalanceAggregate.initialState)
    }

    // MARK: - Existing Events Yield Folded State

    @Test func existingEventsYieldFoldedState() async throws {
        let (store, registry) = makeStore()
        _ = try await store.append(BalanceAggregate.Event.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(BalanceAggregate.Event.debited(amount: 30), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let stateStream = AggregateStateStream<BalanceAggregate>(
            id: "acct-1",
            store: store,
            registry: registry,
            tickInterval: .milliseconds(10)
        )

        let collector = StateCollector<BalanceAggregate.State>()
        let task = Task {
            for try await state in stateStream {
                await collector.append(state)
                if await collector.count == 1 { break }
            }
        }

        try await task.value
        let states = await collector.states
        #expect(states.count == 1)
        #expect(states[0] == BalanceAggregate.State(balance: 70))
    }

    // MARK: - Live Updates Yield New State

    @Test func liveUpdatesYieldNewState() async throws {
        let (store, registry) = makeStore()
        _ = try await store.append(BalanceAggregate.Event.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let stateStream = AggregateStateStream<BalanceAggregate>(
            id: "acct-1",
            store: store,
            registry: registry,
            tickInterval: .milliseconds(10)
        )

        let collector = StateCollector<BalanceAggregate.State>()
        let task = Task {
            for try await state in stateStream {
                await collector.append(state)
                if await collector.count == 3 { break }
            }
        }

        // Wait for initial state to be yielded
        try await Task.sleep(for: .milliseconds(50))

        // Append more events -- should trigger new state yields
        _ = try await store.append(BalanceAggregate.Event.credited(amount: 50), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(BalanceAggregate.Event.debited(amount: 20), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        try await task.value
        let states = await collector.states
        #expect(states.count == 3)
        #expect(states[0] == BalanceAggregate.State(balance: 100))  // initial fold
        #expect(states[1] == BalanceAggregate.State(balance: 150))  // after +50
        #expect(states[2] == BalanceAggregate.State(balance: 130))  // after -20
    }

    // MARK: - Cancellation

    @Test func stopsOnTaskCancellation() async throws {
        let (store, registry) = makeStore()

        let stateStream = AggregateStateStream<BalanceAggregate>(
            id: "acct-1",
            store: store,
            registry: registry,
            tickInterval: .milliseconds(10)
        )

        let collector = StateCollector<BalanceAggregate.State>()
        let task = Task {
            for try await state in stateStream {
                await collector.append(state)
                // Don't break -- let it poll forever
            }
        }

        // Let the stream yield initial state
        try await Task.sleep(for: .milliseconds(50))

        // Cancel the task
        task.cancel()

        // The task should finish without hanging
        let result = await task.result
        switch result {
        case .success:
            break
        case .failure(let error):
            #expect(error is CancellationError)
        }
        let count = await collector.count
        #expect(count == 1)  // only initial state
    }

    // MARK: - Multiple Events in Single Poll

    @Test func multipleEventsInSinglePollYieldMultipleStates() async throws {
        let (store, registry) = makeStore()

        let stateStream = AggregateStateStream<BalanceAggregate>(
            id: "acct-1",
            store: store,
            registry: registry,
            tickInterval: .milliseconds(10)
        )

        let collector = StateCollector<BalanceAggregate.State>()
        let task = Task {
            for try await state in stateStream {
                await collector.append(state)
                // Initial state + 3 event-driven states
                if await collector.count == 4 { break }
            }
        }

        // Wait for initial empty state to be yielded
        try await Task.sleep(for: .milliseconds(50))

        // Append three events at once -- they should all be in one poll batch
        _ = try await store.append(BalanceAggregate.Event.credited(amount: 10), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(BalanceAggregate.Event.credited(amount: 20), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(BalanceAggregate.Event.credited(amount: 30), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        try await task.value
        let states = await collector.states
        #expect(states.count == 4)
        #expect(states[0] == BalanceAggregate.State(balance: 0))   // initial
        #expect(states[1] == BalanceAggregate.State(balance: 10))  // +10
        #expect(states[2] == BalanceAggregate.State(balance: 30))  // +20
        #expect(states[3] == BalanceAggregate.State(balance: 60))  // +30
    }
}
```

**Step 2: Implement AggregateStateStream**

Create `Sources/Songbird/AggregateStateStream.swift`:

```swift
import Foundation

/// A reactive `AsyncSequence` that yields the current state of an aggregate, updating live
/// as new events arrive in the entity stream.
///
/// On the first iteration call, the stream reads all existing events, decodes them via the
/// provided `EventTypeRegistry`, folds them through `Aggregate.apply`, and yields the resulting
/// state. If no events exist, `Aggregate.initialState` is yielded. After the initial fold,
/// the stream polls for new events from the last known position, applies each one, and yields
/// the updated state for every event.
///
/// The stream does not persist position -- it always folds from the beginning on creation.
/// This makes it suitable for live UI updates, in-memory caches, and reactive projections.
///
/// Usage:
/// ```swift
/// let stateStream = AggregateStateStream<BankAccountAggregate>(
///     id: "acct-123",
///     store: eventStore,
///     registry: registry
/// )
///
/// let task = Task {
///     for try await state in stateStream {
///         print("Balance: \(state.balance)")
///     }
/// }
///
/// // Later: cancel stops the polling loop
/// task.cancel()
/// ```
public struct AggregateStateStream<A: Aggregate>: AsyncSequence, Sendable {
    public typealias Element = A.State

    public let id: String
    public let store: any EventStore
    public let registry: EventTypeRegistry
    public let batchSize: Int
    public let tickInterval: Duration

    public init(
        id: String,
        store: any EventStore,
        registry: EventTypeRegistry,
        batchSize: Int = 100,
        tickInterval: Duration = .milliseconds(100)
    ) {
        self.id = id
        self.store = store
        self.registry = registry
        self.batchSize = batchSize
        self.tickInterval = tickInterval
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(
            stream: StreamName(category: A.category, id: id),
            store: store,
            registry: registry,
            batchSize: batchSize,
            tickInterval: tickInterval
        )
    }

    public struct Iterator: AsyncIteratorProtocol {
        let stream: StreamName
        let store: any EventStore
        let registry: EventTypeRegistry
        let batchSize: Int
        let tickInterval: Duration
        private var state: A.State = A.initialState
        private var position: Int64 = 0
        private var initialFoldDone: Bool = false

        init(
            stream: StreamName,
            store: any EventStore,
            registry: EventTypeRegistry,
            batchSize: Int,
            tickInterval: Duration
        ) {
            self.stream = stream
            self.store = store
            self.registry = registry
            self.batchSize = batchSize
            self.tickInterval = tickInterval
        }

        public mutating func next() async throws -> A.State? {
            // Phase 1: Initial fold -- read all existing events and yield folded state
            if !initialFoldDone {
                initialFoldDone = true

                while true {
                    let batch = try await store.readStream(
                        stream,
                        from: position,
                        maxCount: batchSize
                    )

                    for record in batch {
                        let decoded = try registry.decode(record)
                        guard let event = decoded as? A.Event else {
                            throw AggregateError.unexpectedEventType(record.eventType)
                        }
                        state = A.apply(state, event)
                        position = record.position + 1
                    }

                    if batch.count < batchSize { break }
                }

                return state
            }

            // Phase 2: Poll for new events, yield state after each one
            while !Task.isCancelled {
                try Task.checkCancellation()

                let batch = try await store.readStream(
                    stream,
                    from: position,
                    maxCount: batchSize
                )

                if !batch.isEmpty {
                    // Apply the first event and yield the updated state.
                    // Remaining events in the batch will be processed on subsequent
                    // calls to next() via the same poll-then-apply loop.
                    let record = batch[0]
                    let decoded = try registry.decode(record)
                    guard let event = decoded as? A.Event else {
                        throw AggregateError.unexpectedEventType(record.eventType)
                    }
                    state = A.apply(state, event)
                    position = record.position + 1
                    return state
                }

                // Caught up -- sleep before polling again
                try await Task.sleep(for: tickInterval)
            }

            return nil  // cancelled
        }
    }
}
```

**Step 3: Run tests**

Run: `swift test 2>&1`
Expected: All tests pass, zero warnings.

**Step 4: Commit**

```bash
git add Sources/Songbird/AggregateStateStream.swift Tests/SongbirdTests/AggregateStateStreamTests.swift
git commit -m "Add AggregateStateStream for reactive aggregate state observation

Reads all existing events, folds through Aggregate.apply, yields state.
Then polls for new events and yields updated state on each change.
Always yields at least one value (initialState for empty streams).
No position persistence -- folds from beginning on creation. 5 tests
covering empty stream, existing events, live updates, cancellation,
and multi-event batch handling."
```

---

### Task 6: Final review, changelog, push

**Step 1: Verify clean build**

Run: `swift build 2>&1`
Expected: Build complete, zero warnings, zero errors.

**Step 2: Verify all tests pass**

Run: `swift test 2>&1`
Expected: All tests pass, zero warnings.

**Step 3: Verify file layout**

Confirm these new files exist:
- `Sources/Songbird/Message.swift`
- `Sources/Songbird/EventSubscription.swift` (renamed from CategorySubscription.swift)
- `Sources/Songbird/StreamSubscription.swift`
- `Sources/Songbird/AggregateStateStream.swift`
- `Tests/SongbirdTests/MessageTests.swift`
- `Tests/SongbirdTests/EventSubscriptionTests.swift` (renamed from CategorySubscriptionTests.swift)
- `Tests/SongbirdTests/StreamSubscriptionTests.swift`
- `Tests/SongbirdTests/AggregateStateStreamTests.swift`

Confirm `Sources/Songbird/CategorySubscription.swift` and `Tests/SongbirdTests/CategorySubscriptionTests.swift` no longer exist.

**Step 4: Write changelog entry**

Create `changelog/0007-message-hierarchy.md`:

```markdown
# 0007 — Message Hierarchy, Store Generalization & Reactive Streams

Implemented Phase 6 of Songbird:

- **Message protocol** — Shared base protocol (`Sendable`, `Codable`, `Equatable`) unifying `Event` and `Command`. Both extend `Message` and provide `messageType` via their respective `eventType`/`commandType` properties.
- **Command update** — `Command.commandType` is now an instance property (was static), consistent with `Event.eventType`. Commands gain `Codable` and `Equatable` from `Message`.
- **EventStore.readCategories** — Replaces `readCategory` as the protocol requirement. Accepts `[String]` (empty = all events). Convenience extensions `readCategory` and `readAll` delegate to it. InMemoryEventStore uses Set-based filter. SQLiteEventStore uses dynamic SQL (no WHERE / single WHERE / WHERE IN).
- **EventSubscription** — Renamed from `CategorySubscription`. Accepts `categories: [String]` for multi-category or all-events subscriptions. Uses `readCategories` internally. Position persistence unchanged.
- **StreamSubscription** — New polling-based `AsyncSequence` for a single entity stream. No position persistence. Configurable start position, batch size, tick interval. Designed for reactive use.
- **AggregateStateStream** — Reactive `AsyncSequence` that yields aggregate state. Folds all existing events on first call, then polls for new events and yields updated state. Always yields at least one value (initialState for empty streams).

New test coverage: MessageTests (7), StreamSubscriptionTests (6), AggregateStateStreamTests (5), plus multi-category/all-events tests in EventSubscription and both event store test suites.
```

**Step 5: Commit and push**

```bash
git add changelog/0007-message-hierarchy.md
git commit -m "Add Phase 6 changelog entry"
git push
```
