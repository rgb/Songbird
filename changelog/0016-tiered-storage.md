# Tiered Storage for SongbirdSmew

Adds optional hot/cold tiered storage to `ReadModelStore` — hot DuckDB for recent projection data, cold DuckLake/Parquet for historical data.

**Design doc:** `docs/plans/2026-03-04-tiered-storage-design.md`

## What Changed

### New Types

- **`StorageMode`** enum (`.duckdb` default, `.tiered(DuckLakeConfig)`) — controls whether the store uses single-tier or tiered storage
- **`DuckLakeConfig`** struct — holds `catalogPath`, `dataPath`, and `backend` (`.local` only for now, extensible for S3/GCS/Azure)
- **`TieringService`** actor — background service that periodically moves old rows from hot to cold tier

### ReadModelStore Extensions

- **`init(path:storageMode:)`** — accepts optional `StorageMode`, attaches DuckLake in tiered mode
- **`registerTable(_:)`** — projectors register table names for tiered management
- **`tierProjections(olderThan:)`** — moves rows with `recorded_at` older than threshold from hot to cold tier; returns total rows moved; no-op in `.duckdb` mode
- **Cold tier mirrors** — `migrate()` auto-creates `lake."<table>"` mirrors and `v_<table>` UNION ALL views for registered tables in tiered mode

### Naming Convention

- Hot table: `orders` (created by projector migration, unchanged)
- Cold table: `lake.orders` (auto-created mirror, identical schema)
- View: `v_orders` (UNION ALL of both, for cross-tier queries)

### Convention

Registered tables must have a `recorded_at TIMESTAMP` column for time-based tiering.

## Testing

Tests simulate DuckLake by attaching an in-memory database as `lake` (`ATTACH ':memory:' AS lake`), avoiding the need for the DuckLake extension in CI. Shared `makeTieredStore()` helper in `TestHelpers.swift`.

12 new tiered storage tests + 2 TieringService tests added. 294 total tests across 47 suites.

## Known Limitations

- DuckDB does not support cross-database transactions, so the INSERT-to-cold + DELETE-from-hot per table is not atomic. If the process crashes between them, the UNION ALL view may show duplicates until the next tiering pass.
- Only local filesystem backend is supported. Cloud backends (S3/GCS/Azure) are planned for a future release.

## Files

- `Sources/SongbirdSmew/StorageMode.swift` (new)
- `Sources/SongbirdSmew/DuckLakeConfig.swift` (new)
- `Sources/SongbirdSmew/TieringService.swift` (new)
- `Sources/SongbirdSmew/ReadModelStore.swift` (modified)
- `Tests/SongbirdSmewTests/ReadModelStoreTests.swift` (modified)
- `Tests/SongbirdSmewTests/TieringServiceTests.swift` (new)
- `Tests/SongbirdSmewTests/TestHelpers.swift` (new)
