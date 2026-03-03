# Phase 5: Subscription Engine -- Design

## Summary

Implement polling-based subscription for continuous background event processing. Subscriptions poll the EventStore by category, process events, and persist position for restartability. The subscription is exposed as a flat `AsyncSequence<RecordedEvent>` -- batching and position persistence happen transparently behind the iterator.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Relationship to ProjectionPipeline | Separate system | Pipeline is real-time push (AsyncStream). Subscriptions are background pull (polling). Different use cases. |
| Position storage | Separate `PositionStore` protocol | Clean separation from domain events. SQLite impl uses same DB (positions table). |
| Consumer API | Flat `AsyncSequence<RecordedEvent>` | Most aligned with structured concurrency. `for await event in subscription`. Batching/position hidden. |
| Batch API | Not provided (YAGNI) | Users who need batch control can use `store.readCategory` directly. |
| Module | Core `Songbird` (protocol + types) | No external dependencies. `SongbirdTesting` for InMemoryPositionStore. `SongbirdSQLite` for SQLitePositionStore. |

## Types

### PositionStore Protocol (in `Songbird` core)

```swift
public protocol PositionStore: Sendable {
    func load(subscriberId: String) async throws -> Int64?
    func save(subscriberId: String, globalPosition: Int64) async throws
}
```

Simple key-value: subscriber ID -> last processed global position. Returns `nil` if the subscriber has never run (start from beginning).

### CategorySubscription (in `Songbird` core)

```swift
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
    )

    public func makeAsyncIterator() -> Iterator
}
```

Conforms to `AsyncSequence`. Each call to `Iterator.next()` returns the next event. Internally:

1. On first call, loads position from `PositionStore` (or starts from 0)
2. Fetches a batch via `store.readCategory(category, from: position + 1, maxCount: batchSize)`
3. Yields events one by one from the batch
4. When batch is exhausted, saves position to `PositionStore`, fetches next batch
5. When caught up (empty batch), sleeps for `tickInterval` then retries
6. Respects `Task.isCancelled` for cooperative shutdown

### Iterator

```swift
public struct Iterator: AsyncIteratorProtocol {
    public mutating func next() async throws -> RecordedEvent?
}
```

Returns `nil` when the task is cancelled (signals end of sequence).

### InMemoryPositionStore (in `SongbirdTesting`)

```swift
public actor InMemoryPositionStore: PositionStore {
    public init()
    public func load(subscriberId: String) async throws -> Int64?
    public func save(subscriberId: String, globalPosition: Int64) async throws
}
```

### SQLitePositionStore (in `SongbirdSQLite`)

```swift
public actor SQLitePositionStore: PositionStore {
    public init(db: SQLiteEventStore)
    public func load(subscriberId: String) async throws -> Int64?
    public func save(subscriberId: String, globalPosition: Int64) async throws
}
```

Uses a `positions` table in the same SQLite database as the event store:

```sql
CREATE TABLE IF NOT EXISTS positions (
    subscriber_id TEXT PRIMARY KEY,
    global_position INTEGER NOT NULL,
    updated_at TEXT NOT NULL
);
```

The `SQLitePositionStore` takes a `SQLiteEventStore` reference to access the same database connection. Since both are actors, the position store calls through the event store's executor for serialized DB access.

## Usage Example

```swift
let subscription = CategorySubscription(
    subscriberId: "order-summary-projector",
    category: "order",
    store: eventStore,
    positionStore: positionStore,
    batchSize: 100,
    tickInterval: .milliseconds(100)
)

// Structured concurrency -- cancellation stops the subscription
let task = Task {
    for try await event in subscription {
        try await projector.apply(event)
    }
}

// Later: cancel stops the polling loop
task.cancel()
```

## File Layout

```
Sources/Songbird/
├── (existing files)
├── PositionStore.swift           // protocol
└── CategorySubscription.swift    // AsyncSequence + Iterator

Sources/SongbirdTesting/
├── (existing files)
└── InMemoryPositionStore.swift

Sources/SongbirdSQLite/
├── (existing files)
└── SQLitePositionStore.swift

Tests/SongbirdTests/
├── (existing files)
└── CategorySubscriptionTests.swift

Tests/SongbirdSQLiteTests/
├── (existing files)
└── SQLitePositionStoreTests.swift
```
