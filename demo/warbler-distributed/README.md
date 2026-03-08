# Warbler Distributed

A distributed Warbler demo using SQLite for the event store and DuckDB/Smew for read models. A Gateway process on `:8080` forwards HTTP requests to 4 domain workers via distributed actors over Unix sockets.

## Prerequisites

None — SQLite and DuckDB are embedded libraries with no external dependencies.

## Quick Start

```bash
./launch.sh
```

This builds and starts 5 processes (4 workers + gateway). Press Ctrl+C to stop.

## Configuration

| Variable | Default |
|----------|---------|
| `DATA_DIR` | `./data` |
| `SOCKET_DIR` | `/tmp/songbird` |
| `PORT` | `8080` |

Workers use a shared SQLite file at `$DATA_DIR/songbird.sqlite` for events and positions. Each worker has its own DuckDB file for read models (e.g., `$DATA_DIR/identity.duckdb`).

## API Examples

All requests go through the gateway on `:8080`:

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
       +-- Identity Worker      -> songbird.sqlite + identity.duckdb
       +-- Catalog Worker       -> songbird.sqlite + catalog.duckdb
       +-- Subscriptions Worker -> songbird.sqlite + subscriptions.duckdb
       +-- Analytics Worker     -> songbird.sqlite + analytics.duckdb
```

All workers share the same SQLite file for events and positions. Each worker has its own DuckDB read model.
