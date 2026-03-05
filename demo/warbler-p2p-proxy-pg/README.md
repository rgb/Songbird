# Warbler P2P + Proxy (Postgres)

Postgres-backed version of the P2P + Proxy Warbler demo. A reverse proxy on `:8080` forwards requests to 4 Postgres-backed P2P services, providing a unified API identical to the monolith.

This variant contains no Swift code — it launches the Postgres P2P services from `warbler-p2p-pg` and the proxy from `warbler-p2p-proxy`.

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

This checks Postgres is running, builds both packages, and starts 5 processes (4 services + proxy). Press Ctrl+C to stop.

## API Examples

All requests go through the proxy on `:8080`:

```bash
# Create a user
curl -X POST http://localhost:8080/users/alice \
  -H "Content-Type: application/json" \
  -d '{"email": "alice@example.com", "displayName": "Alice"}'

# Publish a video
curl -X POST http://localhost:8080/videos/vid-1 \
  -H "Content-Type: application/json" \
  -d '{"title": "Swift Concurrency", "description": "A deep dive", "creatorId": "alice"}'

# Health check
curl http://localhost:8080/health
```

## Architecture

```
HTTP Client
    |
    v
+----------------------+
|  WarblerProxy :8080  |  Pure HTTP forwarding (no event store)
|  (from warbler-p2p-  |
|   proxy package)     |
+------+---------------+
       | HTTP
       +-- /users/*          -> :8081 (Identity)
       +-- /videos/*         -> :8082 (Catalog)
       +-- /subscriptions/*  -> :8083 (Subscriptions)
       +-- /analytics/*      -> :8084 (Analytics)
                                  |
                                  v
                          +--------------+
                          |  PostgreSQL   |
                          |  (shared)     |
                          +--------------+
```

## Comparison

| Aspect | P2P (SQLite) | P2P + Proxy (Postgres) |
|--------|-------------|----------------------|
| Entry point | 4 ports | Single port (:8080) |
| Event store | Shared SQLite file | Shared Postgres database |
| Position persistence | Lost on restart | Survives restart |
| Proxy intelligence | N/A | Pure HTTP forwarding |
| Prerequisites | None | Running Postgres instance |
