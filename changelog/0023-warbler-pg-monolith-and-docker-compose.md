# Warbler Postgres Monolith + Docker Compose

## warbler-pg

Postgres-backed version of the Warbler monolith. All four domains in a single process on `:8080`, using `PostgresEventStore`, `PostgresPositionStore`, and `PostgresSnapshotStore` instead of in-memory equivalents. Domain code and routes are unchanged.

## Docker Compose

Added `docker-compose.yml` to all four Postgres demos:

| Demo | Services |
|------|----------|
| warbler-pg | postgres |
| warbler-distributed-pg | postgres |
| warbler-p2p-pg | postgres |
| warbler-p2p-proxy-pg | postgres + nginx |

The `warbler-p2p-proxy-pg` compose file includes an nginx reverse proxy that replaces the Swift WarblerProxy, forwarding by URL prefix to the 4 P2P services running natively.

All Postgres services use identical config: `postgres:16`, `warbler/warbler` credentials, port 5432, named volume for data persistence.
