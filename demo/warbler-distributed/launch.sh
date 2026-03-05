#!/usr/bin/env bash
# launch.sh — Starts all Warbler Distributed processes
set -euo pipefail

# Default paths
DATA_DIR="${DATA_DIR:-./data}"
SOCKET_DIR="${SOCKET_DIR:-/tmp/songbird}"
SQLITE_PATH="${DATA_DIR}/songbird.sqlite"

# Create directories
mkdir -p "$DATA_DIR" "$SOCKET_DIR"

echo "Starting Warbler Distributed..."
echo "  SQLite: $SQLITE_PATH"
echo "  Sockets: $SOCKET_DIR"

# Build if needed
swift build 2>/dev/null || true

# Start workers
PIDS=()
.build/debug/WarblerIdentityWorker "$SQLITE_PATH" "$DATA_DIR/identity.duckdb" "$SOCKET_DIR/identity.sock" &
PIDS+=($!)
.build/debug/WarblerCatalogWorker "$SQLITE_PATH" "$DATA_DIR/catalog.duckdb" "$SOCKET_DIR/catalog.sock" &
PIDS+=($!)
.build/debug/WarblerSubscriptionsWorker "$SQLITE_PATH" "$DATA_DIR/subscriptions.duckdb" "$SOCKET_DIR/subscriptions.sock" &
PIDS+=($!)
.build/debug/WarblerAnalyticsWorker "$SQLITE_PATH" "$DATA_DIR/analytics.duckdb" "$SOCKET_DIR/analytics.sock" &
PIDS+=($!)

# Wait for sockets to be created
sleep 1

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
