#!/usr/bin/env bash
# launch.sh — Starts all Warbler Distributed (Postgres) processes
set -euo pipefail

# Default paths
DATA_DIR="${DATA_DIR:-./data}"
SOCKET_DIR="${SOCKET_DIR:-/tmp/songbird}"

# Create directories
mkdir -p "$DATA_DIR" "$SOCKET_DIR"

# Check Postgres is running
pg_isready -h "${POSTGRES_HOST:-localhost}" -p "${POSTGRES_PORT:-5432}" -U "${POSTGRES_USER:-warbler}" || {
    echo "Postgres is not running. Start it with:"
    echo "  docker run -d --name warbler-postgres \\"
    echo "    -e POSTGRES_USER=warbler -e POSTGRES_PASSWORD=warbler \\"
    echo "    -e POSTGRES_DB=warbler -p 5432:5432 postgres:16"
    exit 1
}

echo "Starting Warbler Distributed (Postgres)..."
echo "  Postgres: ${POSTGRES_HOST:-localhost}:${POSTGRES_PORT:-5432}/${POSTGRES_DB:-warbler}"
echo "  Sockets: $SOCKET_DIR"

# Build if needed
swift build || exit 1

# Start workers
PIDS=()
.build/debug/WarblerIdentityWorker "$DATA_DIR/identity.duckdb" "$SOCKET_DIR/identity.sock" &
PIDS+=($!)
.build/debug/WarblerCatalogWorker "$DATA_DIR/catalog.duckdb" "$SOCKET_DIR/catalog.sock" &
PIDS+=($!)
.build/debug/WarblerSubscriptionsWorker "$DATA_DIR/subscriptions.duckdb" "$SOCKET_DIR/subscriptions.sock" &
PIDS+=($!)
.build/debug/WarblerAnalyticsWorker "$DATA_DIR/analytics.duckdb" "$SOCKET_DIR/analytics.sock" &
PIDS+=($!)

# Wait for sockets to be created
for sock in identity.sock catalog.sock subscriptions.sock analytics.sock; do
    while [ ! -S "$SOCKET_DIR/$sock" ]; do sleep 0.1; done
done

# Start gateway
.build/debug/WarblerGateway &
PIDS+=($!)

echo "All processes started. Gateway at http://localhost:8080"
echo "PIDs: ${PIDS[*]}"

# Wait for any process to exit
wait -n
echo "A process exited. Shutting down..."

# Clean up
for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
done
wait
echo "All processes stopped."
