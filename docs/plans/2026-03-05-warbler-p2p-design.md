# Warbler P2P Demo App Design

## Overview

Warbler P2P is the peer-to-peer multi-process version of the Warbler demo app. Each bounded context runs as its own Hummingbird HTTP server on a dedicated port, writing directly to a shared SQLite event store. No gateway, no distributed actors — pure Garofolo "message store as transport" pattern.

**Name:** Warbler P2P (builds on the Warbler monolith's domain modules)

**Scope:** 4 independent domain service executables. Same HTTP API as the monolith (split across 4 ports). Demonstrates that event-sourced domain modules can run as independent processes communicating solely through the shared event store.

**Architecture:** Each service is a standalone Hummingbird app owning its domain's full event-sourcing stack. Cross-domain coordination happens through the shared event store — services subscribe to event categories they care about.

## Prerequisites

1. **SQLiteEventStore TOCTOU fix:** The `BEGIN IMMEDIATE` transaction fix from the distributed demo must be in place. Multiple processes writing to the same SQLite file requires atomic version-check-then-insert.

2. **Warbler monolith complete:** The domain modules (`WarblerIdentity`, `WarblerCatalog`, `WarblerSubscriptions`, `WarblerAnalytics`) must be built and tested. They are reused as-is.

## Package Structure

```
demo/warbler-p2p/
├── Package.swift
├── Sources/
│   ├── WarblerIdentityService/         # :8081 — Users
│   ├── WarblerCatalogService/          # :8082 — Videos
│   ├── WarblerSubscriptionsService/    # :8083 — Subscriptions
│   └── WarblerAnalyticsService/        # :8084 — Analytics
├── launch.sh                           # Starts all 4 processes
└── README.md
```

**Dependencies per executable:**
- Each imports: `Songbird`, `SongbirdSQLite`, `SongbirdSmew`, `SongbirdHummingbird`, and its own domain module
- Cross-domain subscriptions import other domains' event types only (for deserialization)

## Architecture

```
HTTP Clients
    │
    ├── :8081 ──▶ WarblerIdentityService
    ├── :8082 ──▶ WarblerCatalogService
    ├── :8083 ──▶ WarblerSubscriptionsService
    └── :8084 ──▶ WarblerAnalyticsService
                        │
                        ▼
              ┌─────────────────────┐
              │  songbird.sqlite    │  ◀── Shared event store
              │  (all 4 write here) │      (BEGIN IMMEDIATE)
              └─────────────────────┘
                        │
              Each service also has:
              ├── Own DuckDB read model
              ├── Own ProjectionPipeline
              └── Own EventSubscriptions
```

## Per-Service Architecture

Each service follows the same startup pattern — the relevant section of the monolith's `main.swift` extracted into its own executable:

### Startup Flow

1. Create `EventTypeRegistry` — register own domain events + any cross-domain events
2. Create `SQLiteEventStore` (shared file path, safe with `BEGIN IMMEDIATE`)
3. Create `InMemoryPositionStore` (or `SQLitePositionStore` if available)
4. Create `ReadModelStore` (own DuckDB file — per-process, not shared)
5. Create projectors, register migrations, run migrations
6. Create `SongbirdServices` — register projectors, process managers, gateways, injectors
7. Create Hummingbird `Router` with `RequestIdMiddleware` + `ProjectionFlushMiddleware`
8. Register domain routes
9. Run services + app in a task group

### Data Layout

```
data/
├── songbird.sqlite              # Shared event store (all 4 processes write here)
├── identity.duckdb              # Identity service read model
├── catalog.duckdb               # Catalog service read model
├── subscriptions.duckdb         # Subscriptions service read model
└── analytics.duckdb             # Analytics service read model
```

## Cross-Domain Event Flow

Cross-domain coordination uses the Garofolo pattern: the shared event store IS the transport.

**Example:** Subscription lifecycle → Email notification
1. Subscriptions service's `SubscriptionLifecycleProcess` appends `AccessGranted` to the event store
2. The `EmailNotificationGateway` (also in Subscriptions service) picks it up via subscription
3. Gateway logs "would send email" (no real email)

**Example:** Subscription confirmation → cross-domain visibility
1. Subscriptions service appends `PaymentConfirmed` + process manager emits `AccessGranted`
2. Any other service subscribing to subscription events sees these through the shared store

**Component ownership:**
- `EmailNotificationGateway` → Subscriptions service (it consumes subscription lifecycle events)
- `PlaybackInjector` → Analytics service (it ingests external playback events)
- `SubscriptionLifecycleProcess` → Subscriptions service

## HTTP API

Identical endpoints to the monolith, split across 4 ports:

| Port | Service | Routes |
|------|---------|--------|
| `:8081` | Identity | `POST/GET/PATCH/DELETE /users/{id}` |
| `:8082` | Catalog | `POST/GET/PATCH/DELETE /videos/{id}`, `GET /videos`, `POST /videos/{id}/transcode-complete` |
| `:8083` | Subscriptions | `POST /subscriptions/{id}`, `GET /subscriptions/{userId}`, `POST /subscriptions/{id}/pay` |
| `:8084` | Analytics | `POST /analytics/views`, `GET /analytics/videos/{id}/views`, `GET /analytics/top-videos` |

Same request/response formats as the monolith — just different base URLs.

## Testing Strategy

- **Domain tests:** Unchanged from monolith. Same `TestAggregateHarness`, `TestProjectorHarness`, etc. Domain modules are tested independently.
- **Integration tests:** Launch all 4 services, hit each on its port, verify end-to-end flow including cross-domain event propagation.

## Feature Coverage

| Feature | Where |
|---------|-------|
| Peer-to-peer architecture | 4 independent Hummingbird servers |
| Shared event store (multi-writer) | SQLiteEventStore with `BEGIN IMMEDIATE` fix |
| Message store as transport | Cross-domain event subscriptions via shared store |
| Per-process read models | Each service has own DuckDB |
| Independent deployability | Each service starts/stops independently |
| No single point of failure | No gateway process required |
| Same domain modules | Zero changes to domain code |

## Key Differences from Other Demos

| Aspect | Monolith | Distributed | P2P |
|--------|----------|-------------|-----|
| Processes | 1 | 5 (gateway + 4 workers) | 4 |
| Communication | In-process | Distributed actors (Unix sockets) | Shared event store only |
| Single entry point | Yes (:8080) | Yes (:8080 gateway) | No (4 ports) |
| Framework module | None | SongbirdDistributed | None |
| Complexity | Lowest | Highest | Medium |

## Implementation Order

1. Scaffold `demo/warbler-p2p/` package
2. Build Identity service (simplest domain)
3. Build Catalog service
4. Build Subscriptions service (has process manager + gateway)
5. Build Analytics service (has injector)
6. Create launch script
7. Integration testing
8. Documentation

## Known Limitations

- Clients must know which port serves which domain (no unified entry point)
- No service discovery — ports are hardcoded
- No health checks or process supervision (use systemd, launchd, or similar)
- DuckDB read models cannot be shared across processes
- `InMemoryPositionStore` resets on restart (position tracking is a performance optimization; idempotent handlers ensure correctness)

## Future: Approach 2 (+ Reverse Proxy)

After this demo is complete, a variant adds a thin reverse proxy on `:8080` that routes by URL prefix to the 4 domain services. Same 4 services, but clients see a unified API like the monolith. Demonstrates how P2P services can be fronted by a simple HTTP router without any framework-level RPC.
