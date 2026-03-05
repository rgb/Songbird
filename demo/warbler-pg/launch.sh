#!/bin/bash
set -e

# Warbler Monolith (Postgres) — Single-process server on port 8080
# Uses PostgreSQL instead of in-memory stores.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Check Postgres is running
pg_isready -h "${POSTGRES_HOST:-localhost}" -p "${POSTGRES_PORT:-5432}" -U "${POSTGRES_USER:-warbler}" || {
    echo "Postgres is not running. Start it with:"
    echo "  docker compose up -d"
    echo ""
    echo "Or manually:"
    echo "  docker run -d --name warbler-postgres \\"
    echo "    -e POSTGRES_USER=warbler -e POSTGRES_PASSWORD=warbler \\"
    echo "    -e POSTGRES_DB=warbler -p 5432:5432 postgres:16"
    exit 1
}

# Build
echo "Building Warbler (Postgres)..."
swift build

# Start
echo "Starting Warbler (Postgres) on http://localhost:8080"
swift run Warbler
