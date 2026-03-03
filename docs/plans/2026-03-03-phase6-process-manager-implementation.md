# Phase 6: Reactive Streams & Process Manager Runtime -- Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Generalize the EventStore and subscription APIs to support multi-category and all-events reading, add reactive state streams for aggregates, and implement per-entity process managers with a runner actor. This phase builds bottom-up: foundation changes first, then reactive streams, then the process manager runtime.

**Architecture:** Generalize `readCategory` to `readCategories([String])` on the EventStore protocol. Rename `CategorySubscription` to `EventSubscription` with multi-category support. Add `StreamSubscription` for entity-level event following. Add `AggregateStateStream` and `ProcessStateStream` as reactive state projections. Implement `ProcessManagerRunner` actor that uses `EventSubscription` to drive per-entity process manager state machines, dispatching output commands via a user-provided closure.

**Tech Stack:** Swift 6.2+, macOS 14+, Swift Testing, AsyncSequence/AsyncIteratorProtocol, SQLite.swift

**Test command:** `swift test 2>&1`

**Build command:** `swift build 2>&1`

**Design doc:** `docs/plans/2026-03-03-phase6-process-manager-design.md`

---

### Task 1: EventStore protocol change (readCategory -> readCategories)

**Files:**
- Modify: `Sources/Songbird/EventStore.swift`
- Modify: `Sources/SongbirdTesting/InMemoryEventStore.swift`
- Modify: `Sources/SongbirdSQLite/SQLiteEventStore.swift`
- Modify: `Tests/SongbirdTestingTests/InMemoryEventStoreTests.swift`
- Modify: `Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift`

**Step 1: Write the new tests**

Add to the end of `Tests/SongbirdTestingTests/InMemoryEventStoreTests.swift`, inside the `InMemoryEventStoreTests` struct, before the closing brace:

```swift
    // MARK: - Read Categories (multi-category)

    @Test func readCategoriesWithMultipleCategories() async throws {
        let store = makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "invoice", id: "b")
        let s3 = StreamName(category: "other", id: "c")
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
        let s3 = StreamName(category: "other", id: "c")
        _ = try await store.append(AccountEvent.deposited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.deposited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.deposited(amount: 300), to: s3, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readAll(from: 0, maxCount: 100)
        #expect(events.count == 3)
        #expect(events[0].globalPosition == 0)
        #expect(events[1].globalPosition == 1)
        #expect(events[2].globalPosition == 2)
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
```

Add to the end of `Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift`, inside the `SQLiteEventStoreTests` struct, before the closing brace:

```swift
    // MARK: - Read Categories (multi-category)

    @Test func readCategoriesWithMultipleCategories() async throws {
        let store = try makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "invoice", id: "b")
        let s3 = StreamName(category: "other", id: "c")
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
        let s3 = StreamName(category: "other", id: "c")
        _ = try await store.append(AccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 300), to: s3, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readAll(from: 0, maxCount: 100)
        #expect(events.count == 3)
        #expect(events[0].globalPosition == 0)
        #expect(events[1].globalPosition == 1)
        #expect(events[2].globalPosition == 2)
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
```

**Step 2: Modify EventStore protocol**

Replace the entire contents of `Sources/Songbird/EventStore.swift` with:

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

With:
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

In `Sources/SongbirdSQLite/SQLiteEventStore.swift`, replace the `readCategory` method (the `// MARK: - Read Category` section) with `readCategories`:

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

With:
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
Expected: All existing tests pass (they call `readCategory` which is now a convenience extension that delegates to `readCategories`). New tests also pass. Zero warnings.

**Step 6: Commit**

```bash
git add Sources/Songbird/EventStore.swift Sources/SongbirdTesting/InMemoryEventStore.swift Sources/SongbirdSQLite/SQLiteEventStore.swift Tests/SongbirdTestingTests/InMemoryEventStoreTests.swift Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift
git commit -m "Generalize readCategory to readCategories on EventStore protocol

Replace readCategory with readCategories([String]) as the single protocol
requirement. Empty array reads all events, single-element reads one
category, multi-element uses WHERE IN. Convenience extensions provide
readCategory (single) and readAll for ergonomic call sites. All existing
readCategory call sites work unchanged via the extension. 6 new tests
for multi-category and read-all across InMemory and SQLite stores."
```

---

### Task 2: Rename CategorySubscription -> EventSubscription

**Files:**
- Delete: `Sources/Songbird/CategorySubscription.swift`
- Create: `Sources/Songbird/EventSubscription.swift`
- Delete: `Tests/SongbirdTests/CategorySubscriptionTests.swift`
- Create: `Tests/SongbirdTests/EventSubscriptionTests.swift`

**Step 1: Write the tests**

