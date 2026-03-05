# LISTEN/NOTIFY Subscriptions + S3 Cloud Tiering Design

## Feature 1: PostgresEventSubscription (LISTEN/NOTIFY)

### Goal

Replace polling with near-instant event delivery for Postgres-backed subscriptions using PostgreSQL LISTEN/NOTIFY, with a fallback poll as safety net.

### Architecture

`PostgresEventSubscription` is a new `AsyncSequence<RecordedEvent>` in `SongbirdPostgres`. It is a drop-in replacement for the polling-based `EventSubscription` from the core module. The existing `EventSubscription` remains unchanged and universal — it works with any `EventStore`.

**Init parameters** (mirrors `EventSubscription`):
- `client: PostgresClient` — for data reads (readCategories)
- `connectionConfig: PostgresClient.Configuration` — for creating dedicated LISTEN connection
- `subscriberId: String`
- `categories: [String]` (empty = all)
- `positionStore: PositionStore`
- `batchSize: Int` (default 100)
- `fallbackPollInterval: Duration` (default 5 seconds)

### Data Flow

1. Open dedicated `PostgresConnection` (not from pool) and issue `LISTEN songbird_events`
2. Load position from PositionStore
3. Initial poll to catch up on any missed events
4. Wait for either: LISTEN notification OR fallback timer expires
5. On wakeup: read events via `client.readCategories` (same path as polling subscription)
6. Yield events, save position after each batch
7. If fallback poll found events → LISTEN connection may have failed → close and re-establish the dedicated connection, re-issue LISTEN
8. On cancellation: `UNLISTEN`, close dedicated connection

### Key Decisions

- **Dedicated `PostgresConnection`** for LISTEN, not from pool — LISTEN is connection-scoped and long-lived, not suited for pool connections
- **Hybrid wakeup** — LISTEN for the fast path, fallback poll every 5s as safety net. If fallback poll detects missed notifications, re-establish the LISTEN connection
- **Same `readCategories` data path** — LISTEN is just the wakeup signal, not data delivery. Notification payload (global position) is used as a hint, not trusted
- **Same `AsyncSequence<RecordedEvent>` conformance** — drop-in replacement for `EventSubscription`
- **Existing `NOTIFY songbird_events`** in PostgresEventStore is already wired (fire-and-forget after each append)

---

## Feature 2: S3 Cloud Tiering

### Goal

Add S3 backend support to DuckLake-based tiered storage, enabling cold-tier Parquet files to be stored in S3-compatible object stores (AWS S3, rustfs, Garage, MinIO, R2).

### Architecture

Extend `DuckLakeConfig.Backend` to support `.s3(S3Config)`. ReadModelStore emits DuckDB `SET` statements for S3 configuration on init. DuckLake handles Parquet I/O transparently — no changes to tiering logic.

### S3Config

```swift
public struct S3Config: Sendable {
    public var region: String?          // nil = use AWS_REGION env var
    public var accessKeyId: String?     // nil = use AWS_ACCESS_KEY_ID env var
    public var secretAccessKey: String? // nil = use AWS_SECRET_ACCESS_KEY env var
    public var endpoint: String?        // nil = default AWS; set for S3-compatible stores
    public var useSsl: Bool             // default true; false for local dev servers
}
```

### DuckLakeConfig.Backend

```swift
public enum Backend: Sendable {
    case local
    case s3(S3Config)
}
```

### ReadModelStore Changes

On init with `.tiered(config)` where backend is `.s3`:

1. Load DuckDB's `httpfs` extension (`INSTALL httpfs; LOAD httpfs`)
2. Emit `SET` statements for any explicit S3Config fields (nil fields fall back to env vars)
3. `dataPath` uses an S3 URI (`s3://bucket/prefix/`)
4. DuckLake handles Parquet read/write to S3 transparently

`tierProjections(olderThan:)` is unchanged — DuckLake abstracts the storage location.

### What Doesn't Change

- `StorageMode` enum — `.tiered(DuckLakeConfig)` already exists
- `TieringService` — unchanged
- Projector code — unchanged
- Hot tier — still native DuckDB

### Testing

- **Unit tests**: Verify correct `SET` SQL statements are generated for various S3Config combinations (all fields set, some nil, endpoint override, useSsl=false). No S3 connection needed.
- **Integration tests** (opt-in via env var): Start rustfs or Garage in Docker, create bucket, run actual tiering with S3 data path, verify data lands in S3 and queries work through the UNION ALL view.

### Key Decisions

- **S3 only** for this iteration — GCS/Azure can be added as additional Backend cases later without breaking changes
- **Explicit config overrides env vars** — S3Config fields that are nil fall back to standard AWS environment variables
- **`endpoint` + `useSsl`** — enables S3-compatible stores (rustfs, Garage, MinIO, R2) for both dev and production
