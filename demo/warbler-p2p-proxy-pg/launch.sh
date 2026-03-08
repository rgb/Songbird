#!/bin/bash
set -e

# Warbler P2P + Proxy (Postgres) — Starts 4 Postgres P2P services + reverse proxy
# The proxy is unchanged — it forwards HTTP requests by URL prefix.
# The backend services use PostgreSQL instead of SQLite.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEMO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Check Postgres is running
pg_isready -h "${POSTGRES_HOST:-localhost}" -p "${POSTGRES_PORT:-5432}" -U "${POSTGRES_USER:-warbler}" || {
    echo "Postgres is not running. Start it with:"
    echo "  docker run -d --name warbler-postgres \\"
    echo "    -e POSTGRES_USER=warbler -e POSTGRES_PASSWORD=warbler \\"
    echo "    -e POSTGRES_DB=warbler -p 5432:5432 postgres:16"
    exit 1
}

# Build both packages
echo "Building P2P (Postgres) services..."
cd "$DEMO_DIR/warbler-p2p-pg"
mkdir -p data
swift build

echo "Building proxy..."
cd "$DEMO_DIR/warbler-p2p-proxy"
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

# Start P2P services (from warbler-p2p-pg)
echo "Starting Postgres P2P services..."
cd "$DEMO_DIR/warbler-p2p-pg"

swift run WarblerIdentityService &
PIDS+=($!)

swift run WarblerCatalogService &
PIDS+=($!)

swift run WarblerSubscriptionsService &
PIDS+=($!)

swift run WarblerAnalyticsService &
PIDS+=($!)

# Wait for services to start
for p in 8081 8082 8083 8084; do
    until nc -z localhost $p 2>/dev/null; do sleep 0.2; done
done

# Start proxy (from warbler-p2p-proxy)
echo "Starting proxy..."
cd "$DEMO_DIR/warbler-p2p-proxy"
swift run WarblerProxy &
PIDS+=($!)

echo ""
echo "Warbler P2P + Proxy (Postgres) is running:"
echo "  Proxy         → http://localhost:8080 (unified API)"
echo "  Identity      → http://localhost:8081"
echo "  Catalog       → http://localhost:8082"
echo "  Subscriptions → http://localhost:8083"
echo "  Analytics     → http://localhost:8084"
echo ""
echo "Press Ctrl+C to stop all services."

# Wait for any process to exit
wait
