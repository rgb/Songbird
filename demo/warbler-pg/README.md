# Warbler (Postgres)

Postgres-backed version of the Warbler monolith demo. All 4 domains (Identity, Catalog, Subscriptions, Analytics) run in a single process on port 8080, using PostgreSQL for the event store, position store, and snapshot store instead of in-memory stores.

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

This checks Postgres is running, builds, and starts the server on port 8080. Press Ctrl+C to stop.

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

# Get view analytics
curl http://localhost:8080/analytics/videos/vid-1/views

# List all videos
curl http://localhost:8080/videos

# Get a user
curl http://localhost:8080/users/alice

# Create a subscription
curl -X POST http://localhost:8080/subscriptions/sub-1 \
  -H "Content-Type: application/json" \
  -d '{"userId": "alice", "plan": "premium"}'

# Confirm payment
curl -X POST http://localhost:8080/subscriptions/sub-1/pay

# Top videos
curl http://localhost:8080/analytics/top-videos
```

## Differences from In-Memory Variant

| Aspect | In-Memory (`warbler`) | Postgres (`warbler-pg`) |
|--------|----------------------|------------------------|
| Event store | InMemoryEventStore | PostgresEventStore |
| Position store | InMemoryPositionStore | PostgresPositionStore |
| Snapshot store | InMemorySnapshotStore | PostgresSnapshotStore |
| Data persistence | Lost on restart | Survives restart |
| Dependencies | SongbirdTesting | SongbirdPostgres |
| Prerequisites | None | Running Postgres instance |
| Read model | DuckDB (in-memory) | DuckDB (in-memory) |
