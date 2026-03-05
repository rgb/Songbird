# Warbler P2P (Postgres)

Postgres-backed version of the P2P Warbler demo. Identical architecture to `warbler-p2p` — 4 independent Hummingbird services on dedicated ports, communicating through a shared event store — but uses PostgreSQL instead of SQLite.

## Prerequisites

A running PostgreSQL instance. Start one with Docker Compose:

```bash
docker compose up -d
```

Or manually:

```bash
docker run -d --name warbler-postgres \
  -e POSTGRES_USER=warbler -e POSTGRES_PASSWORD=warbler \
  -e POSTGRES_DB=warbler -p 5432:5432 postgres:16
```

## Quick Start

```bash
./launch.sh
```

This checks Postgres is running, builds, and starts all 4 services. Press Ctrl+C to stop.

## Configuration

Postgres connection is configured via environment variables:

| Variable | Default |
|----------|---------|
| `POSTGRES_HOST` | `localhost` |
| `POSTGRES_PORT` | `5432` |
| `POSTGRES_USER` | `warbler` |
| `POSTGRES_PASSWORD` | `warbler` |
| `POSTGRES_DB` | `warbler` |

## Services

| Port | Service | Domain |
|------|---------|--------|
| 8081 | WarblerIdentityService | Users |
| 8082 | WarblerCatalogService | Videos |
| 8083 | WarblerSubscriptionsService | Subscriptions |
| 8084 | WarblerAnalyticsService | Analytics |

## API Examples

Same API as the SQLite P2P variant:

```bash
# Create a user
curl -X POST http://localhost:8081/users/alice \
  -H "Content-Type: application/json" \
  -d '{"email": "alice@example.com", "displayName": "Alice"}'

# Publish a video
curl -X POST http://localhost:8082/videos/vid-1 \
  -H "Content-Type: application/json" \
  -d '{"title": "Swift Concurrency", "description": "A deep dive", "creatorId": "alice"}'

# Record a view
curl -X POST http://localhost:8084/analytics/views \
  -H "Content-Type: application/json" \
  -d '{"videoId": "vid-1", "userId": "alice", "watchedSeconds": 120}'
```

## Architecture

```
HTTP Clients
    |
    +-- :8081 --> Identity (users)
    +-- :8082 --> Catalog (videos)
    +-- :8083 --> Subscriptions (plans, payments)
    +-- :8084 --> Analytics (views, metrics)
                      |
                      v
            +-------------------+
            | PostgreSQL        |  <-- Shared event store
            | (all 4 write)     |
            +-------------------+
```

Each service has its own DuckDB read model (`data/*.duckdb`). Cross-domain coordination happens through event subscriptions polling the shared Postgres event store.

## Differences from SQLite P2P Variant

| Aspect | SQLite P2P | Postgres P2P |
|--------|-----------|-------------|
| Event store | SQLiteEventStore (shared file) | PostgresEventStore (shared database) |
| Position store | InMemoryPositionStore | PostgresPositionStore |
| Snapshot store | InMemorySnapshotStore | PostgresSnapshotStore |
| Concurrency | `BEGIN IMMEDIATE` file lock | UNIQUE constraint + transactions |
| Position persistence | Lost on restart | Survives restart |
| Dependencies | SongbirdSQLite, SongbirdTesting | SongbirdPostgres |
| Prerequisites | None | Running Postgres instance |
