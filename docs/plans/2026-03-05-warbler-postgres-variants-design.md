# Warbler Postgres Variants Design

## Overview

Postgres-backed versions of all three multi-process Warbler demos, swapping `SQLiteEventStore` for `PostgresEventStore`. Each worker/service gets its own `PostgresClient` connection pool to the same Postgres database. No `BEGIN IMMEDIATE` workaround — Postgres handles concurrent connections natively.

**Name:** Warbler Postgres Variants (distributed-pg, p2p-pg, p2p-proxy-pg)

**Scope:** Three new demo packages. Domain code is unchanged — only store initialization differs. The proxy variant is just a launch script (no new Swift code).

## Package Structure

```
demo/warbler-distributed-pg/       # Gateway + 4 workers, Postgres event store
├── Package.swift
├── Sources/
│   ├── WarblerGateway/             # Unchanged from SQLite variant
│   ├── WarblerIdentityWorker/
│   ├── WarblerCatalogWorker/
│   ├── WarblerSubscriptionsWorker/
│   └── WarblerAnalyticsWorker/
├── launch.sh
└── README.md

demo/warbler-p2p-pg/               # 4 independent services, Postgres event store
├── Package.swift
├── Sources/
│   ├── WarblerIdentityService/
│   ├── WarblerCatalogService/
│   ├── WarblerSubscriptionsService/
│   └── WarblerAnalyticsService/
├── launch.sh
└── README.md

demo/warbler-p2p-proxy-pg/         # Proxy + 4 Postgres P2P services
├── launch.sh                       # Starts warbler-p2p-pg services + warbler-p2p-proxy proxy
└── README.md
```

## Changes from SQLite Variants

### Dependency Swap

Per service/worker:
- Remove: `SongbirdSQLite`, `SongbirdTesting`
- Add: `SongbirdPostgres`

`SongbirdTesting` was only needed for `InMemoryPositionStore` and `InMemorySnapshotStore`. Postgres variants use `PostgresPositionStore` and `PostgresSnapshotStore` instead.

### Store Initialization

```swift
// SQLite variant:
let eventStore = try SQLiteEventStore(path: sqlitePath, registry: registry)
let positionStore = InMemoryPositionStore()
let snapshotStore = InMemorySnapshotStore()  // analytics only

// Postgres variant:
let client = PostgresClient(configuration: pgConfig)
try await SongbirdPostgresMigrations.apply(client: client, logger: logger)
let eventStore = PostgresEventStore(client: client, registry: registry)
let positionStore = PostgresPositionStore(client: client)
let snapshotStore = PostgresSnapshotStore(client: client)  // analytics only
```

### Client Lifecycle

Each service/worker adds `client.run()` to its task group:

```swift
try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { await client.run() }
    group.addTask { try await services.run() }
    group.addTask { try await app.runService() }  // P2P services only
    try await group.waitForAll()
}
```

### Postgres Configuration

All services read from environment variables with defaults:

```swift
let pgConfig = PostgresClient.Configuration(
    host: env("POSTGRES_HOST") ?? "localhost",
    port: Int(env("POSTGRES_PORT") ?? "5432") ?? 5432,
    username: env("POSTGRES_USER") ?? "warbler",
    password: env("POSTGRES_PASSWORD") ?? "warbler",
    database: env("POSTGRES_DB") ?? "warbler",
    tls: .disable
)
```

### Migrations

Each service calls `SongbirdPostgresMigrations.apply(...)` at startup. Migrations are idempotent — safe for concurrent execution by multiple services.

## Per-Variant Details

### warbler-distributed-pg

- Gateway is unchanged (no event store — only forwards distributed actor calls)
- 4 workers swap SQLite for Postgres stores
- Workers drop the SQLite path CLI argument; Postgres config from env vars
- Workers still take DuckDB path and socket path as CLI args
- Launch script removes `SQLITE_PATH`, adds Postgres readiness check

### warbler-p2p-pg

- 4 independent Hummingbird services swap SQLite for Postgres stores
- Each service adds `client.run()` to its task group
- Ports remain 8081-8084
- Launch script adds Postgres readiness check

### warbler-p2p-proxy-pg

- No new Swift code — the proxy is pure HTTP forwarding, unchanged
- Launch script starts 4 Postgres P2P services from `warbler-p2p-pg` + proxy from `warbler-p2p-proxy`
- Just a launch script and README

## Data Layout

```
PostgreSQL database "warbler"     # Shared write model (events, positions, snapshots tables)
data/identity.duckdb              # Per-service read model (unchanged)
data/catalog.duckdb
data/subscriptions.duckdb
data/analytics.duckdb
```

## Launch Script Pattern

Each launch script checks Postgres is running before starting services:

```bash
pg_isready -h localhost -p 5432 -U warbler || {
    echo "Postgres is not running. Start it with:"
    echo "  docker run -d --name warbler-postgres \\"
    echo "    -e POSTGRES_USER=warbler -e POSTGRES_PASSWORD=warbler \\"
    echo "    -e POSTGRES_DB=warbler -p 5432:5432 postgres:16"
    exit 1
}
```

## Key Differences from SQLite Variants

| Aspect | SQLite Variant | Postgres Variant |
|--------|---------------|-----------------|
| Event store | SQLiteEventStore (shared file) | PostgresEventStore (shared database) |
| Position store | InMemoryPositionStore | PostgresPositionStore |
| Snapshot store | InMemorySnapshotStore | PostgresSnapshotStore |
| Concurrency | `BEGIN IMMEDIATE` file lock | UNIQUE constraint + transactions |
| Position persistence | Lost on restart | Survives restart |
| Dependencies | SongbirdSQLite, SongbirdTesting | SongbirdPostgres |
| Data directory | SQLite file + DuckDB files | DuckDB files only (Postgres is external) |
| Prerequisites | None | Running Postgres instance |

## Testing

Manual smoke test via curl — same API examples as the SQLite variants. Each README documents the Docker command to start Postgres and the curl examples.

## Known Limitations

- Requires a running Postgres instance (Docker recommended for development)
- No TLS configuration in defaults (development only)
- No connection retry beyond what PostgresNIO provides
