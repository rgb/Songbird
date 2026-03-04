# Warbler Distributed Demo App Design

## Overview

Warbler Distributed is the multi-executable version of the Warbler demo app. It splits each bounded context into its own process, communicating through a shared SQLite event store and a new `SongbirdDistributed` module that provides cross-process command dispatch via Swift Distributed Actors over Unix domain sockets.

**Name:** Warbler Distributed (builds on the Warbler monolith's domain modules)

**Scope:** API gateway + 4 domain worker executables. Same HTTP API as the monolith. Demonstrates that event-sourced domain modules can move from monolith to distributed deployment with zero domain code changes.

**Architecture:** Approach 1 (Distributed Actor Command Gateway) — a single API gateway accepts HTTP requests and forwards commands to domain-specific worker processes via distributed actors. Workers own their domain's full event-sourcing stack. Cross-domain coordination happens through the shared event store (Garofolo's "message store as transport" pattern).

## Prerequisites

Two framework changes must be completed before this demo:

1. **Fix SQLiteEventStore TOCTOU race:** Add `BEGIN IMMEDIATE` transaction around the version-check-then-insert sequence in `append()`. Currently, the actor serializes within a single process, but concurrent writes from multiple processes can read the same version before either inserts. `BEGIN IMMEDIATE` acquires a write lock at the start, making the sequence atomic across all connections.

2. **Warbler monolith complete:** The domain modules (`WarblerIdentity`, `WarblerCatalog`, `WarblerSubscriptions`, `WarblerAnalytics`) must be built and tested. They are reused as-is.

## New Framework Module: SongbirdDistributed

A new Songbird module providing a custom `DistributedActorSystem` for same-machine inter-process communication.

### Package Structure

```
Sources/SongbirdDistributed/
├── SongbirdActorSystem.swift        # Custom DistributedActorSystem
├── SongbirdActorID.swift            # Process-aware actor identity
├── InvocationEncoder.swift          # Codable argument serialization
├── InvocationDecoder.swift          # Argument deserialization
├── ResultHandler.swift              # Return value / error handling
└── Transport.swift                  # NIO-based Unix domain socket transport
```

**Dependencies:** `Songbird` + `swift-nio`

### SongbirdActorSystem

The custom `DistributedActorSystem` implementation:

