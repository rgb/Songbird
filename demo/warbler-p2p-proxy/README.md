# Warbler P2P + Reverse Proxy

Adds a thin reverse proxy on `:8080` in front of the 4 Warbler P2P domain services. Clients see a unified API identical to the monolith, while the backend remains 4 independent processes communicating through the shared event store.

The proxy is a Hummingbird app using AsyncHTTPClient for forwarding. It has zero knowledge of event sourcing — pure HTTP routing by URL prefix.

## Quick Start

```bash
./launch.sh
```

This builds and starts all 4 P2P services plus the proxy (5 processes). Press Ctrl+C to stop.

## Services

| Port | Process | Role |
|------|---------|------|
| 8080 | WarblerProxy | Reverse proxy (unified API) |
| 8081 | WarblerIdentityService | Users |
| 8082 | WarblerCatalogService | Videos |
| 8083 | WarblerSubscriptionsService | Subscriptions |
| 8084 | WarblerAnalyticsService | Analytics |

## API Examples

All requests go to `:8080` — the proxy routes them to the correct backend.

### Create a user
```bash
curl -X POST http://localhost:8080/users/alice \
  -H "Content-Type: application/json" \
  -d '{"email": "alice@example.com", "displayName": "Alice"}'
```

### Get a user
```bash
curl http://localhost:8080/users/alice
```

### Publish a video
```bash
curl -X POST http://localhost:8080/videos/vid-1 \
  -H "Content-Type: application/json" \
  -d '{"title": "Swift Concurrency", "description": "A deep dive", "creatorId": "alice"}'
```

### List videos
```bash
curl http://localhost:8080/videos
```

### Create a subscription
```bash
curl -X POST http://localhost:8080/subscriptions/sub-1 \
  -H "Content-Type: application/json" \
  -d '{"userId": "alice", "plan": "premium"}'
```

### Confirm payment
```bash
curl -X POST http://localhost:8080/subscriptions/sub-1/pay
```

### Record a video view
```bash
curl -X POST http://localhost:8080/analytics/views \
  -H "Content-Type: application/json" \
  -d '{"videoId": "vid-1", "userId": "alice", "watchedSeconds": 120}'
```

### Get video analytics
```bash
curl http://localhost:8080/analytics/videos/vid-1/views
```

### Top videos
```bash
curl http://localhost:8080/analytics/top-videos
```

### Health check
```bash
curl http://localhost:8080/health
```

## Architecture

```
HTTP Client
    |
    v
+------------------------+
| WarblerProxy :8080     |
| - Request logging      |
| - Health check         |
| - URL prefix routing   |
+------+-----------------+
       |
       +-- /users/*          --> :8081 (Identity)
       +-- /videos/*         --> :8082 (Catalog)
       +-- /subscriptions/*  --> :8083 (Subscriptions)
       +-- /analytics/*      --> :8084 (Analytics)
                                  |
                                  v
                        +-------------------+
                        | songbird.sqlite   |  <-- Shared event store
                        +-------------------+
```

## Alternative Proxy Configs

The `config/` directory provides ready-to-use alternatives:

### nginx

```bash
# Start the 4 P2P services first
cd ../warbler-p2p && ./launch.sh &

# Then run nginx
nginx -c $(pwd)/config/nginx.conf
```

### Caddy

```bash
# Start the 4 P2P services first
cd ../warbler-p2p && ./launch.sh &

# Then run Caddy
caddy run --config config/Caddyfile
```

## Comparison with Other Demos

| Aspect | Monolith | Distributed | P2P | P2P + Proxy |
|--------|----------|-------------|-----|-------------|
| Processes | 1 | 5 | 4 | 5 |
| Entry point | :8080 | :8080 (gateway) | 4 ports | :8080 (proxy) |
| Communication | In-process | Distributed actors | Shared store | Shared store |
| Proxy intelligence | N/A | Command dispatch | N/A | URL prefix only |
| Domain knowledge | Full | Gateway knows commands | Per-service | None |
