# Warbler Distributed (Postgres)

Postgres-backed version of the distributed Warbler demo. Identical architecture to `warbler-distributed` — a Gateway process on `:8080` forwards HTTP requests to 4 domain workers via distributed actors — but uses PostgreSQL instead of SQLite for the event store, position store, and snapshot store.

## Prerequisites

A running PostgreSQL instance. Start one with Docker:

```bash
docker run -d --name warbler-postgres \
  -e POSTGRES_USER=warbler -e POSTGRES_PASSWORD=warbler \
  -e POSTGRES_DB=warbler -p 5432:5432 postgres:16
```

## Quick Start

```bash
./launch.sh
```

This checks Postgres is running, builds, and starts 5 processes (4 workers + gateway). Press Ctrl+C to stop.

## Configuration

Postgres connection is configured via environment variables:

| Variable | Default |
|----------|---------|
| `POSTGRES_HOST` | `localhost` |
| `POSTGRES_PORT` | `5432` |
| `POSTGRES_USER` | `warbler` |
| `POSTGRES_PASSWORD` | `warbler` |
| `POSTGRES_DB` | `warbler` |

## API Examples

Same API as the SQLite variant, all on `:8080`:

```bash
# Create a user
curl -X POST http://localhost:8080/users/alice \
  -H "Content-Type: application/json" \
  -d '{"email": "alice@example.com", "displayName": "Alice"}'

# Publish a video
curl -X POST http://localhost:8080/videos/vid-1 \
  -H "Content-Type: application/json" \
  -d '{"title": "Swift Concurrency", "description": "A deep dive", "creatorId": "alice"}'

# Record a view
curl -X POST http://localhost:8080/analytics/views \
  -H "Content-Type: application/json" \
  -d '{"videoId": "vid-1", "userId": "alice", "watchedSeconds": 120}'
```

## Architecture

```
HTTP Client
    |
    v
+----------------------+
|  Gateway :8080       |  No event store — pure forwarding
|  (Hummingbird)       |
+------+---------------+
       | Distributed Actors (Unix sockets)
       +-- Identity Worker     -> PostgreSQL + identity.duckdb
       +-- Catalog Worker      -> PostgreSQL + catalog.duckdb
       +-- Subscriptions Worker -> PostgreSQL + subscriptions.duckdb
       +-- Analytics Worker    -> PostgreSQL + analytics.duckdb
```

All workers share the same PostgreSQL database for events, positions, and snapshots. Each worker has its own DuckDB read model.

## Differences from SQLite Variant

| Aspect | SQLite Variant | Postgres Variant |
|--------|---------------|-----------------|
| Event store | SQLiteEventStore (shared file) | PostgresEventStore (shared database) |
| Position store | SQLitePositionStore | PostgresPositionStore |
| Snapshot store | SQLiteSnapshotStore | PostgresSnapshotStore |
| Concurrency | `BEGIN IMMEDIATE` file lock | UNIQUE constraint + transactions |
| Position persistence | Survives restart | Survives restart |
| Prerequisites | None | Running Postgres instance |
| Worker CLI args | `<sqlite-path> <duckdb-path> <socket-path>` | `<duckdb-path> <socket-path>` |
