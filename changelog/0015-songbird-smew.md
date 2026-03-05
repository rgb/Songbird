# SongbirdSmew Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add DuckDB read model integration via Smew, providing a `ReadModelStore` actor with migrations, query helpers, and rebuild support.

**Architecture:** A new `SongbirdSmew` module containing a `ReadModelStore` actor that owns a Smew `Database` + `Connection`. Uses a custom `DispatchSerialQueue` executor (matching `SQLiteEventStore` pattern). Exposes Smew types directly — no wrapper abstractions. Re-exports `Smew` for consumer convenience.

**Tech Stack:** Swift 6.2, Smew 0.34.4 (DuckDB), Swift Testing

---

### Task 1: Package.swift — Add SongbirdSmew Module

**Files:**
- Modify: `Package.swift`

**Step 1: Add Smew dependency and SongbirdSmew targets**

Add to the `dependencies` array:
```swift
.package(url: "git@github.com:rgb/smew.git", exact: "0.34.4"),
```

Add to the `products` array:
```swift
.library(name: "SongbirdSmew", targets: ["SongbirdSmew"]),
```

Add to the `targets` array (after the `// MARK: - SQLite` section):
```swift
// MARK: - Smew (DuckDB)

.target(
    name: "SongbirdSmew",
    dependencies: [
        "Songbird",
        .product(name: "Smew", package: "smew"),
    ]
),
```

Add to the test targets:
```swift
.testTarget(
    name: "SongbirdSmewTests",
    dependencies: ["SongbirdSmew", "SongbirdTesting"]
),
```

**Step 2: Create source and test directories**

```
mkdir -p Sources/SongbirdSmew
mkdir -p Tests/SongbirdSmewTests
```

**Step 3: Create placeholder file to verify build**

Create `Sources/SongbirdSmew/ReadModelStore.swift`:
```swift
@_exported import Smew
import Songbird
```

Create `Tests/SongbirdSmewTests/ReadModelStoreTests.swift`:
```swift
import Testing

@testable import SongbirdSmew

@Suite("ReadModelStore")
struct ReadModelStoreTests {
}
```

**Step 4: Build to verify**

Run: `swift build`
Expected: Build succeeds. Smew dependency resolves.

**Step 5: Commit**

```
git add Package.swift Sources/SongbirdSmew/ Tests/SongbirdSmewTests/
git commit -m "Add SongbirdSmew module with Smew dependency"
```

---

### Task 2: ReadModelStore — Core Actor

**Files:**
- Modify: `Sources/SongbirdSmew/ReadModelStore.swift`
- Modify: `Tests/SongbirdSmewTests/ReadModelStoreTests.swift`

**Step 1: Write tests for initialization and withConnection**

In `ReadModelStoreTests.swift`:
```swift
import Testing
import Smew

@testable import SongbirdSmew

@Suite("ReadModelStore")
struct ReadModelStoreTests {

    @Test func initializesInMemory() async throws {
        let store = try ReadModelStore()
        // Verify the connection works by executing a simple query
        let result = try await store.withConnection { conn in
            try conn.query("SELECT 42 AS value").scalarInt64()
        }
        #expect(result == 42)
    }

    @Test func withConnectionProvidesAccess() async throws {
        let store = try ReadModelStore()
        try await store.withConnection { conn in
            try conn.execute("CREATE TABLE test (id INTEGER, name VARCHAR)")
            try conn.execute("INSERT INTO test VALUES (1, 'hello')")
        }
        let count = try await store.withConnection { conn in
            try conn.query("SELECT COUNT(*) FROM test").scalarInt64()
        }
        #expect(count == 1)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter SongbirdSmewTests`
Expected: FAIL — `ReadModelStore` has no `withConnection` or proper init.

**Step 3: Implement ReadModelStore core**

