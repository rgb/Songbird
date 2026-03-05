# Warbler P2P + Reverse Proxy Design

## Overview

Warbler P2P + Reverse Proxy adds a thin Hummingbird-based reverse proxy on `:8080` in front of the 4 P2P domain services. Clients see a unified API identical to the monolith, while the backend remains 4 independent processes communicating through the shared event store.

**Name:** Warbler P2P Proxy (builds on the Warbler P2P demo)

**Scope:** One reverse proxy executable, nginx and Caddy alternative configs, a launch script, and documentation. The proxy has zero knowledge of event sourcing — it's pure HTTP forwarding.

**Architecture:** Hummingbird HTTP server with AsyncHTTPClient for outbound forwarding. URL-prefix-based routing to 4 backend services. Request logging, health check endpoint, and 502 error handling.

## Package Structure

```
demo/warbler-p2p-proxy/
├── Package.swift
├── Sources/
│   └── WarblerProxy/
│       └── main.swift
├── config/
│   ├── nginx.conf
│   └── Caddyfile
├── launch.sh
└── README.md
```

**Dependencies:** Hummingbird + AsyncHTTPClient. No Songbird, no domain modules.

## Architecture

```
HTTP Client
    │
    ▼
┌──────────────────────┐
│  WarblerProxy :8080  │
│  (Hummingbird)       │
│  - Request logging   │
│  - Health check      │
│  - URL-prefix routing│
└──────┬───────────────┘
       │ AsyncHTTPClient
       ├── /users/*          → localhost:8081
       ├── /videos/*         → localhost:8082
       ├── /subscriptions/*  → localhost:8083
       └── /analytics/*      → localhost:8084
```

## Routing Rules

| Prefix | Backend | Service |
|--------|---------|---------|
| `/users` | `:8081` | Identity |
| `/videos` | `:8082` | Catalog |
| `/subscriptions` | `:8083` | Subscriptions |
| `/analytics` | `:8084` | Analytics |
| `/health` | Local | Health check |

The proxy forwards the full original path (e.g., `/videos/123` → `localhost:8082/videos/123`), preserving method, headers, and body. Returns the backend's response as-is.

## Proxy Implementation

**Forwarding logic:** A single generic handler that:
1. Matches the URL prefix to determine the backend port
2. Constructs an outbound request to `http://localhost:{port}{originalPath}`
3. Copies the HTTP method, headers, and body from the incoming request
4. Sends via AsyncHTTPClient
5. Returns the backend's status code, headers, and body to the client

**Request logging:** Logs method, path, backend port, response status, and duration. `print`-based to match the demo's style.

**Health check:** `GET /health` hits all 4 backends. Returns:
- `200 OK` with `{"status": "healthy", "services": {"identity": "up", ...}}` if all respond
- `503 Service Unavailable` with the same JSON showing which service is down

**Error handling:** If a backend is unreachable, return `502 Bad Gateway` with a JSON body indicating which service failed. No retries.

**AsyncHTTPClient lifecycle:** One `HTTPClient` created at startup, shared across all requests, shut down on exit.

## Alternative Configs

**nginx.conf** (`config/nginx.conf`): Standard reverse proxy config with `upstream` blocks for each service and `location` blocks matching the URL prefixes. Includes request logging and a health check endpoint.

**Caddyfile** (`config/Caddyfile`): Same routing rules in Caddy's compact syntax. `reverse_proxy` directives with path matchers.

Both are provided as ready-to-use alternatives documented in the README but not wired into `launch.sh`.

## Launch Script

Starts all 4 P2P services (by building and running from `demo/warbler-p2p`) plus the proxy on `:8080`. 5 processes total. Same signal handling pattern as the P2P launch script. Builds both packages first.

## HTTP API

Identical to the Warbler monolith — same endpoints, same request/response formats, all on `:8080`:

| Route | Method | Service |
|-------|--------|---------|
| `/users/{id}` | POST/GET/PATCH/DELETE | Identity |
| `/videos/{id}` | POST/GET/PATCH/DELETE | Catalog |
| `/videos` | GET | Catalog |
| `/videos/{id}/transcode-complete` | POST | Catalog |
| `/subscriptions/{id}` | POST | Subscriptions |
| `/subscriptions/{userId}` | GET | Subscriptions |
| `/subscriptions/{id}/pay` | POST | Subscriptions |
| `/analytics/views` | POST | Analytics |
| `/analytics/videos/{id}/views` | GET | Analytics |
| `/analytics/top-videos` | GET | Analytics |
| `/health` | GET | Proxy (local) |

## Key Differences from Other Demos

| Aspect | Monolith | Distributed | P2P | P2P + Proxy |
|--------|----------|-------------|-----|-------------|
| Processes | 1 | 5 (gateway + 4 workers) | 4 | 5 (proxy + 4 services) |
| Communication | In-process | Distributed actors | Shared event store | Shared event store |
| Single entry point | Yes (:8080) | Yes (:8080 gateway) | No (4 ports) | Yes (:8080 proxy) |
| Proxy intelligence | N/A | Command dispatch | N/A | Pure HTTP forwarding |
| Domain knowledge | Full | Gateway knows commands | Per-service | None (URL prefix only) |

## Testing Strategy

Manual smoke test via curl — same commands as the monolith, all targeting `:8080`. The README includes examples.

## Known Limitations

- No load balancing (single instance per service)
- No connection pooling to backends (AsyncHTTPClient defaults)
- No request buffering or rate limiting
- Health check is simple reachability — does not verify functional correctness
- nginx/Caddy configs are alternatives, not integrated into the launch script
