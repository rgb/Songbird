# SongbirdSmew Design

**Date:** 2026-03-04
**Status:** Approved

## Problem

Songbird's `Projector` protocol handles event dispatch, but projectors need a read model store to write to and query from. DuckDB (via Smew) is the read model database. There's no integration layer connecting Songbird's projection pipeline to Smew's DuckDB access.

## Solution

A `ReadModelStore` actor in a new `SongbirdSmew` module. It owns a Smew `Database` + `Connection`, provides version-tracked migrations, query helpers with `RowDecoder`, and rebuild support. Smew types are exposed directly — no wrapper abstractions. DuckDB-backed projectors hold a reference to the `ReadModelStore` and use it for writes and queries.

## Approach

Shared actor with direct Smew API exposure. The `ReadModelStore` serializes all DuckDB access via a custom `DispatchSerialQueue` executor (matching `SQLiteEventStore` and `SQLiteSnapshotStore` patterns). Projectors are standard `Projector` conformances — no special DuckDB projector protocol. The module re-exports Smew so consumers import only `SongbirdSmew`.

## Components

### 1. ReadModelStore Actor

```swift
public actor ReadModelStore {
    public let database: Database
    nonisolated(unsafe) let connection: Connection
    private let executor: DispatchSerialQueue

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    public init(path: String? = nil) throws
}
```

- `path: nil` → in-memory (testing), `path: String` → file-backed
- Custom executor serializes all access to the underlying DuckDB connection
- Provides query helpers with `RowDecoder(.convertFromSnakeCase)` baked in:
  - `query<T: Decodable>(_:@QueryBuilder:) throws -> [T]`
  - `queryFirst<T: Decodable>(_:@QueryBuilder:) throws -> T?`
- Direct connection access: `withConnection<T>((Connection) throws -> T) throws -> T`

### 2. Schema Migrations

```swift
public typealias Migration = @Sendable (Connection) throws -> Void

extension ReadModelStore {
    func registerMigration(_ migration: @escaping Migration)
    func migrate() throws
}
```

- `schema_version` table tracks current version (single row, integer)
- Migrations run in registration order, each in a transaction with its version bump
- `migrate()` called once at startup after all migrations are registered
- Since read models are rebuildable, migrations can be destructive (DROP + CREATE)

### 3. Rebuild Support

```swift
extension ReadModelStore {
    func rebuild(
        from store: any EventStore,
        projectors: [any Projector],
        batchSize: Int = 1000
    ) async throws
}
```

- Reads all events from the store by global position in batches
- Applies each event to all registered projectors sequentially
- Requires `EventStore.readAll(from:maxCount:)` — a new method on the `EventStore` protocol
- Projectors that want bulk performance can use `Appender` internally via `withConnection`

### 4. EventStore.readAll

New method on the `EventStore` protocol in core `Songbird`:

```swift
func readAll(from globalPosition: Int64, maxCount: Int) async throws -> [RecordedEvent]
```

Reads events across all streams ordered by global position. Implemented in `InMemoryEventStore` and `SQLiteEventStore`.

### 5. Module Boundary

**SongbirdSmew provides:**
- `ReadModelStore` actor
- Re-exports `Smew` (consumers import only `SongbirdSmew`)

**SongbirdSmew does NOT provide:**
- Projection schema abstraction (domain-specific)
- Tiered storage (future concern)
- InMemoryReadModelStore (DuckDB in-memory mode serves this)

**No changes needed to:**
- `Projector` protocol — DuckDB projectors are standard conformances
- `ProjectionPipeline` — dispatches to projectors as before
- `SongbirdServices` — projectors register normally

## Integration Pattern

```swift
// Startup
let readModel = try ReadModelStore(path: "read-model.duckdb")
readModel.registerMigration { conn in
    try conn.execute("CREATE TABLE IF NOT EXISTS order_summaries (...)")
}
try await readModel.migrate()

let projector = OrderSummaryProjector(readModel: readModel)
services.registerProjector(projector)

// Query in route handler
let summary: OrderSummary? = try await readModel.queryFirst(OrderSummary.self) {
    "SELECT * FROM order_summaries WHERE id = \(param: orderId)"
}
```
