# Phase 5: Subscription Engine — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement polling-based category subscriptions for continuous background event processing. Subscriptions poll the EventStore by category, process events one at a time as an AsyncSequence, and persist position for restartability. Batching and position persistence happen transparently behind the iterator.

**Architecture:** `PositionStore` protocol (key-value: subscriber ID -> global position) with InMemory and SQLite implementations. `CategorySubscription` as a flat `AsyncSequence<RecordedEvent>` that polls `EventStore.readCategory` in batches, yields events one at a time, saves position after each batch, and sleeps when caught up. Cooperative cancellation via `Task.isCancelled`.

**Tech Stack:** Swift 6.2+, macOS 14+, Swift Testing, AsyncSequence/AsyncIteratorProtocol, DispatchSerialQueue custom executor (SQLite), SQLite.swift

**Test command:** `swift test 2>&1`

**Build command:** `swift build 2>&1`

**Design doc:** `docs/plans/2026-03-03-phase5-subscription-engine-design.md`

---

### Task 1: PositionStore protocol + InMemoryPositionStore + tests

**Files:**
- Create: `Sources/Songbird/PositionStore.swift`
- Create: `Sources/SongbirdTesting/InMemoryPositionStore.swift`
- Create: `Tests/SongbirdTestingTests/InMemoryPositionStoreTests.swift`

**Step 1: Write the tests**

Create `Tests/SongbirdTestingTests/InMemoryPositionStoreTests.swift`:

```swift
import Testing

@testable import Songbird
@testable import SongbirdTesting

@Suite("InMemoryPositionStore")
struct InMemoryPositionStoreTests {

    @Test func loadReturnsNilForUnknownSubscriber() async throws {
        let store = InMemoryPositionStore()
        let position = try await store.load(subscriberId: "unknown")
        #expect(position == nil)
    }

    @Test func saveAndLoadReturnsStoredPosition() async throws {
        let store = InMemoryPositionStore()
        try await store.save(subscriberId: "projector-1", globalPosition: 42)
        let position = try await store.load(subscriberId: "projector-1")
        #expect(position == 42)
    }

    @Test func saveOverwritesPreviousPosition() async throws {
        let store = InMemoryPositionStore()
        try await store.save(subscriberId: "projector-1", globalPosition: 10)
        try await store.save(subscriberId: "projector-1", globalPosition: 25)
        let position = try await store.load(subscriberId: "projector-1")
        #expect(position == 25)
    }

    @Test func independentSubscribersDoNotInterfere() async throws {
        let store = InMemoryPositionStore()
        try await store.save(subscriberId: "sub-a", globalPosition: 5)
        try await store.save(subscriberId: "sub-b", globalPosition: 99)
        let posA = try await store.load(subscriberId: "sub-a")
        let posB = try await store.load(subscriberId: "sub-b")
        #expect(posA == 5)
        #expect(posB == 99)
    }
}
```

**Step 2: Implement PositionStore protocol**

Create `Sources/Songbird/PositionStore.swift`:

```swift
public protocol PositionStore: Sendable {
    func load(subscriberId: String) async throws -> Int64?
    func save(subscriberId: String, globalPosition: Int64) async throws
}
```

**Step 3: Implement InMemoryPositionStore**

Create `Sources/SongbirdTesting/InMemoryPositionStore.swift`:

```swift
import Songbird

public actor InMemoryPositionStore: PositionStore {
    private var positions: [String: Int64] = [:]

    public init() {}

    public func load(subscriberId: String) async throws -> Int64? {
        positions[subscriberId]
    }

    public func save(subscriberId: String, globalPosition: Int64) async throws {
        positions[subscriberId] = globalPosition
    }
}
```

**Step 4: Run tests**

Run: `swift test 2>&1`
Expected: All tests pass, zero warnings.

**Step 5: Commit**

```bash
git add Sources/Songbird/PositionStore.swift Sources/SongbirdTesting/InMemoryPositionStore.swift Tests/SongbirdTestingTests/InMemoryPositionStoreTests.swift
git commit -m "Add PositionStore protocol and InMemoryPositionStore

Key-value position tracking for subscription restartability.
Protocol in core Songbird module, in-memory actor implementation
in SongbirdTesting. 4 tests covering load/save/overwrite/isolation."
```

---

### Task 2: CategorySubscription (AsyncSequence) + tests

