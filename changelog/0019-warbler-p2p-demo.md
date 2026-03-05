# 0019 — Warbler P2P Demo App

Peer-to-peer multi-process version of the Warbler demo. Each bounded context runs as its own Hummingbird HTTP server on a dedicated port, all writing to a shared SQLite event store.

## What It Demonstrates

- **Garofolo's "message store as transport"**: The shared SQLite event store is the sole communication mechanism between services. No RPC, no message broker, no distributed actors.
- **Independent process deployment**: Each domain (Identity :8081, Catalog :8082, Subscriptions :8083, Analytics :8084) runs independently with its own DuckDB read model.
- **Zero domain code changes**: Reuses the exact same WarblerIdentity, WarblerCatalog, WarblerSubscriptions, and WarblerAnalytics modules from the monolith.
- **Cross-domain coordination**: Services subscribe to event categories in the shared store (e.g., Subscriptions process manager reads subscription events, emits lifecycle events that other services can consume).

## Package Structure

```
demo/warbler-p2p/
├── Package.swift
├── Sources/
│   ├── WarblerIdentityService/         # :8081
│   ├── WarblerCatalogService/          # :8082
│   ├── WarblerSubscriptionsService/    # :8083
│   └── WarblerAnalyticsService/        # :8084
├── launch.sh
└── README.md
```

## How to Run

```bash
cd demo/warbler-p2p
./launch.sh
```

## Key Differences from Monolith

| Aspect | Monolith | P2P |
|--------|----------|-----|
| Processes | 1 | 4 |
| Communication | In-process | Shared event store |
| Entry point | :8080 | 4 separate ports |
| Read models | 1 shared DuckDB | 4 per-service DuckDB files |