Create `Tests/SongbirdTests/EventSubscriptionTests.swift` (this replaces `CategorySubscriptionTests.swift` and adds multi-category + all-events tests):

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
        // After first batch (0,1,2) is exhausted, position 2 is saved.
        // Then second batch (3,4) starts yielding. We break after event 4.
        // Position 2 was saved when first batch was exhausted. Position 4 is NOT saved
        // yet because we broke before the iterator re-enters next().
        let savedPosition = try await positionStore.load(subscriberId: "test-sub")
        #expect(savedPosition != nil)
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

        // Append events across three categories
        let orderStream = StreamName(category: "order", id: "1")
        _ = try await eventStore.append(SubscriptionTestEvent.occurred(value: 1), to: orderStream, metadata: EventMetadata(), expectedVersion: nil)

        let invoiceStream = StreamName(category: "invoice", id: "1")
        _ = try await eventStore.append(SubscriptionTestEvent.occurred(value: 2), to: invoiceStream, metadata: EventMetadata(), expectedVersion: nil)

        let shipmentStream = StreamName(category: "shipment", id: "1")
        _ = try await eventStore.append(SubscriptionTestEvent.occurred(value: 3), to: shipmentStream, metadata: EventMetadata(), expectedVersion: nil)

        // Subscribe to order + invoice only
        let subscription = EventSubscription(
            subscriberId: "test-multi",
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
        #expect(received[0].streamName.category == "order")
        #expect(received[1].streamName.category == "invoice")
    }

    @Test func subscribesToAllEvents() async throws {
        let (eventStore, positionStore) = makeStores()

        let orderStream = StreamName(category: "order", id: "1")
        _ = try await eventStore.append(SubscriptionTestEvent.occurred(value: 1), to: orderStream, metadata: EventMetadata(), expectedVersion: nil)

        let invoiceStream = StreamName(category: "invoice", id: "1")
        _ = try await eventStore.append(SubscriptionTestEvent.occurred(value: 2), to: invoiceStream, metadata: EventMetadata(), expectedVersion: nil)

        let shipmentStream = StreamName(category: "shipment", id: "1")
        _ = try await eventStore.append(SubscriptionTestEvent.occurred(value: 3), to: shipmentStream, metadata: EventMetadata(), expectedVersion: nil)

        // Empty categories = subscribe to all
        let subscription = EventSubscription(
            subscriberId: "test-all",
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
        #expect(received[0].streamName.category == "order")
        #expect(received[1].streamName.category == "invoice")
        #expect(received[2].streamName.category == "shipment")
    }
}
```

**Step 2: Delete old files, create new file**

Delete `Sources/Songbird/CategorySubscription.swift` and `Tests/SongbirdTests/CategorySubscriptionTests.swift`.

Create `Sources/Songbird/EventSubscription.swift`:

```swift
import Foundation

/// A polling-based subscription that reads events from one or more categories as an `AsyncSequence`.
///
/// The subscription polls `EventStore.readCategories` in batches and yields events one at a time.
/// Position is persisted to a `PositionStore` after each batch is fully consumed, enabling
/// restartability. When caught up (no new events), the subscription sleeps for `tickInterval`
/// before polling again. The sequence ends when the enclosing `Task` is cancelled.
///
/// - Pass one or more categories to subscribe to specific event streams.
/// - Pass an empty array to subscribe to all events across all categories.
///
/// Usage:
/// ```swift
/// let subscription = EventSubscription(
///     subscriberId: "order-projector",
///     categories: ["order"],
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

**Step 3: Run tests**

Run: `swift test 2>&1`
Expected: All tests pass, zero warnings. The old `CategorySubscriptionTests` are gone; the new `EventSubscriptionTests` cover the same cases plus multi-category and all-events.

**Step 4: Commit**

```bash
git rm Sources/Songbird/CategorySubscription.swift Tests/SongbirdTests/CategorySubscriptionTests.swift
git add Sources/Songbird/EventSubscription.swift Tests/SongbirdTests/EventSubscriptionTests.swift
git commit -m "Rename CategorySubscription to EventSubscription with multi-category support

Accept categories: [String] instead of category: String. Empty array
subscribes to all events. Uses readCategories internally. All original
test cases preserved plus 2 new tests for multi-category and all-events
subscription."
```

---

### Task 3: StreamSubscription (entity-level)

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

enum StreamSubTestEvent: Event {
    case happened(value: Int)

