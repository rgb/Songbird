# SongbirdPostgres Module Design

## Overview

`SongbirdPostgres` is a new Songbird module providing PostgreSQL implementations of the `EventStore`, `PositionStore`, and `SnapshotStore` protocols. Built on PostgresNIO, it leverages Postgres-native features (JSONB, TIMESTAMPTZ, LISTEN/NOTIFY, proper transaction isolation) while maintaining full protocol compatibility with the existing SQLite implementations.

**Name:** SongbirdPostgres (sibling to SongbirdSQLite)

**Scope:** Three store implementations (`PostgresEventStore`, `PostgresPositionStore`, `PostgresSnapshotStore`), schema management via `postgres-migrations`, and SHA-256 hash chain integrity verification.

**Motivation:** The distributed and P2P Warbler demos share a SQLite file between processes, which requires the `BEGIN IMMEDIATE` workaround for multi-writer safety. PostgreSQL handles concurrent connections natively — each worker gets its own connection pool to the same database. Beyond the demos, Postgres is the natural production choice for event stores that need network accessibility, replication, and robust concurrent writes.

## Dependencies

- **`postgres-nio`** (>= 1.29.0) — PostgresClient with built-in connection pooling, transactions, safe parameterized queries via string interpolation, JSONB support. Zero Vapor dependency. SSWG graduated.
- **`postgres-migrations`** (>= 1.1.0) — Schema versioning from the Hummingbird project. Standalone (only depends on PostgresNIO).

**Why not SQLite-NIO?** Evaluated and rejected. SQLite.swift provides better ergonomics for an embedded database: `db.transaction(.immediate)`, `scalar()`, iterable statements, variadic bindings. SQLite-NIO lacks a transaction API (manual BEGIN/COMMIT/ROLLBACK), has a more verbose query API, and adds unnecessary NIOThreadPool overhead for an in-process database. Our `DispatchSerialQueue` executor pattern is cleaner for SQLite's use case.

**Why not PostgresKit?** Its own README recommends using PostgresNIO's `PostgresClient` directly. PostgresKit's value-add is the SQLKit query builder, which we don't need — Songbird writes raw SQL.

## Module Structure

```
Sources/SongbirdPostgres/
├── PostgresEventStore.swift       # EventStore conformance
├── PostgresPositionStore.swift    # PositionStore conformance
├── PostgresSnapshotStore.swift    # SnapshotStore conformance
└── PostgresMigrations.swift       # Schema creation via postgres-migrations

Tests/SongbirdPostgresTests/
├── PostgresEventStoreTests.swift
├── PostgresPositionStoreTests.swift
├── PostgresSnapshotStoreTests.swift
└── PostgresTestHelper.swift       # Test database setup/teardown
```

**Package.swift additions:**
```swift
.package(url: "https://github.com/vapor/postgres-nio.git", from: "1.29.0"),
.package(url: "https://github.com/hummingbird-project/postgres-migrations.git", from: "1.1.0"),

.target(
    name: "SongbirdPostgres",
    dependencies: [
        "Songbird",
        .product(name: "PostgresNIO", package: "postgres-nio"),
        .product(name: "PostgresMigrations", package: "postgres-migrations"),
    ]
),
```

## Client Lifecycle

The `PostgresClient` is caller-managed. All three stores accept a shared client in their init. The caller is responsible for running the client in a task group (matching the standard PostgresNIO / Hummingbird pattern):

```swift
let client = PostgresClient(configuration: config)

let eventStore = PostgresEventStore(client: client, registry: registry)
let positionStore = PostgresPositionStore(client: client)
let snapshotStore = PostgresSnapshotStore(client: client)

try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { await client.run() }
    group.addTask { try await services.run() }
    group.addTask { try await app.runService() }
    try await group.waitForAll()
}
```

## PostgresEventStore

### Schema

```sql
CREATE TABLE events (
    global_position  BIGSERIAL PRIMARY KEY,
    stream_name      TEXT NOT NULL,
    stream_category  TEXT NOT NULL,
    position         BIGINT NOT NULL,
    event_type       TEXT NOT NULL,
    data             JSONB NOT NULL,
    metadata         JSONB NOT NULL,
    event_id         UUID NOT NULL UNIQUE,
    timestamp        TIMESTAMPTZ NOT NULL,
    event_hash       TEXT,

    UNIQUE (stream_name, position)
);

CREATE INDEX idx_events_stream ON events(stream_name, position);
CREATE INDEX idx_events_category ON events(stream_category, global_position);
```

### Postgres-Native Features

| Feature | SQLite | Postgres |
|---------|--------|----------|
| Event data | TEXT (JSON string) | JSONB (indexable, efficient) |
| Metadata | TEXT (JSON string) | JSONB (indexable) |
| Timestamps | TEXT (ISO8601 strings) | TIMESTAMPTZ (native) |
| Concurrency | `BEGIN IMMEDIATE` (file lock) | `UNIQUE (stream_name, position)` constraint + transactions |
| Global position | INTEGER AUTOINCREMENT | BIGSERIAL |
| Notifications | N/A | `NOTIFY songbird_events` after append |