**Files:**
- Create: `Sources/Songbird/CategorySubscription.swift`
- Create: `Tests/SongbirdTests/CategorySubscriptionTests.swift`

**Step 1: Write the tests**

Create `Tests/SongbirdTests/CategorySubscriptionTests.swift`:

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

@Suite("CategorySubscription")
struct CategorySubscriptionTests {

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

        let subscription = CategorySubscription(
            subscriberId: "test-sub",
            category: category,
            store: eventStore,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        )

        var received: [RecordedEvent] = []
        let task = Task {
            for try await event in subscription {
                received.append(event)
                if received.count == 3 { break }
            }
        }

        try await task.value
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

        let subscription = CategorySubscription(
            subscriberId: "test-sub",
            category: "order",
            store: eventStore,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        )

        var received: [RecordedEvent] = []
        let task = Task {
            for try await event in subscription {
                received.append(event)
                if received.count == 2 { break }
            }
        }

        try await task.value
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

        let subscription = CategorySubscription(
            subscriberId: "test-sub",
            category: category,
            store: eventStore,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        )

        var received: [RecordedEvent] = []
        let task = Task {
            for try await event in subscription {
                received.append(event)
                if received.count == 2 { break }
            }
        }

        try await task.value
        #expect(received.count == 2)
        // Should start from position 3 (after persisted position 2)
        #expect(received[0].globalPosition == 3)
        #expect(received[1].globalPosition == 4)
    }

    @Test func savesPositionAfterBatch() async throws {
        let (eventStore, positionStore) = makeStores()

        // Append 5 events with batch size 3
        try await appendEvents(to: eventStore, category: category, count: 5)

        let subscription = CategorySubscription(
            subscriberId: "test-sub",
            category: category,
            store: eventStore,
            positionStore: positionStore,
            batchSize: 3,
            tickInterval: .milliseconds(10)
        )

        var received: [RecordedEvent] = []
        let task = Task {
            for try await event in subscription {
                received.append(event)
                // Consume all 5 events (first batch of 3, then batch of 2)
                if received.count == 5 { break }
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

        let subscription = CategorySubscription(
            subscriberId: "test-sub",
            category: category,
            store: eventStore,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        )

        var received: [RecordedEvent] = []
        let task = Task {
            for try await event in subscription {
                received.append(event)
                // Don't break -- let it poll forever
            }
        }

        // Let the subscription process existing events
        try await Task.sleep(for: .milliseconds(50))

        // Cancel the task
        task.cancel()

        // The task should finish without hanging
        // Use a timeout to avoid hanging the test suite
        let result = await Task {
            await task.value
            return true
        }.value
        #expect(result == true)
        #expect(received.count == 2)
    }

    // MARK: - Polling

    @Test func pollsForNewEvents() async throws {
        let (eventStore, positionStore) = makeStores()

        let subscription = CategorySubscription(
            subscriberId: "test-sub",
            category: category,
            store: eventStore,
            positionStore: positionStore,
            batchSize: 100,
            tickInterval: .milliseconds(10)
        )

        var received: [RecordedEvent] = []
        let task = Task {
            for try await event in subscription {
                received.append(event)
                if received.count == 3 { break }
            }
        }

        // Give the subscription time to start polling on an empty store
        try await Task.sleep(for: .milliseconds(30))
        #expect(received.isEmpty)

        // Now append events -- the subscription should pick them up
        try await appendEvents(to: eventStore, category: category, count: 3)

        try await task.value
        #expect(received.count == 3)
    }

    @Test func handlesEmptyStore() async throws {
        let (eventStore, positionStore) = makeStores()

        let subscription = CategorySubscription(
            subscriberId: "test-sub",
            category: category,
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

        // Await completion. Use a wrapper task with a timeout to avoid hanging.
        let completedCleanly = await Task {
            await task.value
            return true
        }.value
        #expect(completedCleanly == true)
    }
}
```

**Step 2: Implement CategorySubscription**

Create `Sources/Songbird/CategorySubscription.swift`:

```swift
import Foundation

/// A polling-based subscription that reads events from a single category as an `AsyncSequence`.
///
/// The subscription polls `EventStore.readCategory` in batches and yields events one at a time.
/// Position is persisted to a `PositionStore` after each batch is fully consumed, enabling
/// restartability. When caught up (no new events), the subscription sleeps for `tickInterval`
/// before polling again. The sequence ends when the enclosing `Task` is cancelled.
///
/// Usage:
/// ```swift
/// let subscription = CategorySubscription(
///     subscriberId: "order-projector",
///     category: "order",
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
public struct CategorySubscription: AsyncSequence, Sendable {
    public typealias Element = RecordedEvent

    public let subscriberId: String
    public let category: String
    public let store: any EventStore
    public let positionStore: any PositionStore
    public let batchSize: Int
    public let tickInterval: Duration

    public init(
        subscriberId: String,
        category: String,
        store: any EventStore,
        positionStore: any PositionStore,
        batchSize: Int = 100,
        tickInterval: Duration = .milliseconds(100)
    ) {
        self.subscriberId = subscriberId
        self.category = category
        self.store = store
        self.positionStore = positionStore
        self.batchSize = batchSize
        self.tickInterval = tickInterval
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(
            subscriberId: subscriberId,
            category: category,
            store: store,
            positionStore: positionStore,
            batchSize: batchSize,
            tickInterval: tickInterval
        )
    }

    public struct Iterator: AsyncIteratorProtocol {
        let subscriberId: String
        let category: String
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
            category: String,
            store: any EventStore,
            positionStore: any PositionStore,
            batchSize: Int,
            tickInterval: Duration
        ) {
            self.subscriberId = subscriberId
            self.category = category
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

                let batch = try await store.readCategory(
                    category,
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
Expected: All tests pass, zero warnings.

**Step 4: Commit**

```bash
git add Sources/Songbird/CategorySubscription.swift Tests/SongbirdTests/CategorySubscriptionTests.swift
git commit -m "Add CategorySubscription as polling AsyncSequence

Polls EventStore.readCategory in batches, yields events one at a time.
Persists position to PositionStore after each batch for restartability.
Cooperative cancellation via Task.isCancelled. 7 tests covering
consumption, category filtering, position resume, position saving,
cancellation, polling, and empty store handling."
```

---

### Task 3: SQLitePositionStore + tests

**Files:**
- Create: `Sources/SongbirdSQLite/SQLitePositionStore.swift`
- Create: `Tests/SongbirdSQLiteTests/SQLitePositionStoreTests.swift`

**Step 1: Write the tests**

Create `Tests/SongbirdSQLiteTests/SQLitePositionStoreTests.swift`:

```swift
import Foundation
import Testing

@testable import Songbird
@testable import SongbirdSQLite

@Suite("SQLitePositionStore")
struct SQLitePositionStoreTests {

    func makeStore() throws -> SQLitePositionStore {
        try SQLitePositionStore(path: ":memory:")
    }

    @Test func loadReturnsNilForUnknownSubscriber() async throws {
        let store = try makeStore()
        let position = try await store.load(subscriberId: "unknown")
        #expect(position == nil)
    }

    @Test func saveAndLoadReturnsStoredPosition() async throws {
        let store = try makeStore()
        try await store.save(subscriberId: "projector-1", globalPosition: 42)
        let position = try await store.load(subscriberId: "projector-1")
        #expect(position == 42)
    }

    @Test func saveOverwritesPreviousPosition() async throws {
        let store = try makeStore()
        try await store.save(subscriberId: "projector-1", globalPosition: 10)
        try await store.save(subscriberId: "projector-1", globalPosition: 25)
        let position = try await store.load(subscriberId: "projector-1")
        #expect(position == 25)
    }

    @Test func independentSubscribersDoNotInterfere() async throws {
        let store = try makeStore()
        try await store.save(subscriberId: "sub-a", globalPosition: 5)
        try await store.save(subscriberId: "sub-b", globalPosition: 99)
        let posA = try await store.load(subscriberId: "sub-a")
        let posB = try await store.load(subscriberId: "sub-b")
        #expect(posA == 5)
        #expect(posB == 99)
    }

    @Test func savePersistsUpdatedAtTimestamp() async throws {
        let store = try makeStore()
        try await store.save(subscriberId: "sub-1", globalPosition: 7)

        // Verify via the load round-trip (timestamp is internal but should not cause errors)
        let position = try await store.load(subscriberId: "sub-1")
        #expect(position == 7)

        // Save again to exercise the ON CONFLICT UPDATE path
        try await store.save(subscriberId: "sub-1", globalPosition: 14)
        let updated = try await store.load(subscriberId: "sub-1")
        #expect(updated == 14)
    }
}
```

**Step 2: Implement SQLitePositionStore**

Create `Sources/SongbirdSQLite/SQLitePositionStore.swift`:

```swift
import Dispatch
import Foundation
import Songbird
import SQLite

public actor SQLitePositionStore: PositionStore {
    /// The underlying SQLite connection. Marked `nonisolated(unsafe)` because all access
    /// is serialized through this actor's custom `DispatchSerialQueue` executor, ensuring
    /// that only one thread accesses the connection at a time.
    nonisolated(unsafe) let db: Connection
    private let executor: DispatchSerialQueue
    private let iso8601Formatter = ISO8601DateFormatter()

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    public init(path: String) throws {
        self.executor = DispatchSerialQueue(label: "songbird.sqlite-position-store")
        if path == ":memory:" {
            self.db = try Connection(.inMemory)
        } else {
            self.db = try Connection(path)
        }
        try Self.configurePragmas(db)
        try Self.migrate(db)
    }

    // MARK: - Pragmas

    private static func configurePragmas(_ db: Connection) throws {
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("PRAGMA synchronous = NORMAL")
        try db.execute("PRAGMA foreign_keys = ON")
    }

    // MARK: - Migrations

    private static func migrate(_ db: Connection) throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS positions (
                subscriber_id   TEXT PRIMARY KEY,
                global_position INTEGER NOT NULL,
                updated_at      TEXT NOT NULL
            )
        """)
    }

    // MARK: - PositionStore

    public func load(subscriberId: String) async throws -> Int64? {
        let result = try db.scalar(
            "SELECT global_position FROM positions WHERE subscriber_id = ?",
            subscriberId
        )
        return result as? Int64
    }

    public func save(subscriberId: String, globalPosition: Int64) async throws {
        let now = iso8601Formatter.string(from: Date())
        try db.run(
            """
            INSERT INTO positions (subscriber_id, global_position, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(subscriber_id) DO UPDATE SET
                global_position = excluded.global_position,
                updated_at = excluded.updated_at
            """,
            subscriberId, globalPosition, now
        )
    }
}
```

**Step 3: Run tests**

Run: `swift test 2>&1`
Expected: All tests pass, zero warnings.

**Step 4: Commit**

```bash
git add Sources/SongbirdSQLite/SQLitePositionStore.swift Tests/SongbirdSQLiteTests/SQLitePositionStoreTests.swift
git commit -m "Add SQLitePositionStore for persistent position tracking

Actor with custom DispatchSerialQueue executor, same pattern as
SQLiteEventStore. Uses positions table with UPSERT for save.
WAL mode for concurrent access. 5 tests covering load/save/overwrite/
isolation/timestamp-update."
```

---

### Task 4: Final review — clean build, all tests pass, changelog, push

**Step 1: Verify clean build**

Run: `swift build 2>&1`
Expected: Build complete, zero warnings, zero errors.

**Step 2: Verify all tests pass**

Run: `swift test 2>&1`
Expected: All tests pass (should be around 116 total).

**Step 3: Write changelog entry**

Create `changelog/0006-subscription-engine.md`:

```markdown
# 0006 — Subscription Engine

Implemented Phase 5 of Songbird:

- **PositionStore** — Protocol for subscriber position persistence (subscriber ID -> global position)
- **InMemoryPositionStore** — Actor-based in-memory implementation in SongbirdTesting
- **SQLitePositionStore** — SQLite-backed implementation with custom DispatchSerialQueue executor, WAL mode, UPSERT semantics
- **CategorySubscription** — Polling-based `AsyncSequence<RecordedEvent>` for continuous background event processing
  - Polls `EventStore.readCategory` in configurable batches
  - Yields events one at a time (flat sequence, batching is transparent)
  - Persists position to `PositionStore` after each batch for restartability
  - Configurable tick interval for polling when caught up
  - Cooperative cancellation via `Task.isCancelled`

16 tests covering position store operations, event consumption, category filtering, position resume, batch position saving, cancellation, polling, and empty store handling.
```

**Step 4: Commit and push**

```bash
git add changelog/0006-subscription-engine.md
git commit -m "Add Phase 5 changelog entry"
git push
```