    var eventType: String {
        switch self {
        case .happened: "Happened"
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

    let stream = StreamName(category: "thing", id: "1")

    func makeStore() -> InMemoryEventStore {
        let registry = EventTypeRegistry()
        registry.register(StreamSubTestEvent.self, eventTypes: ["Happened"])
        return InMemoryEventStore(registry: registry)
    }

    func appendEvents(to store: InMemoryEventStore, stream: StreamName, count: Int) async throws {
        for i in 0..<count {
            _ = try await store.append(
                StreamSubTestEvent.happened(value: i),
                to: stream,
                metadata: EventMetadata(),
                expectedVersion: nil
            )
        }
    }

    // MARK: - Basic Consumption

    @Test func yieldsEventsFromStream() async throws {
        let store = makeStore()
        try await appendEvents(to: store, stream: stream, count: 3)

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

    @Test func startsFromGivenPosition() async throws {
        let store = makeStore()
        try await appendEvents(to: store, stream: stream, count: 5)

        let subscription = StreamSubscription(
            stream: stream,
            store: store,
            startPosition: 3,
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
        #expect(received[0].position == 3)
        #expect(received[1].position == 4)
    }

    @Test func onlyYieldsEventsFromTargetStream() async throws {
        let store = makeStore()
        let otherStream = StreamName(category: "thing", id: "2")

        _ = try await store.append(StreamSubTestEvent.happened(value: 1), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(StreamSubTestEvent.happened(value: 2), to: otherStream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(StreamSubTestEvent.happened(value: 3), to: stream, metadata: EventMetadata(), expectedVersion: nil)

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

    // MARK: - Polling

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

        // Give polling time to run with an empty stream
        try await Task.sleep(for: .milliseconds(30))
        let earlyCount = await collector.count
        #expect(earlyCount == 0)

        // Now append events
        try await appendEvents(to: store, stream: stream, count: 2)

        try await task.value
        let finalCount = await collector.count
        #expect(finalCount == 2)
    }

    // MARK: - Cancellation

    @Test func stopsOnCancellation() async throws {
        let store = makeStore()
        try await appendEvents(to: store, stream: stream, count: 2)

        let subscription = StreamSubscription(
            stream: stream,
            store: store,
            tickInterval: .milliseconds(10)
        )

        let collector = StreamEventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                // Don't break -- poll forever
            }
        }

        // Let it consume existing events
        try await Task.sleep(for: .milliseconds(50))

        task.cancel()

        let result = await task.result
        switch result {
        case .success:
            break
        case .failure(let error):
            #expect(error is CancellationError)
        }
        let count = await collector.count
        #expect(count == 2)
    }
}
```

**Step 2: Implement StreamSubscription**

Create `Sources/Songbird/StreamSubscription.swift`:

```swift
import Foundation

/// A polling-based subscription that reads events from a single stream as an `AsyncSequence`.
///
/// Unlike `EventSubscription`, this does not persist position -- it is intended for short-lived
/// reactive streams (e.g., observing an aggregate's events to build a live state projection).
/// Starts from a given position (default 0) and polls `EventStore.readStream` for new events.
/// The sequence ends when the enclosing `Task` is cancelled.
///
/// Usage:
/// ```swift
/// let subscription = StreamSubscription(
///     stream: StreamName(category: "order", id: "123"),
///     store: eventStore
/// )
///
/// for try await event in subscription {
///     // process event
/// }
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
git commit -m "Add StreamSubscription for entity-level event following

Polling-based AsyncSequence for a single StreamName. No position
persistence -- intended for reactive state streams. Starts from a
configurable position, polls readStream in batches. 5 tests covering
consumption, start position, stream isolation, polling, and
cancellation."
```

---

### Task 4: AggregateStateStream

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

// MARK: - Test Aggregate for State Stream

enum BalanceEvent: Event {
    case credited(amount: Int)
    case debited(amount: Int)

    var eventType: String {
        switch self {
        case .credited: "BalanceCredited"
        case .debited: "BalanceDebited"
        }
    }
}

enum BalanceAggregate: Aggregate {
    struct State: Sendable, Equatable {
        var balance: Int = 0
    }

    typealias Event = BalanceEvent
    enum Failure: Error { case insufficientFunds }

    static let category = "balance"
    static let initialState = State()

    static func apply(_ state: State, _ event: BalanceEvent) -> State {
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
        registry.register(BalanceEvent.self, eventTypes: ["BalanceCredited", "BalanceDebited"])
        return (InMemoryEventStore(registry: registry), registry)
    }

    let stream = StreamName(category: "balance", id: "acct-1")

    // MARK: - Initial State

    @Test func yieldsInitialStateOnEmptyStream() async throws {
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

    @Test func yieldsStateAfterFoldingExistingEvents() async throws {
        let (store, registry) = makeStore()

        _ = try await store.append(BalanceEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(BalanceEvent.debited(amount: 30), to: stream, metadata: EventMetadata(), expectedVersion: nil)

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

    // MARK: - Live Updates

    @Test func yieldsUpdatedStateOnNewEvents() async throws {
        let (store, registry) = makeStore()

        _ = try await store.append(BalanceEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)

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
                if await collector.count == 2 { break }
            }
        }

        // Wait for initial state to be yielded
        try await Task.sleep(for: .milliseconds(30))

        // Append a new event
        _ = try await store.append(BalanceEvent.credited(amount: 50), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        try await task.value
        let states = await collector.states
        #expect(states.count == 2)
        #expect(states[0] == BalanceAggregate.State(balance: 100))
        #expect(states[1] == BalanceAggregate.State(balance: 150))
    }

    @Test func foldsMultipleNewEventsSequentially() async throws {
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
                // Initial state + 3 updates = 4
                if await collector.count == 4 { break }
            }
        }

        // Wait for initial (empty) state
        try await Task.sleep(for: .milliseconds(30))

        // Append three events
        _ = try await store.append(BalanceEvent.credited(amount: 10), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(BalanceEvent.credited(amount: 20), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(BalanceEvent.debited(amount: 5), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        try await task.value
        let states = await collector.states
        #expect(states.count == 4)
        #expect(states[0] == BalanceAggregate.State(balance: 0))   // initial
        #expect(states[1] == BalanceAggregate.State(balance: 10))  // +10
        #expect(states[2] == BalanceAggregate.State(balance: 30))  // +20
        #expect(states[3] == BalanceAggregate.State(balance: 25))  // -5
    }

    // MARK: - Cancellation

    @Test func stopsOnCancellation() async throws {
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
            }
        }

        // Let it yield the initial state
        try await Task.sleep(for: .milliseconds(50))

        task.cancel()

        let result = await task.result
        switch result {
        case .success:
            break
        case .failure(let error):
            #expect(error is CancellationError)
        }
        let count = await collector.count
        #expect(count >= 1)  // at least the initial state
    }
}
```

**Step 2: Implement AggregateStateStream**

Create `Sources/Songbird/AggregateStateStream.swift`:

```swift
import Foundation

/// A reactive `AsyncSequence` that yields the current state of an aggregate, updating on each new event.
///
/// On the first iteration, reads all existing events from the aggregate's stream, folds them
/// through `A.apply` to produce the current state, and yields it. Then polls for new events
/// and yields updated state after each one. The stream does not persist position -- it rebuilds
/// state from the beginning each time it is created.
///
/// Usage:
/// ```swift
/// let stateStream = AggregateStateStream<OrderAggregate>(
///     id: "order-123",
///     store: eventStore,
///     registry: registry
/// )
///
/// for try await state in stateStream {
///     print("Current state: \(state)")
/// }
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
        private var initialized: Bool = false

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
            try Task.checkCancellation()

            // First call: fold all existing events and yield initial state
            if !initialized {
                initialized = true

                // Read all existing events in batches
                while true {
                    let batch = try await store.readStream(stream, from: position, maxCount: batchSize)
                    for record in batch {
                        let decoded = try registry.decode(record)
                        if let event = decoded as? A.Event {
                            state = A.apply(state, event)
                        }
                    }
                    if batch.isEmpty {
                        break
                    }
                    position = batch[batch.count - 1].position + 1
                }

                return state
            }

            // Subsequent calls: poll for new events
            while !Task.isCancelled {
                try Task.checkCancellation()

                let batch = try await store.readStream(stream, from: position, maxCount: batchSize)

                for record in batch {
                    let decoded = try registry.decode(record)
                    if let event = decoded as? A.Event {
                        state = A.apply(state, event)
                    }
                    position = record.position + 1
                }

                if !batch.isEmpty {
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

AsyncSequence that yields aggregate state by folding events through
A.apply. First iteration loads all existing events and yields the
current state. Subsequent iterations poll for new events and yield
updated state. 5 tests covering empty stream, existing events, live
updates, multi-event folding, and cancellation."
```

---

### Task 5: ProcessManager protocol update + ProcessManagerRunner

**Files:**
- Modify: `Sources/Songbird/ProcessManager.swift`
- Create: `Sources/Songbird/ProcessManagerRunner.swift`
- Modify: `Tests/SongbirdTests/ProcessManagerTests.swift`

**Step 1: Write the tests**

Replace the entire contents of `Tests/SongbirdTests/ProcessManagerTests.swift` with:

```swift
import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

// MARK: - Test Domain

enum OrderPlacedEvent: Event {
    case placed(orderId: String, amount: Int)

    var eventType: String {
        switch self {
        case .placed: "OrderPlaced"
        }
    }
}

enum PaymentReceivedEvent: Event {
    case received(orderId: String, amount: Int)

    var eventType: String {
        switch self {
        case .received: "PaymentReceived"
        }
    }
}

enum ShipOrderCommand: Command {
    static let commandType = "ShipOrder"
    case ship(orderId: String)
}

enum FulfillmentProcess: ProcessManager {
    struct State: Sendable, Equatable {
        var orderPlaced: Bool = false
        var paymentReceived: Bool = false
        var amount: Int = 0
    }

    enum InputEvent: Event {
        case orderPlaced(orderId: String, amount: Int)
        case paymentReceived(orderId: String, amount: Int)

        var eventType: String {
            switch self {
            case .orderPlaced: "OrderPlaced"
            case .paymentReceived: "PaymentReceived"
            }
        }
    }

    typealias OutputCommand = ShipOrderCommand

    static let processId = "fulfillment"
    static let initialState = State()
    static let categories = ["order", "payment"]

    static func apply(_ state: State, _ event: InputEvent) -> State {
        switch event {
        case .orderPlaced(_, let amount):
            State(orderPlaced: true, paymentReceived: state.paymentReceived, amount: amount)
        case .paymentReceived(_, let amount):
            State(orderPlaced: state.orderPlaced, paymentReceived: true, amount: amount)
        }
    }

    static func commands(_ state: State, _ event: InputEvent) -> [ShipOrderCommand] {
        // Only ship when both order and payment are received
        if state.orderPlaced && state.paymentReceived {
            switch event {
            case .orderPlaced(let orderId, _):
                return [.ship(orderId: orderId)]
            case .paymentReceived(let orderId, _):
                return [.ship(orderId: orderId)]
            }
        }
        return []
    }

    static func route(_ event: RecordedEvent) -> String? {
        // Route by extracting the stream ID as the process instance ID
        event.streamName.id
    }

    static func decodeEvent(_ recorded: RecordedEvent) throws -> InputEvent {
        try JSONDecoder().decode(InputEvent.self, from: recorded.data)
    }
}

// MARK: - Protocol Tests

@Suite("ProcessManager Protocol")
struct ProcessManagerProtocolTests {
    @Test func processIdIsAccessible() {
        #expect(FulfillmentProcess.processId == "fulfillment")
    }

    @Test func categoriesAreAccessible() {
        #expect(FulfillmentProcess.categories == ["order", "payment"])
    }

    @Test func applyUpdatesState() {
        let state = FulfillmentProcess.apply(
            FulfillmentProcess.initialState,
            .orderPlaced(orderId: "o1", amount: 100)
        )
        #expect(state.orderPlaced == true)
        #expect(state.paymentReceived == false)
        #expect(state.amount == 100)
    }

    @Test func commandsProducesOutputWhenConditionsMet() {
        let state = FulfillmentProcess.State(orderPlaced: true, paymentReceived: true, amount: 100)
        let commands = FulfillmentProcess.commands(
            state,
            .paymentReceived(orderId: "o1", amount: 100)
        )
        #expect(commands.count == 1)
    }

    @Test func commandsProducesNoOutputWhenConditionsNotMet() {
        let state = FulfillmentProcess.State(orderPlaced: true, paymentReceived: false, amount: 100)
        let commands = FulfillmentProcess.commands(
            state,
            .orderPlaced(orderId: "o1", amount: 100)
        )
        #expect(commands.isEmpty)
    }

    @Test func routeExtractsInstanceId() {
        let event = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "order", id: "o-123"),
            position: 0,
            globalPosition: 0,
            eventType: "OrderPlaced",
            data: Data(),
            metadata: EventMetadata(),
            timestamp: Date()
        )
        let instanceId = FulfillmentProcess.route(event)
        #expect(instanceId == "o-123")
    }
}

// MARK: - ProcessManagerRunner Tests

/// Actor to collect commands emitted by the runner.
private actor CommandCollector {
    private(set) var commands: [(command: ShipOrderCommand, instanceId: String)] = []

    func append(_ command: ShipOrderCommand, instanceId: String) {
        commands.append((command, instanceId))
    }

    var count: Int { commands.count }
}

@Suite("ProcessManagerRunner")
struct ProcessManagerRunnerTests {

    func makeStores() -> (InMemoryEventStore, InMemoryPositionStore, EventTypeRegistry) {
        let registry = EventTypeRegistry()
        registry.register(FulfillmentProcess.InputEvent.self, eventTypes: ["OrderPlaced", "PaymentReceived"])
        let store = InMemoryEventStore(registry: registry)
        let positionStore = InMemoryPositionStore()
        return (store, positionStore, registry)
    }

    @Test func processesEventsAndEmitsCommands() async throws {
        let (store, positionStore, _) = makeStores()

        let commandCollector = CommandCollector()
        let runner = ProcessManagerRunner<FulfillmentProcess>(
            store: store,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        ) { command, instanceId in
            await commandCollector.append(command, instanceId: instanceId)
        }

        let runTask = Task { try await runner.run() }

        // Append order placed for order o1
        let orderStream = StreamName(category: "order", id: "o1")
        _ = try await store.append(
            FulfillmentProcess.InputEvent.orderPlaced(orderId: "o1", amount: 100),
            to: orderStream,
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Give runner time to process
        try await Task.sleep(for: .milliseconds(50))

        // No command yet -- payment not received
        let earlyCount = await commandCollector.count
        #expect(earlyCount == 0)

        // Append payment received for same process instance
        let paymentStream = StreamName(category: "payment", id: "o1")
        _ = try await store.append(
            FulfillmentProcess.InputEvent.paymentReceived(orderId: "o1", amount: 100),
            to: paymentStream,
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Give runner time to process
        try await Task.sleep(for: .milliseconds(50))

        let finalCount = await commandCollector.count
        #expect(finalCount == 1)

        let commands = await commandCollector.commands
        #expect(commands[0].instanceId == "o1")

        await runner.stop()
        runTask.cancel()
    }

    @Test func handlesMultipleProcessInstances() async throws {
        let (store, positionStore, _) = makeStores()

        let commandCollector = CommandCollector()
        let runner = ProcessManagerRunner<FulfillmentProcess>(
            store: store,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        ) { command, instanceId in
            await commandCollector.append(command, instanceId: instanceId)
        }

        let runTask = Task { try await runner.run() }

        // Order o1: place + pay
        let orderStream1 = StreamName(category: "order", id: "o1")
        _ = try await store.append(
            FulfillmentProcess.InputEvent.orderPlaced(orderId: "o1", amount: 50),
            to: orderStream1,
            metadata: EventMetadata(),
            expectedVersion: nil
        )
        let paymentStream1 = StreamName(category: "payment", id: "o1")
        _ = try await store.append(
            FulfillmentProcess.InputEvent.paymentReceived(orderId: "o1", amount: 50),
            to: paymentStream1,
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Order o2: place only (no payment yet)
        let orderStream2 = StreamName(category: "order", id: "o2")
        _ = try await store.append(
            FulfillmentProcess.InputEvent.orderPlaced(orderId: "o2", amount: 75),
            to: orderStream2,
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        try await Task.sleep(for: .milliseconds(100))

        let count = await commandCollector.count
        #expect(count == 1)  // Only o1 should have a command

        let commands = await commandCollector.commands
        #expect(commands[0].instanceId == "o1")

        await runner.stop()
        runTask.cancel()
    }

    @Test func skipsEventsWithNilRoute() async throws {
        // Define a process manager that only routes certain events
        enum SelectiveProcess: ProcessManager {
            struct State: Sendable, Equatable { var count: Int = 0 }
            enum InputEvent: Event {
                case relevant(id: String)
                var eventType: String { "Relevant" }
            }
            struct Noop: Command { static let commandType = "Noop" }
            typealias OutputCommand = Noop

            static let processId = "selective"
            static let initialState = State()
            static let categories = ["test"]

            static func apply(_ state: State, _ event: InputEvent) -> State {
                State(count: state.count + 1)
            }

            static func commands(_ state: State, _ event: InputEvent) -> [Noop] {
                []
            }

            static func route(_ event: RecordedEvent) -> String? {
                // Only route events from streams with id starting with "routed"
                if let id = event.streamName.id, id.hasPrefix("routed") {
                    return id
                }
                return nil
            }

            static func decodeEvent(_ recorded: RecordedEvent) throws -> InputEvent {
                try JSONDecoder().decode(InputEvent.self, from: recorded.data)
            }
        }

        let registry = EventTypeRegistry()
        registry.register(SelectiveProcess.InputEvent.self, eventTypes: ["Relevant"])
        let store = InMemoryEventStore(registry: registry)
        let positionStore = InMemoryPositionStore()

        let runner = ProcessManagerRunner<SelectiveProcess>(
            store: store,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        ) { _, _ in }

        let runTask = Task { try await runner.run() }

        // This event should be skipped (route returns nil)
        let skippedStream = StreamName(category: "test", id: "ignored-1")
        _ = try await store.append(
            SelectiveProcess.InputEvent.relevant(id: "ignored-1"),
            to: skippedStream,
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // This event should be processed
        let routedStream = StreamName(category: "test", id: "routed-1")
        _ = try await store.append(
            SelectiveProcess.InputEvent.relevant(id: "routed-1"),
            to: routedStream,
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        try await Task.sleep(for: .milliseconds(50))

        // Runner should have processed without error
        await runner.stop()
        runTask.cancel()

        // If we got here, the runner handled nil route correctly
    }

    @Test func stopsCleanly() async throws {
        let (store, positionStore, _) = makeStores()

        let runner = ProcessManagerRunner<FulfillmentProcess>(
            store: store,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        ) { _, _ in }

        let runTask = Task { try await runner.run() }

        try await Task.sleep(for: .milliseconds(30))

        await runner.stop()
        runTask.cancel()

        let result = await runTask.result
        switch result {
        case .success:
            break
        case .failure(let error):
            #expect(error is CancellationError)
        }
    }
}
```

**Step 2: Update ProcessManager protocol**

Replace the entire contents of `Sources/Songbird/ProcessManager.swift` with:

```swift
import Foundation

public protocol ProcessManager {
    associatedtype State: Sendable
    associatedtype InputEvent: Event
    associatedtype OutputCommand: Command

    static var processId: String { get }
    static var initialState: State { get }
    static var categories: [String] { get }

    static func apply(_ state: State, _ event: InputEvent) -> State
    static func commands(_ state: State, _ event: InputEvent) -> [OutputCommand]
    static func route(_ event: RecordedEvent) -> String?
    static func decodeEvent(_ recorded: RecordedEvent) throws -> InputEvent
}
```

**Step 3: Implement ProcessManagerRunner**

Create `Sources/Songbird/ProcessManagerRunner.swift`:

```swift
import Foundation

/// Runs a `ProcessManager` by subscribing to its event categories, routing events to per-instance
/// state machines, and dispatching output commands via a user-provided handler.
///
/// The runner maintains an in-memory cache of process instance states. For each event:
/// 1. `PM.route(event)` determines the process instance ID (nil = skip).
/// 2. The instance's state is loaded from cache (or initialized to `PM.initialState`).
/// 3. `PM.decodeEvent(event)` decodes the raw event.
/// 4. `PM.apply(state, event)` produces the new state.
/// 5. `PM.commands(newState, event)` produces output commands.
/// 6. Each command is passed to the `commandHandler` closure.
///
/// Position is persisted via `PositionStore` using the process manager's `processId` as the
/// subscriber ID, enabling restartable processing across restarts.
///
/// Usage:
/// ```swift
/// let runner = ProcessManagerRunner<FulfillmentProcess>(
///     store: eventStore,
///     positionStore: positionStore
/// ) { command, instanceId in
///     // Execute the command (e.g., via an AggregateRepository)
/// }
///
/// let task = Task { try await runner.run() }
///
/// // Later:
/// await runner.stop()
/// ```
public actor ProcessManagerRunner<PM: ProcessManager> {
    private let store: any EventStore
    private let positionStore: any PositionStore
    private let batchSize: Int
    private let tickInterval: Duration
    private let commandHandler: @Sendable (PM.OutputCommand, String) async throws -> Void
    private var instanceStates: [String: PM.State] = [:]
    private var stopped: Bool = false

    public init(
        store: any EventStore,
        positionStore: any PositionStore,
        batchSize: Int = 100,
        tickInterval: Duration = .milliseconds(100),
        commandHandler: @escaping @Sendable (PM.OutputCommand, String) async throws -> Void
    ) {
        self.store = store
        self.positionStore = positionStore
        self.batchSize = batchSize
        self.tickInterval = tickInterval
        self.commandHandler = commandHandler
    }

    public func run() async throws {
        let subscription = EventSubscription(
            subscriberId: PM.processId,
            categories: PM.categories,
            store: store,
            positionStore: positionStore,
            batchSize: batchSize,
            tickInterval: tickInterval
        )

        for try await event in subscription {
            if stopped { break }

            // Route event to process instance
            guard let instanceId = PM.route(event) else {
                continue
            }

            // Get or create instance state
            let currentState = instanceStates[instanceId] ?? PM.initialState

            // Decode and apply
            let decodedEvent = try PM.decodeEvent(event)
            let newState = PM.apply(currentState, decodedEvent)
            instanceStates[instanceId] = newState

            // Emit commands
            let commands = PM.commands(newState, decodedEvent)
            for command in commands {
                try await commandHandler(command, instanceId)
            }
        }
    }

    public func stop() {
        stopped = true
    }
}
```

**Step 4: Run tests**

Run: `swift test 2>&1`
Expected: All tests pass, zero warnings.

**Step 5: Commit**

```bash
git add Sources/Songbird/ProcessManager.swift Sources/Songbird/ProcessManagerRunner.swift Tests/SongbirdTests/ProcessManagerTests.swift
git commit -m "Update ProcessManager protocol and add ProcessManagerRunner

Add categories, route, and decodeEvent to ProcessManager protocol.
ProcessManagerRunner actor uses EventSubscription to poll for events,
routes to per-instance state machines, folds state via apply, and
dispatches output commands via a user-provided closure. 9 tests
covering protocol conformance, command emission, multi-instance
handling, nil route skipping, and clean shutdown."
```

---

### Task 6: ProcessStateStream

**Files:**
- Create: `Sources/Songbird/ProcessStateStream.swift`
- Create: `Tests/SongbirdTests/ProcessStateStreamTests.swift`

**Step 1: Write the tests**

Create `Tests/SongbirdTests/ProcessStateStreamTests.swift`:

```swift
import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

// MARK: - Test Process Manager for State Stream

enum TicketEvent: Event {
    case created(title: String)
    case assigned(to: String)
    case resolved

    var eventType: String {
        switch self {
        case .created: "TicketCreated"
        case .assigned: "TicketAssigned"
        case .resolved: "TicketResolved"
        }
    }
}

struct EscalateCommand: Command {
    static let commandType = "Escalate"
}

enum TicketProcess: ProcessManager {
    struct State: Sendable, Equatable {
        var created: Bool = false
        var assignee: String? = nil
        var resolved: Bool = false
    }

    typealias InputEvent = TicketEvent
    typealias OutputCommand = EscalateCommand

    static let processId = "ticket-workflow"
    static let initialState = State()
    static let categories = ["ticket"]

    static func apply(_ state: State, _ event: TicketEvent) -> State {
        switch event {
        case .created:
            State(created: true, assignee: state.assignee, resolved: state.resolved)
        case .assigned(let to):
            State(created: state.created, assignee: to, resolved: state.resolved)
        case .resolved:
            State(created: state.created, assignee: state.assignee, resolved: true)
        }
    }

    static func commands(_ state: State, _ event: TicketEvent) -> [EscalateCommand] {
        []
    }

    static func route(_ event: RecordedEvent) -> String? {
        event.streamName.id
    }

    static func decodeEvent(_ recorded: RecordedEvent) throws -> TicketEvent {
        try JSONDecoder().decode(TicketEvent.self, from: recorded.data)
    }
}

/// Actor to safely collect states across task boundaries in tests.
private actor ProcessStateCollector<S: Sendable> {
    private(set) var states: [S] = []

    func append(_ state: S) {
        states.append(state)
    }

    var count: Int { states.count }
}

@Suite("ProcessStateStream")
struct ProcessStateStreamTests {

    let stream = StreamName(category: "ticket", id: "t-1")

    func makeStore() -> (InMemoryEventStore, EventTypeRegistry) {
        let registry = EventTypeRegistry()
        registry.register(TicketEvent.self, eventTypes: ["TicketCreated", "TicketAssigned", "TicketResolved"])
        return (InMemoryEventStore(registry: registry), registry)
    }

    // MARK: - Initial State

    @Test func yieldsInitialStateOnEmptyStream() async throws {
        let (store, registry) = makeStore()

        let stateStream = ProcessStateStream<TicketProcess>(
            processInstanceId: "t-1",
            categories: TicketProcess.categories,
            store: store,
            registry: registry,
            tickInterval: .milliseconds(10)
        )

        let collector = ProcessStateCollector<TicketProcess.State>()
        let task = Task {
            for try await state in stateStream {
                await collector.append(state)
                if await collector.count == 1 { break }
            }
        }

        try await task.value
        let states = await collector.states
        #expect(states.count == 1)
        #expect(states[0] == TicketProcess.initialState)
    }

    @Test func yieldsStateAfterFoldingExistingEvents() async throws {
        let (store, registry) = makeStore()

        _ = try await store.append(TicketEvent.created(title: "Bug"), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(TicketEvent.assigned(to: "Alice"), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let stateStream = ProcessStateStream<TicketProcess>(
            processInstanceId: "t-1",
            categories: TicketProcess.categories,
            store: store,
            registry: registry,
            tickInterval: .milliseconds(10)
        )

        let collector = ProcessStateCollector<TicketProcess.State>()
        let task = Task {
            for try await state in stateStream {
                await collector.append(state)
                if await collector.count == 1 { break }
            }
        }

        try await task.value
        let states = await collector.states
        #expect(states.count == 1)
        #expect(states[0] == TicketProcess.State(created: true, assignee: "Alice", resolved: false))
    }

    // MARK: - Live Updates

    @Test func yieldsUpdatedStateOnNewEvents() async throws {
        let (store, registry) = makeStore()

        _ = try await store.append(TicketEvent.created(title: "Bug"), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let stateStream = ProcessStateStream<TicketProcess>(
            processInstanceId: "t-1",
            categories: TicketProcess.categories,
            store: store,
            registry: registry,
            tickInterval: .milliseconds(10)
        )

        let collector = ProcessStateCollector<TicketProcess.State>()
        let task = Task {
            for try await state in stateStream {
                await collector.append(state)
                if await collector.count == 3 { break }
            }
        }

        // Wait for initial state to be yielded
        try await Task.sleep(for: .milliseconds(30))

        _ = try await store.append(TicketEvent.assigned(to: "Bob"), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        try await Task.sleep(for: .milliseconds(30))

        _ = try await store.append(TicketEvent.resolved, to: stream, metadata: EventMetadata(), expectedVersion: nil)

        try await task.value
        let states = await collector.states
        #expect(states.count == 3)
        #expect(states[0] == TicketProcess.State(created: true, assignee: nil, resolved: false))
        #expect(states[1] == TicketProcess.State(created: true, assignee: "Bob", resolved: false))
        #expect(states[2] == TicketProcess.State(created: true, assignee: "Bob", resolved: true))
    }

    // MARK: - Cross-Stream Routing

    @Test func onlyFoldsEventsForTargetInstance() async throws {
        let (store, registry) = makeStore()

        let stream1 = StreamName(category: "ticket", id: "t-1")
        let stream2 = StreamName(category: "ticket", id: "t-2")

        _ = try await store.append(TicketEvent.created(title: "Bug 1"), to: stream1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(TicketEvent.created(title: "Bug 2"), to: stream2, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(TicketEvent.assigned(to: "Alice"), to: stream1, metadata: EventMetadata(), expectedVersion: nil)

        let stateStream = ProcessStateStream<TicketProcess>(
            processInstanceId: "t-1",
            categories: TicketProcess.categories,
            store: store,
            registry: registry,
            tickInterval: .milliseconds(10)
        )

        let collector = ProcessStateCollector<TicketProcess.State>()
        let task = Task {
            for try await state in stateStream {
                await collector.append(state)
                if await collector.count == 1 { break }
            }
        }

        try await task.value
        let states = await collector.states
        #expect(states.count == 1)
        // Should only include t-1's events, not t-2's
        #expect(states[0] == TicketProcess.State(created: true, assignee: "Alice", resolved: false))
    }

    // MARK: - Cancellation

    @Test func stopsOnCancellation() async throws {
        let (store, registry) = makeStore()

        let stateStream = ProcessStateStream<TicketProcess>(
            processInstanceId: "t-1",
            categories: TicketProcess.categories,
            store: store,
            registry: registry,
            tickInterval: .milliseconds(10)
        )

        let collector = ProcessStateCollector<TicketProcess.State>()
        let task = Task {
            for try await state in stateStream {
                await collector.append(state)
            }
        }

        // Let it yield initial state
        try await Task.sleep(for: .milliseconds(50))

        task.cancel()

        let result = await task.result
        switch result {
        case .success:
            break
        case .failure(let error):
            #expect(error is CancellationError)
        }
        let count = await collector.count
        #expect(count >= 1)  // at least the initial state
    }
}
```

**Step 2: Implement ProcessStateStream**

Create `Sources/Songbird/ProcessStateStream.swift`:

```swift
import Foundation

/// A reactive `AsyncSequence` that yields the current state of a process manager instance,
/// updating on each new event that routes to this instance.
///
/// On the first iteration, reads all existing events from the process manager's categories,
/// filters for events routed to the target instance, folds them through `PM.apply` to produce
/// the current state, and yields it. Then polls for new events and yields updated state when
/// relevant events arrive.
///
/// The stream does not persist position -- it rebuilds state from the beginning each time.
///
/// Usage:
/// ```swift
/// let stateStream = ProcessStateStream<FulfillmentProcess>(
///     processInstanceId: "order-123",
///     categories: FulfillmentProcess.categories,
///     store: eventStore,
///     registry: registry
/// )
///
/// for try await state in stateStream {
///     print("Process state: \(state)")
/// }
/// ```
public struct ProcessStateStream<PM: ProcessManager>: AsyncSequence, Sendable {
    public typealias Element = PM.State

    public let processInstanceId: String
    public let categories: [String]
    public let store: any EventStore
    public let registry: EventTypeRegistry
    public let batchSize: Int
    public let tickInterval: Duration

    public init(
        processInstanceId: String,
        categories: [String],
        store: any EventStore,
        registry: EventTypeRegistry,
        batchSize: Int = 100,
        tickInterval: Duration = .milliseconds(100)
    ) {
        self.processInstanceId = processInstanceId
        self.categories = categories
        self.store = store
        self.registry = registry
        self.batchSize = batchSize
        self.tickInterval = tickInterval
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(
            processInstanceId: processInstanceId,
            categories: categories,
            store: store,
            registry: registry,
            batchSize: batchSize,
            tickInterval: tickInterval
        )
    }

    public struct Iterator: AsyncIteratorProtocol {
        let processInstanceId: String
        let categories: [String]
        let store: any EventStore
        let registry: EventTypeRegistry
        let batchSize: Int
        let tickInterval: Duration
        private var state: PM.State = PM.initialState
        private var globalPosition: Int64 = 0
        private var initialized: Bool = false

        init(
            processInstanceId: String,
            categories: [String],
            store: any EventStore,
            registry: EventTypeRegistry,
            batchSize: Int,
            tickInterval: Duration
        ) {
            self.processInstanceId = processInstanceId
            self.categories = categories
            self.store = store
            self.registry = registry
            self.batchSize = batchSize
            self.tickInterval = tickInterval
        }

        public mutating func next() async throws -> PM.State? {
            try Task.checkCancellation()

            // First call: fold all existing events and yield initial state
            if !initialized {
                initialized = true

                // Read all existing events in batches
                while true {
                    let batch = try await store.readCategories(categories, from: globalPosition, maxCount: batchSize)
                    for record in batch {
                        if PM.route(record) == processInstanceId {
                            let decoded = try PM.decodeEvent(record)
                            state = PM.apply(state, decoded)
                        }
                    }
                    if batch.isEmpty {
                        break
                    }
                    globalPosition = batch[batch.count - 1].globalPosition + 1
                }

                return state
            }

            // Subsequent calls: poll for new events
            while !Task.isCancelled {
                try Task.checkCancellation()

                let batch = try await store.readCategories(categories, from: globalPosition, maxCount: batchSize)

                var stateChanged = false
                for record in batch {
                    if PM.route(record) == processInstanceId {
                        let decoded = try PM.decodeEvent(record)
                        state = PM.apply(state, decoded)
                        stateChanged = true
                    }
                    globalPosition = record.globalPosition + 1
                }

                if stateChanged {
                    return state
                }

                if batch.isEmpty {
                    // Caught up -- sleep before polling again
                    try await Task.sleep(for: tickInterval)
                }
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
git add Sources/Songbird/ProcessStateStream.swift Tests/SongbirdTests/ProcessStateStreamTests.swift
git commit -m "Add ProcessStateStream for reactive process instance state observation

AsyncSequence that yields process manager instance state by filtering
events from the PM's categories by route, decoding, and folding through
PM.apply. First iteration loads existing events, subsequent iterations
poll for new ones. 5 tests covering empty stream, existing events, live
updates, cross-stream instance isolation, and cancellation."
```

---

### Task 7: Final review, changelog, push

**Step 1: Verify clean build**

Run: `swift build 2>&1`
Expected: Build complete, zero warnings, zero errors.

**Step 2: Verify all tests pass**

Run: `swift test 2>&1`
Expected: All tests pass (should be around 141 total: 116 existing - 7 old CategorySubscription + 10 new EventSubscription + 6 new readCategories/readAll + 5 StreamSubscription + 5 AggregateStateStream + 9 ProcessManager + 5 ProcessStateStream = ~149, but the old ProcessManager tests (3) are replaced by the new ones (5 protocol + 4 runner), so net is ~148).

**Step 3: Write changelog entry**

Create `changelog/0007-process-manager-runtime.md`:

```markdown
# 0007 -- Process Manager Runtime

Implemented Phase 6 of Songbird: Reactive Streams & Process Manager Runtime.

## Foundation Changes

- **EventStore.readCategories** -- Generalized `readCategory` to `readCategories([String])` as the single protocol requirement. Empty array reads all events, single-element reads one category, multi-element uses SQL WHERE IN. Convenience extensions provide `readCategory` (single) and `readAll` for ergonomic call sites.
- **EventSubscription** -- Renamed from `CategorySubscription`. Accepts `categories: [String]` instead of `category: String`. Empty array subscribes to all events. Uses `readCategories` internally.
- **StreamSubscription** -- New polling-based `AsyncSequence<RecordedEvent>` for a single `StreamName`. No position persistence. Intended for reactive state streams.

## Reactive State Streams

- **AggregateStateStream** -- `AsyncSequence<A.State>` that yields aggregate state by folding events through `A.apply`. First iteration loads all existing events, subsequent iterations poll for new ones.
- **ProcessStateStream** -- `AsyncSequence<PM.State>` for a specific process instance. Filters events from PM categories by route, decodes, and folds through `PM.apply`.

## Process Manager Runtime

- **ProcessManager protocol** -- Added `categories`, `route(_:)`, and `decodeEvent(_:)` to the protocol. `categories` declares which event categories the PM watches. `route` extracts a process instance ID from each event (nil = skip). `decodeEvent` converts `RecordedEvent` to the PM's typed `InputEvent`.
- **ProcessManagerRunner** -- Actor that drives per-entity process managers. Uses `EventSubscription` to poll for events, routes to per-instance state machines, folds state via `apply`, and dispatches output commands via a user-provided `commandHandler` closure. Position-tracked via `PositionStore` for restartability.

~32 new tests covering multi-category reading, all-events reading, event subscription with multi-category/all-events, stream subscription, aggregate state streaming, process manager protocol conformance, process manager runner (command emission, multi-instance, nil route, clean shutdown), and process state streaming.
```

**Step 4: Commit and push**

```bash
git add changelog/0007-process-manager-runtime.md
git commit -m "Add Phase 6 changelog entry"
git push
```
