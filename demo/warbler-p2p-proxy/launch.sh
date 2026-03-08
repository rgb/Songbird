#!/bin/bash
set -e

# Warbler P2P + Reverse Proxy — Launch all 4 domain services + the proxy
# Clients connect to http://localhost:8080 (unified API).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
P2P_DIR="$SCRIPT_DIR/../warbler-p2p"

cd "$P2P_DIR"

# Ensure data directory exists (used by P2P services)
mkdir -p data

# Build both packages
echo "Building P2P services..."
swift build

echo "Building proxy..."
cd "$SCRIPT_DIR"
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

# Start P2P services
echo "Starting P2P services..."
cd "$P2P_DIR"

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

# Start proxy
echo "Starting proxy..."
cd "$SCRIPT_DIR"

swift run WarblerProxy &
PIDS+=($!)

echo ""
echo "Warbler P2P + Reverse Proxy is running:"
echo ""
echo "  Proxy (unified API) → http://localhost:8080"
echo ""
echo "  Backend services:"
echo "    Identity      → http://localhost:8081"
echo "    Catalog       → http://localhost:8082"
echo "    Subscriptions → http://localhost:8083"
echo "    Analytics     → http://localhost:8084"
echo ""
echo "  Health check: curl http://localhost:8080/health"
echo ""
echo "Press Ctrl+C to stop all services."

# Wait for any process to exit
wait
