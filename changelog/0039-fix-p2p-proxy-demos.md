# Fix P2P + proxy demo apps

## Changes

### P2P SQLite services (warbler-p2p)
- Made file paths configurable via `SQLITE_PATH` and `DUCKDB_PATH` environment variables (with sensible defaults)
- Made port configurable via `PORT` environment variable
- Replaced `InMemoryPositionStore` with `SQLitePositionStore` (shares the SQLite path with the event store)
- Removed `import SongbirdTesting` from all 4 services
- Removed `SongbirdTesting` dependency from `Package.swift` for all 4 targets

### P2P Postgres services (warbler-p2p-pg)
- Made DuckDB path configurable via `DUCKDB_PATH` environment variable
- Made port configurable via `PORT` environment variable
- Made bind host configurable via `BIND_HOST` environment variable (default: `localhost`)
- Consolidated double `client.run()` into single task group pattern (one outer group with `client.run()` + a task that runs migrations then starts services)

### Analytics services (both SQLite and PG)
- Removed dead `_viewCountRepo` code (unused `AggregateRepository<ViewCountAggregate>`)
- Removed unused `InMemorySnapshotStore` / `PostgresSnapshotStore` creation

### Proxy (warbler-p2p-proxy)
- Replaced manual JSON string interpolation in `healthCheck()` with `JSONEncoder` and a `Codable` struct

### nginx config (warbler-p2p-proxy-pg)
- Removed trailing slashes from location blocks (`/users/` -> `/users`, etc.) so paths like `/users/alice` match correctly