Replace `Sources/SongbirdSmew/ReadModelStore.swift`:
```swift
@_exported import Smew
import Dispatch
import Foundation
import Songbird

/// A DuckDB-backed read model store for materialized projections.
///
/// Owns a Smew `Database` and `Connection`, serializing all access through a
/// custom executor. Projectors hold a reference to the store and use
/// `withConnection` for writes, while route handlers use the query helpers
/// for reads.
///
/// ```swift
/// let readModel = try ReadModelStore()
/// try await readModel.withConnection { conn in
///     try conn.execute("INSERT INTO orders ...")
/// }
/// let orders: [Order] = try await readModel.query(Order.self) {
///     "SELECT * FROM orders WHERE status = \(param: "active")"
/// }
/// ```
public actor ReadModelStore {
    public let database: Database

    /// The underlying DuckDB connection. Marked `nonisolated(unsafe)` because all access
    /// is serialized through this actor's custom `DispatchSerialQueue` executor.
    nonisolated(unsafe) let connection: Connection

    private let executor: DispatchSerialQueue

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    /// Creates a new read model store.
    ///
    /// - Parameter path: File path for persistent storage. Pass `nil` (default) for
    ///   an in-memory database, suitable for testing.
    public init(path: String? = nil) throws {
        self.executor = DispatchSerialQueue(label: "songbird.read-model-store")
        if let path {
            self.database = try Database(store: .file(at: URL(fileURLWithPath: path)))
        } else {
            self.database = try Database(store: .inMemory)
        }
        self.connection = try database.connect()
    }

    /// Provides direct access to the underlying Smew `Connection`.
    ///
    /// Use this for raw SQL execution, `Appender`-based bulk inserts, or any
    /// operation not covered by the query helpers.
    public func withConnection<T: Sendable>(
        _ body: (Connection) throws -> T
    ) throws -> T {
        try body(connection)
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter SongbirdSmewTests`
Expected: PASS — 2 tests pass.

**Step 5: Commit**

```
git add Sources/SongbirdSmew/ReadModelStore.swift Tests/SongbirdSmewTests/ReadModelStoreTests.swift
git commit -m "Add ReadModelStore actor with DuckDB connection management"
```

---

### Task 3: Query Helpers

**Files:**
- Modify: `Sources/SongbirdSmew/ReadModelStore.swift`
- Modify: `Tests/SongbirdSmewTests/ReadModelStoreTests.swift`

**Step 1: Write tests for query and queryFirst**

Add to `ReadModelStoreTests.swift`:
```swift
private struct Widget: Decodable, Equatable {
    let id: Int64
    let name: String
}

// Add these tests inside the suite:

@Test func queryDecodesRows() async throws {
    let store = try ReadModelStore()
    try await store.withConnection { conn in
        try conn.execute("CREATE TABLE widgets (id INTEGER, name VARCHAR)")
        try conn.execute("INSERT INTO widgets VALUES (1, 'Sprocket')")
        try conn.execute("INSERT INTO widgets VALUES (2, 'Gear')")
    }
    let widgets: [Widget] = try await store.query(Widget.self) {
        "SELECT id, name FROM widgets ORDER BY id"
    }
    #expect(widgets.count == 2)
    #expect(widgets[0] == Widget(id: 1, name: "Sprocket"))
    #expect(widgets[1] == Widget(id: 2, name: "Gear"))
}

@Test func queryFirstReturnsSingleRow() async throws {
    let store = try ReadModelStore()
    try await store.withConnection { conn in
        try conn.execute("CREATE TABLE items (item_id INTEGER, item_name VARCHAR)")
        try conn.execute("INSERT INTO items VALUES (1, 'Alpha')")
    }
    // snake_case → camelCase via RowDecoder
    struct Item: Decodable, Equatable {
        let itemId: Int64
        let itemName: String
    }
    let item: Item? = try await store.queryFirst(Item.self) {
        "SELECT item_id, item_name FROM items WHERE item_id = \(param: Int64(1))"
    }
    #expect(item == Item(itemId: 1, itemName: "Alpha"))
}

@Test func queryFirstReturnsNilWhenEmpty() async throws {
    let store = try ReadModelStore()
    try await store.withConnection { conn in
        try conn.execute("CREATE TABLE empty_table (id INTEGER)")
    }
    struct Row: Decodable { let id: Int64 }
    let result: Row? = try await store.queryFirst(Row.self) {
        "SELECT id FROM empty_table"
    }
    #expect(result == nil)
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter SongbirdSmewTests`
Expected: FAIL — `query` and `queryFirst` don't exist yet.

**Step 3: Implement query helpers**

Add to `ReadModelStore.swift`:
```swift
// MARK: - Query Helpers

private let snakeCaseDecoder = RowDecoder(keyDecodingStrategy: .convertFromSnakeCase)

extension ReadModelStore {
    /// Executes a query built with `@QueryBuilder` and decodes all rows.
    ///
    /// Uses `RowDecoder(.convertFromSnakeCase)` so DuckDB `snake_case` columns
    /// map automatically to Swift `camelCase` properties.
    public func query<T: Decodable>(
        _ type: T.Type,
        @QueryBuilder _ build: () -> QueryFragment
    ) throws -> [T] {
        try connection.query(build).decode(type, using: snakeCaseDecoder)
    }

    /// Executes a query and decodes the first row, or returns `nil`.
    public func queryFirst<T: Decodable>(
        _ type: T.Type,
        @QueryBuilder _ build: () -> QueryFragment
    ) throws -> T? {
        try connection.query(build).decodeFirst(type, using: snakeCaseDecoder)
    }
}
```

**Note:** The `snakeCaseDecoder` is a file-level `let` (not a stored property on the actor) because `RowDecoder` is `Sendable` and stateless — no need to make it part of the actor's isolated state.

**Step 4: Run tests to verify they pass**

Run: `swift test --filter SongbirdSmewTests`
Expected: PASS — 5 tests pass.

**Step 5: Commit**

```
git add Sources/SongbirdSmew/ReadModelStore.swift Tests/SongbirdSmewTests/ReadModelStoreTests.swift
git commit -m "Add query helpers with snake_case to camelCase decoding"
```

---

### Task 4: Schema Migrations

**Files:**
- Modify: `Sources/SongbirdSmew/ReadModelStore.swift`
- Modify: `Tests/SongbirdSmewTests/ReadModelStoreTests.swift`

**Step 1: Write tests for migration tracking**

Add to `ReadModelStoreTests.swift`:
```swift
@Test func migrateRunsPendingMigrations() async throws {
    let store = try ReadModelStore()
    await store.registerMigration { conn in
        try conn.execute("CREATE TABLE v1_table (id INTEGER)")
    }
    await store.registerMigration { conn in
        try conn.execute("CREATE TABLE v2_table (id INTEGER)")
    }
    try await store.migrate()

    // Both tables should exist
    let v1Count = try await store.withConnection { conn in
        try conn.query("SELECT COUNT(*) FROM v1_table").scalarInt64()
    }
    let v2Count = try await store.withConnection { conn in
        try conn.query("SELECT COUNT(*) FROM v2_table").scalarInt64()
    }
    #expect(v1Count == 0)
    #expect(v2Count == 0)
}

@Test func migrateSkipsAlreadyApplied() async throws {
    let store = try ReadModelStore()
    var runCount = 0
    await store.registerMigration { conn in
        runCount += 1
        try conn.execute("CREATE TABLE m1 (id INTEGER)")
    }
    try await store.migrate()
    try await store.migrate()  // Second call should be a no-op
    #expect(runCount == 1)
}

@Test func migrateRunsInOrder() async throws {
    let store = try ReadModelStore()
    var order: [Int] = []
    await store.registerMigration { _ in order.append(1) }
    await store.registerMigration { _ in order.append(2) }
    await store.registerMigration { _ in order.append(3) }
    try await store.migrate()
    #expect(order == [1, 2, 3])
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter SongbirdSmewTests`
Expected: FAIL — `registerMigration` and `migrate` don't exist.

**Step 3: Implement migrations**

Add to `ReadModelStore.swift`, inside the actor:
```swift
private var migrations: [Migration] = []

/// Registers a migration to run during `migrate()`.
///
/// Migrations execute in registration order. Each migration receives the
/// underlying DuckDB `Connection` and should create/alter tables as needed.
/// Since read models are rebuildable from events, destructive operations
/// (DROP + CREATE) are safe.
public func registerMigration(_ migration: @escaping Migration) {
    migrations.append(migration)
}

/// Runs all pending migrations.
///
/// Tracks the current schema version in a `schema_version` table. Each
/// migration runs in a transaction with its version bump, ensuring atomicity.
/// Call once at startup after registering all migrations.
public func migrate() throws {
    try ensureSchemaVersionTable()
    let currentVersion = try schemaVersion()
    for (index, migration) in migrations.enumerated() {
        let version = index + 1
        if version > currentVersion {
            try connection.withTransaction {
                try migration(connection)
                try connection.execute(
                    "UPDATE schema_version SET version = \(param: Int64(version))"
                )
            }
        }
    }
}

private func ensureSchemaVersionTable() throws {
    try connection.execute(
        "CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)"
    )
    let count = try connection.query("SELECT COUNT(*) FROM schema_version").scalarInt64() ?? 0
    if count == 0 {
        try connection.execute("INSERT INTO schema_version VALUES (0)")
    }
}

private func schemaVersion() throws -> Int {
    Int(try connection.query("SELECT version FROM schema_version").scalarInt64() ?? 0)
}
```

Add the `Migration` typealias at file level (outside the actor):
```swift
/// A migration closure that receives a DuckDB `Connection` and creates or
/// modifies read model tables.
public typealias Migration = @Sendable (Connection) throws -> Void
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter SongbirdSmewTests`
Expected: PASS — 8 tests pass.

**Step 5: Commit**

```
git add Sources/SongbirdSmew/ReadModelStore.swift Tests/SongbirdSmewTests/ReadModelStoreTests.swift
git commit -m "Add version-tracked schema migrations to ReadModelStore"
```

---

### Task 5: Rebuild Support

**Files:**
- Modify: `Sources/SongbirdSmew/ReadModelStore.swift`
- Modify: `Tests/SongbirdSmewTests/ReadModelStoreTests.swift`

**Step 1: Write tests for rebuild**

Add to `ReadModelStoreTests.swift`:
```swift
import Songbird
import SongbirdTesting

// Add a test event type at file level (outside the suite):
private enum TestEvent: Event, Equatable {
    case itemAdded(name: String)

    var eventType: String {
        switch self {
        case .itemAdded: "ItemAdded"
        }
    }
}

// Add a test projector at file level:
private actor CountingProjector: Projector {
    let projectorId = "Counting"
    private(set) var count = 0

    func apply(_ event: RecordedEvent) async throws {
        count += 1
    }
}

// Add these tests inside the suite:

@Test func rebuildReplaysAllEvents() async throws {
    let registry = EventTypeRegistry()
    registry.register(TestEvent.self, eventTypes: ["ItemAdded"])
    let eventStore = InMemoryEventStore(registry: registry)

    let meta = EventMetadata(traceId: "test")
    let stream = StreamName(category: "item", id: "1")
    _ = try await eventStore.append(TestEvent.itemAdded(name: "A"), to: stream, metadata: meta, expectedVersion: nil)
    _ = try await eventStore.append(TestEvent.itemAdded(name: "B"), to: stream, metadata: meta, expectedVersion: nil)
    _ = try await eventStore.append(TestEvent.itemAdded(name: "C"), to: stream, metadata: meta, expectedVersion: nil)

    let readModel = try ReadModelStore()
    let projector = CountingProjector()
    try await readModel.rebuild(from: eventStore, projectors: [projector])

    let count = await projector.count
    #expect(count == 3)
}

@Test func rebuildWithNoEventsSucceeds() async throws {
    let eventStore = InMemoryEventStore()
    let readModel = try ReadModelStore()
    let projector = CountingProjector()
    try await readModel.rebuild(from: eventStore, projectors: [projector])

    let count = await projector.count
    #expect(count == 0)
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter SongbirdSmewTests`
Expected: FAIL — `rebuild` doesn't exist.

**Step 3: Implement rebuild**

Add to `ReadModelStore.swift`:
```swift
// MARK: - Rebuild

extension ReadModelStore {
    /// Rebuilds the read model by replaying all events from the store.
    ///
    /// Reads events in batches by global position and applies each to every
    /// projector. Projectors that need bulk performance can use `Appender`
    /// internally via their reference to this store's `withConnection`.
    ///
    /// - Parameters:
    ///   - store: The event store to read from.
    ///   - projectors: The projectors to apply events to.
    ///   - batchSize: Number of events to read per batch (default 1000).
    public func rebuild(
        from store: any EventStore,
        projectors: [any Projector],
        batchSize: Int = 1000
    ) async throws {
        var position: Int64 = 0
        while true {
            let batch = try await store.readAll(from: position, maxCount: batchSize)
            guard !batch.isEmpty else { break }
            for record in batch {
                for projector in projectors {
                    try await projector.apply(record)
                }
            }
            position = batch.last!.globalPosition + 1
        }
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter SongbirdSmewTests`
Expected: PASS — 10 tests pass.

**Step 5: Commit**

```
git add Sources/SongbirdSmew/ReadModelStore.swift Tests/SongbirdSmewTests/ReadModelStoreTests.swift
git commit -m "Add event replay rebuild support to ReadModelStore"
```

---

### Task 6: Integration Test — Full Projection Cycle

**Files:**
- Modify: `Tests/SongbirdSmewTests/ReadModelStoreTests.swift`

**Step 1: Write an end-to-end test**

This test verifies the full cycle: append event → pipeline delivers → DuckDB projector writes → query returns data.

Add to `ReadModelStoreTests.swift`:
```swift
// Add a DuckDB-backed projector at file level:
private actor ItemProjector: Projector {
    let projectorId = "Items"
    let readModel: ReadModelStore

    init(readModel: ReadModelStore) {
        self.readModel = readModel
    }

    func apply(_ event: RecordedEvent) async throws {
        guard event.eventType == "ItemAdded" else { return }
        let envelope = try event.decode(TestEvent.self)
        guard case .itemAdded(let name) = envelope.event else { return }
        try await readModel.withConnection { conn in
            try conn.execute(
                "INSERT INTO items (name, stream) VALUES (\(param: name), \(param: event.streamName.description))"
            )
        }
    }
}

// Add to the suite:
@Test func fullProjectionCycle() async throws {
    // Setup
    let registry = EventTypeRegistry()
    registry.register(TestEvent.self, eventTypes: ["ItemAdded"])
    let eventStore = InMemoryEventStore(registry: registry)
    let readModel = try ReadModelStore()

    await readModel.registerMigration { conn in
        try conn.execute("CREATE TABLE items (name VARCHAR, stream VARCHAR)")
    }
    try await readModel.migrate()

    let projector = ItemProjector(readModel: readModel)
    let pipeline = ProjectionPipeline()
    await pipeline.register(projector)

    let runTask = Task { await pipeline.run() }

    // Append and project
    let meta = EventMetadata(traceId: "test")
    let stream = StreamName(category: "item", id: "1")
    let recorded = try await eventStore.append(
        TestEvent.itemAdded(name: "Widget"),
        to: stream, metadata: meta, expectedVersion: nil
    )
    await pipeline.enqueue(recorded)
    try await pipeline.waitForIdle()

    // Query
    struct ItemRow: Decodable, Equatable {
        let name: String
        let stream: String
    }
    let items: [ItemRow] = try await readModel.query(ItemRow.self) {
        "SELECT name, stream FROM items"
    }
    #expect(items.count == 1)
    #expect(items[0] == ItemRow(name: "Widget", stream: "item-1"))

    // Cleanup
    pipeline.stop()
    runTask.cancel()
}
```

**Step 2: Run tests to verify they pass**

Run: `swift test --filter SongbirdSmewTests`
Expected: PASS — 11 tests pass.

**Step 3: Commit**

```
git add Tests/SongbirdSmewTests/ReadModelStoreTests.swift
git commit -m "Add end-to-end projection cycle integration test"
```

---

### Task 7: Clean Build + Full Test Suite

**Step 1: Run the full test suite**

Run: `swift test`
Expected: All tests pass (270+ existing + 11 new SongbirdSmew tests).

**Step 2: Check for warnings**

Run: `swift build 2>&1 | grep -i warning`
Expected: No warnings.

**Step 3: Commit changelog**

The changelog file was written at the start. Verify it's tracked and commit any final updates.

```
git add changelog/0015-songbird-smew.md
git commit -m "Add SongbirdSmew changelog entry"
```
