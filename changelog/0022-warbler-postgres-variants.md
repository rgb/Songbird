# Warbler Postgres Variants

Added Postgres-backed versions of all three multi-process Warbler demos:

## warbler-distributed-pg

Gateway + 4 workers using PostgresEventStore, PostgresPositionStore, and PostgresSnapshotStore instead of SQLite equivalents. Gateway is unchanged (no event store). Workers take 2 CLI args (duckdb-path, socket-path) instead of 3 — Postgres config comes from environment variables.

## warbler-p2p-pg

4 independent Hummingbird services using Postgres stores instead of SQLite + in-memory stores. Positions and snapshots now survive restarts (PostgresPositionStore/PostgresSnapshotStore replace InMemoryPositionStore/InMemorySnapshotStore).

## warbler-p2p-proxy-pg

Launch script + README only — starts 4 Postgres P2P services from warbler-p2p-pg plus the proxy from warbler-p2p-proxy. No new Swift code.

## Key Changes

- **Dependency swap**: SongbirdSQLite (+ SongbirdTesting) -> SongbirdPostgres
- **Store initialization**: PostgresClient with env var config, SongbirdPostgresMigrations at startup, client.run() in task group
- **Launch scripts**: Postgres readiness check via pg_isready, Docker instructions on failure
- **Domain code**: Zero changes — only store initialization differs
