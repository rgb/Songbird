# Tiered Storage Design

**Date:** 2026-03-04
**Status:** Approved

## Problem

Projection data in DuckDB accumulates over time. Old historical rows make the hot database larger and slower. There's no way to archive old projection data to cost-effective storage while keeping recent data fast.

## Solution

Extend `ReadModelStore` with optional tiered storage: hot DuckDB for recent data, cold DuckLake/Parquet for historical data. Projectors register table names. The store auto-creates cold-tier mirrors and UNION ALL views. A `TieringService` actor periodically moves old rows from hot to cold based on a time threshold.

## Approach

Integrated extension of ReadModelStore. When `storageMode` is `.duckdb` (default), behavior is identical to today. When `.tiered`, the store attaches a DuckLake database, mirrors registered tables in the cold schema, and creates views spanning both tiers. Follows ether's battle-tested pattern, simplified: time-based tiering on `recorded_at` instead of ether's `is_latest` flag.

## Components

### 1. Storage Mode & Configuration

```swift
public enum StorageMode: Sendable {
    case duckdb
    case tiered(DuckLakeConfig)
}

public struct DuckLakeConfig: Sendable {
    public enum Backend: String, Sendable {
        case local
    }

    public let catalogPath: String
    public let dataPath: String
    public let backend: Backend

    public init(catalogPath: String, dataPath: String, backend: Backend = .local)
}
```

- `StorageMode.duckdb` — current behavior, no changes
- `StorageMode.tiered(config)` — hot DuckDB + cold DuckLake/Parquet
- `DuckLakeConfig.Backend` is extensible for future S3/GCS/Azure support
- `catalogPath` — DuckLake metadata catalog file
- `dataPath` — directory for Parquet data files

### 2. ReadModelStore Init Changes

```swift
public init(path: String? = nil, storageMode: StorageMode = .duckdb) throws
```

When `.tiered`, init additionally runs:
```sql
INSTALL ducklake;
LOAD ducklake;
ATTACH 'ducklake:<catalogPath>' AS lake (DATA_PATH '<dataPath>');
```

The `lake` schema name is a constant (`coldSchemaName = "lake"`), matching ether's convention.

### 3. Table Registration

```swift
public func registerTable(_ name: String)
```

Projectors register their table names at startup, before `migrate()`. This tells ReadModelStore which tables to manage across tiers.

During `migrate()` in tiered mode, after running user migrations:
1. For each registered table, create a cold-tier mirror: `CREATE TABLE IF NOT EXISTS lake."<name>" AS SELECT * FROM "<name>" WHERE FALSE`
2. Create a UNION ALL view: `CREATE OR REPLACE VIEW "v_<name>" AS SELECT * FROM "<name>" UNION ALL SELECT * FROM lake."<name>"`

Naming convention:
- Hot table: `orders` (created by projector migration, unchanged)
- Cold table: `lake.orders` (auto-created mirror, identical schema)
- View: `v_orders` (UNION ALL of both, for cross-tier queries)

In `.duckdb` mode, `registerTable()` is callable but a no-op for cold-tier setup.

### 4. Tiering Operation

```swift
public func tierProjections(olderThan thresholdDays: Int) throws -> Int
```

For each registered table:
1. Count rows: `SELECT COUNT(*) FROM "<table>" WHERE recorded_at < CURRENT_TIMESTAMP - INTERVAL '<thresholdDays> days'`
2. Insert to cold: `INSERT INTO lake."<table>" SELECT * FROM "<table>" WHERE ...`
3. Delete from hot: `DELETE FROM "<table>" WHERE ...`
4. Return total rows moved across all tables

**Convention:** Registered tables must have a `recorded_at TIMESTAMP` column for time-based tiering. This is documented as a requirement.

Returns 0 immediately in `.duckdb` mode.

### 5. TieringService Actor

```swift
public actor TieringService {
    public init(
        readModel: ReadModelStore,
        thresholdDays: Int = 30,
        interval: Duration = .seconds(3600)
    )

    public func run() async
    public func stop()
}
```

Long-running actor that periodically calls `tierProjections()`. Runs in a loop with configurable interval (default: 1 hour) and threshold (default: 30 days). Stops gracefully via `stop()`.

### 6. Module Boundary

**SongbirdSmew provides:**
- `StorageMode` enum
- `DuckLakeConfig` struct with `Backend` enum
- `ReadModelStore.registerTable(_:)` method
- `ReadModelStore.tierProjections(olderThan:)` method
- `TieringService` actor

**SongbirdSmew does NOT provide:**
- Cloud backend credential management
- Automatic Parquet file compaction (use `ducklake_merge_adjacent_files()` manually)
- Query rewriting (consumers choose hot tables or `v_` views explicitly)

**Planned future features (not in this implementation):**
- S3/GCS/Azure cloud backends via httpfs extension
- Credential management helpers
- Parquet compaction wrapper

## Integration Pattern

```swift
// Startup
let readModel = try ReadModelStore(
    path: "read-model.duckdb",
    storageMode: .tiered(DuckLakeConfig(
        catalogPath: "/data/lake-catalog.duckdb",
        dataPath: "/data/parquet/"
    ))
)

// Projector registers its table
readModel.registerTable("order_summaries")

readModel.registerMigration { conn in
    try conn.execute("CREATE TABLE order_summaries (id VARCHAR, total DECIMAL, recorded_at TIMESTAMP)")
}
try await readModel.migrate()

// Queries: use v_order_summaries for cross-tier, order_summaries for hot-only
let summaries: [OrderSummary] = try await readModel.query(OrderSummary.self) {
    "SELECT * FROM v_order_summaries WHERE id = \(param: orderId)"
}

// Background tiering
let tieringService = TieringService(readModel: readModel, thresholdDays: 30)
let tierTask = Task { await tieringService.run() }
// ... on shutdown:
await tieringService.stop()
tierTask.cancel()
```
