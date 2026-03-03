# Phase 2: EventStore Implementations -- Design

## Summary

Implement the EventStore protocol with two concrete stores: InMemoryEventStore (for testing) and SQLiteEventStore (for production). Add EventTypeRegistry for type-safe deserialization. Add SongbirdTesting and SongbirdSQLite modules.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Scope | Both stores now | Full Phase 2 as planned. InMemory for testing, SQLite for production. |
| Hash chaining | Yes, from day one | Proven in ether. Tamper detection, audit trail. Small cost, big trust benefit. |
| EventTypeRegistry location | Core module, injected into stores at init | Both stores need it. Clean dependency injection. |
| SQLite metadata storage | Single JSON column | Keeps schema generic (not domain-specific like ether's flattened columns). |
| Stream identity in schema | `stream_name` + `stream_category` columns | Generic replacement for ether's `aggregate_type`/`aggregate_id`/`ehr_id`. |

## Types

### EventTypeRegistry (in `Songbird` core module)

```swift
public final class EventTypeRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var decoders: [String: @Sendable (Data) throws -> any Event] = [:]

    public init()
    public func register<E: Event>(_ type: E.Type)
    public func decode(_ recorded: RecordedEvent) throws -> any Event
}
```

Maps `Event.eventType` strings to decoder closures. Thread-safe via NSLock. Used by stores on the read path to reconstitute typed events from stored JSON.

### InMemoryEventStore (in `SongbirdTesting` module)

```swift
public actor InMemoryEventStore: EventStore {
    private var events: [RecordedEvent] = []
    private var streamVersions: [StreamName: Int64] = [:]
    private var globalPosition: Int64 = 0
    private let registry: EventTypeRegistry

    public init(registry: EventTypeRegistry = EventTypeRegistry())

    // Full EventStore protocol conformance
    // Optimistic concurrency via expectedVersion check
    // No hash chaining (test store)
}
```

### SQLiteEventStore (in `SongbirdSQLite` module)

```swift
public actor SQLiteEventStore: EventStore {
    let db: Connection  // SQLite.swift
    private let registry: EventTypeRegistry

    public init(path: String, registry: EventTypeRegistry) throws

    // Full EventStore protocol conformance
    // SHA-256 hash chaining
    // Optimistic concurrency via expectedVersion
    // Version-tracked migrations

    public func verifyChain(batchSize: Int = 1000) throws -> ChainVerificationResult
}
```

### ChainVerificationResult

```swift
public struct ChainVerificationResult: Sendable, Equatable {
    public let intact: Bool
    public let eventsVerified: Int
    public let brokenAtSequence: Int64?
}
```

### SQLite Schema (V1)

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;

CREATE TABLE schema_version (version INTEGER NOT NULL);

CREATE TABLE events (
    global_position  INTEGER PRIMARY KEY AUTOINCREMENT,
    stream_name      TEXT NOT NULL,
    stream_category  TEXT NOT NULL,
    position         INTEGER NOT NULL,
    event_type       TEXT NOT NULL,
    data             TEXT NOT NULL,
    metadata         TEXT NOT NULL,
    event_id         TEXT NOT NULL,
    timestamp        TEXT NOT NULL,
    event_hash       TEXT
);

CREATE INDEX idx_events_stream ON events(stream_name, position);
CREATE INDEX idx_events_category ON events(stream_category, global_position);
CREATE UNIQUE INDEX idx_events_event_id ON events(event_id);
```

### Hash Chaining

- Algorithm: SHA-256 (via CryptoKit on Apple, swift-crypto on Linux)
- Genesis hash: `"genesis"`
- Input format: `{previousHash}\0{eventType}\0{streamName}\0{data}\0{timestamp}`
- Output: lowercase hex string (64 chars)

### Optimistic Concurrency

On `append` with `expectedVersion != nil`:
1. Query `SELECT MAX(position) FROM events WHERE stream_name = ?`
2. If actual version != expectedVersion, throw `VersionConflictError`
3. Otherwise proceed with insert

### Package.swift Changes

New modules:
- **`SongbirdTesting`** -- depends on `Songbird`
- **`SongbirdSQLite`** -- depends on `Songbird` + `sqlite-swift` (stephencelis/SQLite.swift, exact: 0.15.3)

New test targets:
- **`SongbirdTestingTests`** -- tests for InMemoryEventStore
- **`SongbirdSQLiteTests`** -- tests for SQLiteEventStore

Both test targets also depend on `SongbirdTesting` (to share test event types).

### File Layout

```
Sources/Songbird/
├── (existing files)
└── EventTypeRegistry.swift

Sources/SongbirdTesting/
└── InMemoryEventStore.swift

Sources/SongbirdSQLite/
├── SQLiteEventStore.swift
└── ChainVerificationResult.swift

Tests/SongbirdTests/
└── EventTypeRegistryTests.swift

Tests/SongbirdTestingTests/
└── InMemoryEventStoreTests.swift

Tests/SongbirdSQLiteTests/
└── SQLiteEventStoreTests.swift
```
