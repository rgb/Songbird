# Warbler P2P

Peer-to-peer multi-process version of the Warbler demo app. Each bounded context runs as its own Hummingbird HTTP server on a dedicated port, communicating solely through a shared SQLite event store.

This demonstrates Garofolo's "message store as transport" pattern — no gateway, no distributed actors. The event store IS the communication mechanism between services.

## Quick Start

```bash
./launch.sh
```

This builds and starts all 4 services. Press Ctrl+C to stop.

## Services

| Port | Service | Domain |
|------|---------|--------|
| 8081 | WarblerIdentityService | Users |
| 8082 | WarblerCatalogService | Videos |
| 8083 | WarblerSubscriptionsService | Subscriptions |
| 8084 | WarblerAnalyticsService | Analytics |

## API Examples

### Create a user
```bash
curl -X POST http://localhost:8081/users/alice \
  -H "Content-Type: application/json" \
  -d '{"email": "alice@example.com", "displayName": "Alice"}'
```

### Get a user
```bash
curl http://localhost:8081/users/alice
```

### Publish a video
```bash
curl -X POST http://localhost:8082/videos/vid-1 \
  -H "Content-Type: application/json" \
  -d '{"title": "Swift Concurrency", "description": "A deep dive", "creatorId": "alice"}'
```

### List videos
```bash
curl http://localhost:8082/videos
```

### Create a subscription
```bash
curl -X POST http://localhost:8083/subscriptions/sub-1 \
  -H "Content-Type: application/json" \
  -d '{"userId": "alice", "plan": "premium"}'
```

### Confirm payment
```bash
curl -X POST http://localhost:8083/subscriptions/sub-1/pay
```

### Record a video view
```bash
curl -X POST http://localhost:8084/analytics/views \
  -H "Content-Type: application/json" \
  -d '{"videoId": "vid-1", "userId": "alice", "watchedSeconds": 120}'
```

### Get video analytics
```bash
curl http://localhost:8084/analytics/videos/vid-1/views
```

### Top videos
```bash
curl http://localhost:8084/analytics/top-videos
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
            | songbird.sqlite   |  <-- Shared event store
            | (all 4 write)     |
            +-------------------+
```

Each service has its own DuckDB read model (`data/*.duckdb`). Cross-domain coordination happens through event subscriptions polling the shared event store.

## Data

All data is stored in the `data/` directory:
- `songbird.sqlite` — Shared event store
- `identity.duckdb` — Identity read model
- `catalog.duckdb` — Catalog read model
- `subscriptions.duckdb` — Subscriptions read model
- `analytics.duckdb` — Analytics read model

To reset, delete the `data/` directory and restart.

## Comparison with Other Demos

| Aspect | Monolith | P2P |
|--------|----------|-----|
| Processes | 1 | 4 |
| Communication | In-process | Shared event store |
| Single entry point | :8080 | 4 ports |
| Domain code changes | — | Zero |