- **Transport:** Unix domain sockets via swift-nio (same-machine IPC, no network overhead)
- **Socket paths:** Each process binds a socket at a well-known path (e.g., `/tmp/songbird/{process-name}.sock`)
- **Serialization:** `Codable` (JSON encoding, matches Songbird's existing patterns)
- **Actor registry:** Local actors registered by name, resolvable by remote processes
- **Connection management:** Gateway maintains persistent connections to all worker sockets

### SongbirdActorID

```swift
struct SongbirdActorID: Hashable, Sendable, Codable {
    let processName: String   // e.g., "identity-worker"
    let actorName: String     // e.g., "command-handler"
}
```

### How It Works

1. Each worker process creates a `SongbirdActorSystem` and binds a Unix domain socket
2. Workers register distributed actors with well-known names
3. The gateway connects to each worker's socket
4. On a distributed actor call:
   - Arguments serialized via `InvocationEncoder` (JSON)
   - Sent over Unix socket to target process
   - `executeDistributedTarget` (Swift stdlib) dispatches to the local actor
   - Result serialized back over the socket

### Testing

- Unit tests use `LocalTestingDistributedActorSystem` (ships with Swift) — no sockets needed
- Integration tests run two `SongbirdActorSystem` instances in the same process with real Unix sockets

## Demo Package Structure

```
demo/warbler-distributed/
├── Package.swift
├── Sources/
│   ├── WarblerGateway/              # API gateway executable
│   ├── WarblerIdentityWorker/       # Identity domain worker
│   ├── WarblerCatalogWorker/        # Catalog domain worker
│   ├── WarblerSubscriptionsWorker/  # Subscriptions domain worker
│   └── WarblerAnalyticsWorker/      # Analytics domain worker
├── launch.sh                        # Starts all 5 processes
└── README.md
```

**Dependencies:**
- Gateway: `SongbirdHummingbird` + `SongbirdDistributed` + all 4 domain modules
- Workers: `SongbirdSQLite` + `SongbirdSmew` + `SongbirdDistributed` + own domain module

## Architecture

```
HTTP Client
    │
    ▼
┌──────────────────────┐  distributed actor calls   ┌─────────────────────┐
│  WarblerGateway      │ ─────────────────────────▶  │  IdentityWorker     │
│  (Hummingbird :8080) │ ─────────────────────────▶  │  CatalogWorker      │
│  HTTP routes only    │ ─────────────────────────▶  │  SubscriptionsWorker│
│  No event store      │ ─────────────────────────▶  │  AnalyticsWorker    │
│  No read model       │                             └─────────┬───────────┘
└──────────────────────┘                                       │
                                                    Each worker has:
                                                    ├── SQLiteEventStore (shared file)
                                                    ├── ReadModelStore (own DuckDB)
                                                    ├── ProjectionPipeline
                                                    └── Subscriptions
```

### Worker Process Architecture

Each worker is a standalone executable that owns its domain's full stack:

- **SQLiteEventStore** connection to the shared SQLite file (read + write, safe with `BEGIN IMMEDIATE`)
- **ReadModelStore** with its own DuckDB file (per-process, not shared — DuckDB is an embedded single-writer database)
- **ProjectionPipeline** for its domain's projectors
- **EventSubscription** for cross-domain event consumption (polling the shared event store)
- **Distributed actor command handlers** exposed to the gateway

### Worker Startup Flow

```
1. Parse config (SQLite path, DuckDB path, socket path, worker name)
2. Create SongbirdActorSystem, bind Unix domain socket
3. Create SQLiteEventStore (connect to shared SQLite file)
4. Create ReadModelStore (own DuckDB file)
5. Register domain projectors, process managers, gateways
6. Create distributed command handler actor, register with actor system
7. Run (actor system + projection pipeline + subscriptions)
```

### Data Layout

```
data/
├── songbird.sqlite          # Shared event store (all processes write here)
├── identity.duckdb          # Identity worker's read model
├── catalog.duckdb           # Catalog worker's read model
├── subscriptions.duckdb     # Subscriptions worker's read model
└── analytics.duckdb         # Analytics worker's read model
```

### Cross-Domain Event Flow

Cross-domain coordination uses Garofolo's pattern: the shared event store IS the transport.

Example: When a subscription is confirmed, the Subscriptions worker appends `AccessGranted` to the event store. The Identity worker's subscription polls the event store, sees the event, and updates its read model. No distributed actor call needed — pure event-driven coordination.

### Gateway Routing

The gateway is purely a routing process — no event store, no read model. It accepts HTTP requests and forwards them:

- **Command routes** (`POST`, `PATCH`, `DELETE`): Forward to the appropriate worker's distributed command handler
- **Query routes** (`GET`): Forward to the appropriate worker's distributed query handler, which queries its local DuckDB

### Usage Pattern

```swift
// In WarblerIdentityWorker:
distributed actor IdentityCommandHandler {
    typealias ActorSystem = SongbirdActorSystem

    let eventStore: SQLiteEventStore
    let pipeline: ProjectionPipeline

    distributed func registerUser(email: String, displayName: String) async throws -> UUID {
        // Same command handling logic as the monolith
    }

    distributed func getUser(id: UUID) async throws -> UserDTO? {
        // Query local DuckDB read model
    }
}

// In WarblerGateway:
router.post("/users") { request, context in
    let body = try await request.decode(as: RegisterUserRequest.self, context: context)
    let userId = try await identityHandler.registerUser(
        email: body.email, displayName: body.displayName
    )
    return Response(status: .created, body: .init(userId: userId))
}
```

## HTTP API

Identical to the Warbler monolith — same endpoints, same request/response formats. The gateway maps each route to the appropriate worker's distributed actor method.

## Testing Strategy

- **Domain tests:** Unchanged from monolith. Same `TestAggregateHarness`, `TestProjectorHarness`, etc.
- **SongbirdDistributed unit tests:** Actor system with `LocalTestingDistributedActorSystem` (no sockets)
- **SongbirdDistributed integration tests:** Real Unix socket transport between two `SongbirdActorSystem` instances
- **Demo integration tests:** Launch all processes, hit gateway HTTP endpoints, verify end-to-end flow

## Feature Coverage

| Feature | Where |
|---------|-------|
| `SongbirdDistributed` module | New framework module |
| Custom `DistributedActorSystem` | Unix domain socket transport |
| Cross-process command dispatch | Gateway → Worker distributed actor calls |
| Per-process read models | Each worker has own DuckDB |
| Shared event store (multi-writer) | SQLiteEventStore with `BEGIN IMMEDIATE` fix |
| Event-based cross-domain coordination | Workers subscribe to shared event store |
| Same domain modules, different deployment | Zero changes to domain code |

## Implementation Order

1. Fix SQLiteEventStore concurrent writes (`BEGIN IMMEDIATE`)
2. Build `SongbirdDistributed` module (actor system, transport, tests)
3. Build demo executables (gateway + 4 workers)
4. Integration testing
5. Launch script and documentation

## Known Limitations

- Unix domain sockets are local-only (no network distribution)
- No service discovery — socket paths are configured at startup
- No retry/reconnection logic in the transport (MVP)
- DuckDB read models cannot be shared across processes
- No health checks or process supervision (use systemd, launchd, or similar)

## Future: Approach 2 (Peer-to-Peer)

A separate demo where each domain runs as its own HTTP server on a different port, all writing directly to the shared event store. No gateway, no distributed actors — pure Garofolo. Distributed actors used only for optional cross-domain queries.
