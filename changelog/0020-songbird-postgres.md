# 0020 — SongbirdPostgres Module

## Summary

Added `SongbirdPostgres`, a PostgreSQL-backed implementation of `EventStore`, `PositionStore`, and `SnapshotStore` using PostgresNIO. This gives Songbird a production-grade persistence backend alongside the existing SQLite implementation.

## What Changed

### New Module: `SongbirdPostgres`

**Dependencies:**
- `postgres-nio` (>= 1.29.0) — PostgreSQL client with Swift concurrency support
- `postgres-migrations` (>= 1.1.0) — Schema migration management

**PostgresEventStore** (`Sources/SongbirdPostgres/PostgresEventStore.swift`)
- Full `EventStore` protocol conformance
- JSONB storage for event data and metadata (Postgres-native binary JSON)
- TIMESTAMPTZ for timestamps (timezone-aware, microsecond precision)
- BIGSERIAL for global_position (1-based internally, 0-based externally)
- Optimistic concurrency via `UNIQUE (stream_name, position)` constraint
- SHA-256 hash chain computed from JSONB-normalized data for tamper detection
- `NOTIFY songbird_events` after each append for future LISTEN-based subscriptions
- `readStream`, `readCategories`, `readAll`, `readLastEvent`, `streamVersion`, `verifyChain`
- `rawExecute` for test support (unsafe SQL execution)

**PostgresPositionStore** (`Sources/SongbirdPostgres/PostgresPositionStore.swift`)
- `PositionStore` protocol conformance
- Upsert-based save (`ON CONFLICT ... DO UPDATE`)

**PostgresSnapshotStore** (`Sources/SongbirdPostgres/PostgresSnapshotStore.swift`)
- `SnapshotStore` protocol conformance
- JSONB state storage with upsert

**PostgresMigrations** (`Sources/SongbirdPostgres/PostgresMigrations.swift`)
- Schema creation via `postgres-migrations` library
- Tables: `events`, `subscriber_positions`, `snapshots`
- Indexes on `(stream_name, position)` and `(stream_category, global_position)`
- Public API for registering migrations into external `DatabaseMigrations` actors

### Core Module Change

- Moved `ChainVerificationResult` from `SongbirdSQLite` to `Songbird` core module so both SQLite and Postgres stores can use it

### Design Decisions

- **Struct-based stores** (not actors) — PostgresClient manages connection pooling internally
- **JSONB over TEXT** — enables Postgres-native JSON querying and indexing
- **Hash chain uses JSONB-normalized data** — hashes are computed from the Postgres-normalized JSON text (via INSERT + RETURNING data::text) to ensure verification consistency
- **PostgresTransactionError unwrapping** — VersionConflictError is extracted from the transaction error wrapper for clean error handling
- **1-based to 0-based position mapping** — BIGSERIAL starts at 1; the store subtracts 1 for external consumers

## Tests

34 tests across 4 suites (all nested in a serialized parent suite for database isolation):

- **PostgresEventStore** (22 tests): append, optimistic concurrency, read stream/category/all, read last event, stream version, multi-category reads
- **PostgresPositionStore** (5 tests): load/save, upsert, subscriber isolation
- **PostgresSnapshotStore** (4 tests): load/save, upsert, stream independence
- **Chain Verification** (3 tests): intact chain, empty store, tampered event detection

Tests require a running PostgreSQL instance (default: localhost:5432, songbird/songbird credentials, songbird_test database). Configurable via environment variables.
