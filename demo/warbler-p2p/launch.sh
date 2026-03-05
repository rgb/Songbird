#!/bin/bash
set -e

# Warbler P2P — Launch all 4 domain services
# Each service writes to a shared SQLite event store and its own DuckDB read model.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Ensure data directory exists
mkdir -p data

# Build all services
echo "Building all services..."
swift build

PIDS=()

cleanup() {
    echo ""
    echo "Shutting down all services..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait
    echo "All services stopped."
}

trap cleanup SIGINT SIGTERM

# Start each service
echo "Starting services..."

swift run WarblerIdentityService &
PIDS+=($!)

swift run WarblerCatalogService &
PIDS+=($!)

swift run WarblerSubscriptionsService &
PIDS+=($!)

swift run WarblerAnalyticsService &
PIDS+=($!)

echo ""
echo "Warbler P2P is running:"
echo "  Identity      → http://localhost:8081"
echo "  Catalog       → http://localhost:8082"
echo "  Subscriptions → http://localhost:8083"
echo "  Analytics     → http://localhost:8084"
echo ""
echo "Press Ctrl+C to stop all services."

# Wait for any process to exit
wait