### Concurrency Model

The store is a struct (not an actor). `PostgresClient` manages connection pooling internally. No `DispatchSerialQueue` executor needed.

For append:
1. `client.withTransaction` wraps the version check + insert
2. The `UNIQUE (stream_name, position)` constraint is the database-level safety net
3. If a concurrent insert at the same position occurs, catch the unique constraint violation and convert to `VersionConflictError`

### LISTEN/NOTIFY

After each successful append, the store issues:
```sql
NOTIFY songbird_events, '<global_position>'
```

This enables a future `PostgresEventSubscription` that uses `LISTEN songbird_events` for near-instant event delivery instead of polling. The notification is fire-and-forget — subscriptions that miss it fall back to the existing polling mechanism.

The `PostgresEventStore` itself only produces notifications. Consuming them is a separate concern (see Future Work).

### Hash Chain

Same SHA-256 chain as SQLite:
```
hash = SHA256(previousHash + "\0" + eventType + "\0" + streamName + "\0" + data + "\0" + timestamp)
```

Stored in the `event_hash` column. Verifiable via `verifyChain()`.

### Global Position

BIGSERIAL is 1-based. We subtract 1 for 0-based global positions, matching SQLite behavior and the `EventStore` protocol contract.

## PostgresPositionStore

```sql
CREATE TABLE subscriber_positions (
    subscriber_id    TEXT PRIMARY KEY,
    global_position  BIGINT NOT NULL,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

- `load(subscriberId:)` → `SELECT global_position WHERE subscriber_id = $1`
- `save(subscriberId:, globalPosition:)` → `INSERT ... ON CONFLICT DO UPDATE` (upsert)

Struct accepting a `PostgresClient`.

## PostgresSnapshotStore

```sql
CREATE TABLE snapshots (
    stream_name  TEXT PRIMARY KEY,
    state        JSONB NOT NULL,
    version      BIGINT NOT NULL,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

- `saveData(_:version:for:)` → upsert with `ON CONFLICT (stream_name) DO UPDATE`
- `loadData(for:)` → `SELECT state, version WHERE stream_name = $1`

JSONB for the `state` column (instead of SQLite's BLOB) since aggregate state is JSON-encoded. This allows querying snapshot contents directly if needed.

Struct accepting a `PostgresClient`.

## Schema Management

All three tables are created via a `SongbirdPostgresMigrations` helper that integrates with `postgres-migrations`:

```swift
let migrations = PostgresMigrations()
SongbirdPostgresMigrations.register(in: &migrations)
try await migrations.apply(client: client, logger: logger)
```

This runs versioned migrations (create tables, add indexes) idempotently.

## Testing Strategy

- **Unit tests** require a running Postgres instance (localhost:5432)
- **`PostgresTestHelper`**: Creates a temporary test database, runs migrations, tears down after tests
- **Test scenarios mirror `SQLiteEventStoreTests`**: append + read, optimistic concurrency, category reads, hash chain verification, position store CRUD, snapshot store CRUD
- **CI**: GitHub Actions with `services: postgres:16` container

## Warbler Integration

The distributed and P2P demos can swap SQLite for Postgres by changing the store initialization:

```swift
// SQLite (current):
let eventStore = try SQLiteEventStore(path: "data/songbird.sqlite", registry: registry)

// Postgres:
let client = PostgresClient(configuration: .init(
    host: "localhost", username: "warbler", password: "warbler",
    database: "warbler", tls: .disable
))
let eventStore = PostgresEventStore(client: client, registry: registry)
```

Each worker gets its own connection pool. No file sharing, no `BEGIN IMMEDIATE` workaround.

We don't modify the existing demos — Postgres variants are a follow-up.

## Future Work

- **`PostgresEventSubscription`**: LISTEN/NOTIFY-based event subscription for near-instant delivery instead of polling. The `NOTIFY` is already built into the event store; this would add the `LISTEN` consumer.
- **`EventStore` protocol improvements**: Track any protocol enhancement opportunities discovered during implementation and present as feedback.
- **JSONB indexing**: GIN indexes on `data` column for event content queries (e.g., "find all events where data->>'userId' = 'alice'").
- **Warbler Postgres variants**: Modified distributed/P2P demos using Postgres instead of shared SQLite.
- **`SongbirdKafka` module**: Kafka integration for injectors using `swift-kafka-client`. AsyncSequence consumer maps to `Injector.events() -> AsyncStream<InboundEvent>`.

## Known Limitations

- Tests require a running Postgres instance (not purely in-memory like SQLite tests)
- No connection retry/reconnection logic beyond what PostgresNIO provides
- LISTEN/NOTIFY notifications are fire-and-forget — subscribers that disconnect may miss notifications (they fall back to polling)
- No support for Postgres logical replication or CDC (change data capture) — that would be a separate integration
