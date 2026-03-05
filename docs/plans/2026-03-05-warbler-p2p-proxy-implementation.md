# Warbler P2P + Reverse Proxy Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a Hummingbird-based reverse proxy on `:8080` that forwards requests by URL prefix to the 4 Warbler P2P domain services, plus provide nginx and Caddy config alternatives.

**Architecture:** A single `WarblerProxy` executable using Hummingbird for the HTTP server and `AsyncHTTPClient` for outbound forwarding. Routes are matched by URL prefix (`/users` → `:8081`, `/videos` → `:8082`, etc.). Includes request logging, a `/health` endpoint, and 502 error handling. Separate package from warbler-p2p.

**Tech Stack:** Hummingbird 2, AsyncHTTPClient (>= 1.21.0), Swift 6.2

**Design doc:** `docs/plans/2026-03-05-warbler-p2p-proxy-design.md`

---

## Reference: Key API Patterns

**Hummingbird route with wildcard:**
```swift
router.on("/**", method: .GET) { request, context -> Response in ... }
```

**AsyncHTTPClient request forwarding:**
```swift
import AsyncHTTPClient

var clientRequest = HTTPClientRequest(url: "http://localhost:8081/users/alice")
clientRequest.method = .POST
clientRequest.headers = request.headers  // forward incoming headers
clientRequest.body = .stream(request.body, length: .unknown)

let response = try await HTTPClient.shared.execute(clientRequest, timeout: .seconds(30))

return Response(
    status: .init(code: Int(response.status.code)),
    headers: HTTPFields(response.headers, splitCookie: false),
    body: ResponseBody(asyncSequence: response.body)
)
```

**Backend routing map:**
```swift
let backends: [(prefix: String, port: Int)] = [
    ("/users", 8081),
    ("/videos", 8082),
    ("/subscriptions", 8083),
    ("/analytics", 8084),
]
```

---

### Task 1: Scaffold Package

**Files:**
- Create: `demo/warbler-p2p-proxy/Package.swift`
- Create: `demo/warbler-p2p-proxy/Sources/WarblerProxy/main.swift` (placeholder)
- Create: `demo/warbler-p2p-proxy/.gitignore`

**Step 1: Create the directory structure**

```bash
mkdir -p demo/warbler-p2p-proxy/Sources/WarblerProxy
mkdir -p demo/warbler-p2p-proxy/config
```

**Step 2: Write Package.swift**

Create `demo/warbler-p2p-proxy/Package.swift`:

```swift
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WarblerP2PProxy",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    ],
    targets: [
        .executableTarget(
            name: "WarblerProxy",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ]
        ),
    ]
)
```

**Step 3: Write placeholder main.swift**

Create `demo/warbler-p2p-proxy/Sources/WarblerProxy/main.swift`:

```swift
import Hummingbird

@main
struct WarblerProxy {
    static func main() async throws {
        let router = Router()
        router.get("/") { _, _ in "WarblerProxy placeholder" }

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("localhost", port: 8080))
        )

        print("WarblerProxy starting on http://localhost:8080")
        try await app.runService()
    }
}
```

**Step 4: Write .gitignore**

Create `demo/warbler-p2p-proxy/.gitignore`:

```
.build/
.swiftpm/
Package.resolved
```

**Step 5: Verify it builds**

```bash
cd demo/warbler-p2p-proxy && swift build
```

Expected: Clean build.

**Step 6: Commit**

```bash
git add demo/warbler-p2p-proxy/
git commit -m "Scaffold warbler-p2p-proxy package"
```

---

### Task 2: Reverse Proxy Forwarding

**Files:**
- Modify: `demo/warbler-p2p-proxy/Sources/WarblerProxy/main.swift`

**Context:** Replace the placeholder with the full reverse proxy implementation. The proxy matches URL prefixes to backend ports and forwards the request using AsyncHTTPClient. Uses `HTTPClient.shared` (no lifecycle management needed).

**Step 1: Write the full main.swift**

Replace `demo/warbler-p2p-proxy/Sources/WarblerProxy/main.swift` with:

```swift
import AsyncHTTPClient
import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import NIOHTTPTypes

@main
struct WarblerProxy {
    /// Maps URL path prefixes to backend ports.
    static let backends: [(prefix: String, port: Int, name: String)] = [
        ("/users", 8081, "identity"),
        ("/videos", 8082, "catalog"),
        ("/subscriptions", 8083, "subscriptions"),
        ("/analytics", 8084, "analytics"),
    ]

    static func main() async throws {
        let router = Router()

        // Health check
        router.get("/health") { _, _ -> Response in
            try await healthCheck()
        }

        // Catch-all: forward to the appropriate backend
        router.on("/**") { request, context -> Response in
            let path = context.remainingPathComponents
                .joined(separator: "/")
            let fullPath = "/" + path
            let query = request.uri.query.map { "?\($0)" } ?? ""

            guard let backend = Self.backends.first(where: { fullPath.hasPrefix($0.prefix) }) else {
                let body = #"{"error":"No backend for path: \#(fullPath)"}"#
                return Response(
                    status: .notFound,
                    headers: [.contentType: "application/json"],
                    body: .init(byteBuffer: ByteBuffer(string: body))
                )
            }

            let start = ContinuousClock.now
            let response = await forward(
                request: request,
                path: fullPath,
                query: query,
                backend: backend
            )
            let elapsed = ContinuousClock.now - start

            print("\(request.method) \(fullPath) → :\(backend.port) (\(backend.name)) → \(response.status.code) [\(elapsed)]")

            return response
        }

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("localhost", port: 8080))
        )

        print("WarblerProxy starting on http://localhost:8080")
        print("Routing:")
        for b in backends {
            print("  \(b.prefix)/* → localhost:\(b.port) (\(b.name))")
        }
        print("")
        try await app.runService()
    }

    /// Forwards a request to the given backend and returns the response.
    static func forward(
        request: Request,
        path: String,
        query: String,
        backend: (prefix: String, port: Int, name: String)
    ) async -> Response {
        let url = "http://localhost:\(backend.port)\(path)\(query)"

        var clientRequest = HTTPClientRequest(url: url)
        clientRequest.method = .init(rawValue: request.method.rawValue)!

        // Forward headers (skip host — AsyncHTTPClient sets it from the URL)
        for header in request.headers {
            if header.name != .host {
                clientRequest.headers.add(name: String(header.name), value: String(header.value))
            }
        }

        // Forward body
        if let contentLength = request.headers[.contentLength], let length = Int(contentLength) {
            clientRequest.body = .stream(request.body, length: .known(length))
        } else {
            clientRequest.body = .stream(request.body, length: .unknown)
        }

        do {
            let response = try await HTTPClient.shared.execute(clientRequest, timeout: .seconds(30))

            var responseHeaders = HTTPFields()
            for header in response.headers {
                responseHeaders.append(HTTPField(name: .init(header.name)!, value: header.value))
            }

            return Response(
                status: .init(code: Int(response.status.code)),
                headers: responseHeaders,
                body: .init(asyncSequence: response.body)
            )
        } catch {
            let body = #"{"error":"Service unavailable: \#(backend.name) (port \#(backend.port))"}"#
            return Response(
                status: .badGateway,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(string: body))
            )
        }
    }

    /// Checks if all 4 backends are reachable.
    static func healthCheck() async throws -> Response {
        var services: [(String, String)] = []
        var allHealthy = true

        for backend in backends {
            let url = "http://localhost:\(backend.port)/"
            var request = HTTPClientRequest(url: url)
            request.method = .GET

            let status: String
            do {
                let response = try await HTTPClient.shared.execute(request, timeout: .seconds(5))
                // Any response (even 404) means the service is up
                _ = try? await response.body.collect(upTo: 1024)
                status = "up"
            } catch {
                status = "down"
                allHealthy = false
            }
            services.append((backend.name, status))
        }

        var json = #"{"status":"\#(allHealthy ? "healthy" : "degraded")","services":{"#
        json += services.map { #""\#($0.0)":"\#($0.1)""# }.joined(separator: ",")
        json += "}}"

        return Response(
            status: allHealthy ? .ok : .serviceUnavailable,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(string: json))
        )
    }
}
```

**Important implementation notes:**
- The catch-all route uses `/**` to match any path. The exact Hummingbird 2 wildcard syntax may differ — check how `context.remainingPathComponents` or `request.uri.path` works and adjust.
- Header forwarding between Hummingbird's `HTTPFields` and AsyncHTTPClient's `HTTPHeaders` may need adaptation. The two types are different (`HTTPTypes.HTTPFields` vs NIO `HTTPHeaders`). Check the actual conversion API.
- The `HTTPMethod` conversion between HTTPTypes and AsyncHTTPClient may need a different initializer. `NIOHTTP1.HTTPMethod` can be constructed from a string.
- `ResponseBody(asyncSequence:)` streams the backend response body directly without buffering. Verify this initializer exists in Hummingbird 2.
- If any API mismatch is found, adapt to the actual API. The forwarding pattern is correct; specific type conversions may vary.

**Step 2: Verify it builds**

```bash
cd demo/warbler-p2p-proxy && swift build
```

Expected: Clean build. Fix any type mismatches.

**Step 3: Commit**

```bash
git add demo/warbler-p2p-proxy/Sources/WarblerProxy/main.swift
git commit -m "Implement reverse proxy with forwarding, logging, and health check"
```

---

### Task 3: nginx and Caddy Alternative Configs

**Files:**
- Create: `demo/warbler-p2p-proxy/config/nginx.conf`
- Create: `demo/warbler-p2p-proxy/config/Caddyfile`

**Step 1: Write nginx.conf**

Create `demo/warbler-p2p-proxy/config/nginx.conf`:

```nginx
# Warbler P2P Reverse Proxy — nginx configuration
#
# Usage:
#   1. Start the 4 P2P services (cd ../warbler-p2p && ./launch.sh)
#   2. Run nginx with this config:
#      nginx -c $(pwd)/config/nginx.conf
#   3. Access all services via http://localhost:8080

worker_processes 1;
error_log /dev/stderr;
pid /tmp/warbler-nginx.pid;

events {
    worker_connections 256;
}

http {
    access_log /dev/stdout;

    upstream identity {
        server localhost:8081;
    }

    upstream catalog {
        server localhost:8082;
    }

    upstream subscriptions {
        server localhost:8083;
    }

    upstream analytics {
        server localhost:8084;
    }

    server {
        listen 8080;
        server_name localhost;

        location /users {
            proxy_pass http://identity;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }

        location /videos {
            proxy_pass http://catalog;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }

        location /subscriptions {
            proxy_pass http://subscriptions;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }

        location /analytics {
            proxy_pass http://analytics;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }

        location /health {
            return 200 '{"status":"healthy","note":"nginx does not check backend health by default"}';
            add_header Content-Type application/json;
        }
    }
}
```

**Step 2: Write Caddyfile**

Create `demo/warbler-p2p-proxy/config/Caddyfile`:

```
# Warbler P2P Reverse Proxy — Caddy configuration
#
# Usage:
#   1. Start the 4 P2P services (cd ../warbler-p2p && ./launch.sh)
#   2. Run Caddy with this config:
#      caddy run --config config/Caddyfile
#   3. Access all services via http://localhost:8080

:8080 {
    handle_path /health {
        respond `{"status":"healthy","note":"caddy does not check backend health by default"}` 200 {
            close
        }
    }

    handle /users/* {
        reverse_proxy localhost:8081
    }

    handle /users {
        reverse_proxy localhost:8081
    }

    handle /videos/* {
        reverse_proxy localhost:8082
    }

    handle /videos {
        reverse_proxy localhost:8082
    }

    handle /subscriptions/* {
        reverse_proxy localhost:8083
    }

    handle /subscriptions {
        reverse_proxy localhost:8083
    }

    handle /analytics/* {
        reverse_proxy localhost:8084
    }

    handle /analytics {
        reverse_proxy localhost:8084
    }

    handle {
        respond `{"error":"No backend for this path"}` 404
    }

    log {
        output stdout
    }
}
```

**Step 3: Commit**

```bash
git add demo/warbler-p2p-proxy/config/
git commit -m "Add nginx and Caddy reverse proxy configs as alternatives"
```

---

### Task 4: Launch Script

**Files:**
- Create: `demo/warbler-p2p-proxy/launch.sh`

**Context:** Starts all 4 P2P services from `../warbler-p2p` plus the proxy. 5 processes total. Builds both packages first. Same signal handling pattern as the P2P launch script.

**Step 1: Write launch.sh**

Create `demo/warbler-p2p-proxy/launch.sh`:

```bash
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

# Give services a moment to start
sleep 2

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
```

**Step 2: Make it executable**

```bash
chmod +x demo/warbler-p2p-proxy/launch.sh
```

**Step 3: Commit**

```bash
git add demo/warbler-p2p-proxy/launch.sh
git commit -m "Add launch script for P2P + proxy (5 processes)"
```

---

### Task 5: README

**Files:**
- Create: `demo/warbler-p2p-proxy/README.md`

**Step 1: Write README.md**

Create `demo/warbler-p2p-proxy/README.md`:

```markdown
# Warbler P2P + Reverse Proxy

Adds a thin reverse proxy on `:8080` in front of the 4 Warbler P2P domain services. Clients see a unified API identical to the monolith, while the backend remains 4 independent processes communicating through the shared event store.

The proxy is a Hummingbird app using AsyncHTTPClient for forwarding. It has zero knowledge of event sourcing — pure HTTP routing by URL prefix.

## Quick Start

```bash
./launch.sh
```

This builds and starts all 4 P2P services plus the proxy (5 processes). Press Ctrl+C to stop.

## Services

| Port | Process | Role |
|------|---------|------|
| 8080 | WarblerProxy | Reverse proxy (unified API) |
| 8081 | WarblerIdentityService | Users |
| 8082 | WarblerCatalogService | Videos |
| 8083 | WarblerSubscriptionsService | Subscriptions |
| 8084 | WarblerAnalyticsService | Analytics |

## API Examples

All requests go to `:8080` — the proxy routes them to the correct backend.

### Create a user
```bash
curl -X POST http://localhost:8080/users/alice \
  -H "Content-Type: application/json" \
  -d '{"email": "alice@example.com", "displayName": "Alice"}'
```

### Get a user
```bash
curl http://localhost:8080/users/alice
```

### Publish a video
```bash
curl -X POST http://localhost:8080/videos/vid-1 \
  -H "Content-Type: application/json" \
  -d '{"title": "Swift Concurrency", "description": "A deep dive", "creatorId": "alice"}'
```

### List videos
```bash
curl http://localhost:8080/videos
```

### Create a subscription
```bash
curl -X POST http://localhost:8080/subscriptions/sub-1 \
  -H "Content-Type: application/json" \
  -d '{"userId": "alice", "plan": "premium"}'
```

### Confirm payment
```bash
curl -X POST http://localhost:8080/subscriptions/sub-1/pay
```

### Record a video view
```bash
curl -X POST http://localhost:8080/analytics/views \
  -H "Content-Type: application/json" \
  -d '{"videoId": "vid-1", "userId": "alice", "watchedSeconds": 120}'
```

### Get video analytics
```bash
curl http://localhost:8080/analytics/videos/vid-1/views
```

### Top videos
```bash
curl http://localhost:8080/analytics/top-videos
```

### Health check
```bash
curl http://localhost:8080/health
```

## Architecture

```
HTTP Client
    |
    v
+------------------------+
| WarblerProxy :8080     |
| - Request logging      |
| - Health check         |
| - URL prefix routing   |
+------+-----------------+
       |
       +-- /users/*          --> :8081 (Identity)
       +-- /videos/*         --> :8082 (Catalog)
       +-- /subscriptions/*  --> :8083 (Subscriptions)
       +-- /analytics/*      --> :8084 (Analytics)
                                  |
                                  v
                        +-------------------+
                        | songbird.sqlite   |  <-- Shared event store
                        +-------------------+
```

## Alternative Proxy Configs

The `config/` directory provides ready-to-use alternatives:

### nginx

```bash
# Start the 4 P2P services first
cd ../warbler-p2p && ./launch.sh &

# Then run nginx
nginx -c $(pwd)/config/nginx.conf
```

### Caddy

```bash
# Start the 4 P2P services first
cd ../warbler-p2p && ./launch.sh &

# Then run Caddy
caddy run --config config/Caddyfile
```

## Comparison with Other Demos

| Aspect | Monolith | Distributed | P2P | P2P + Proxy |
|--------|----------|-------------|-----|-------------|
| Processes | 1 | 5 | 4 | 5 |
| Entry point | :8080 | :8080 (gateway) | 4 ports | :8080 (proxy) |
| Communication | In-process | Distributed actors | Shared store | Shared store |
| Proxy intelligence | N/A | Command dispatch | N/A | URL prefix only |
| Domain knowledge | Full | Gateway knows commands | Per-service | None |
```

**Step 2: Commit**

```bash
git add demo/warbler-p2p-proxy/README.md
git commit -m "Add README for warbler-p2p-proxy demo"
```

---

### Task 6: Build Verification and Smoke Test

**Files:**
- No new files

**Context:** Verify the proxy builds, starts, and forwards requests correctly. Requires the 4 P2P services to be running.

**Step 1: Build the proxy**

```bash
cd demo/warbler-p2p-proxy && swift build 2>&1
```

Expected: Clean build, no warnings.

**Step 2: Start the P2P services (in a separate terminal)**

```bash
cd demo/warbler-p2p && ./launch.sh
```

Wait for all 4 services to report they've started.

**Step 3: Start the proxy**

```bash
cd demo/warbler-p2p-proxy && swift run WarblerProxy
```

Expected: Prints routing table and "starting on http://localhost:8080".

**Step 4: Smoke test — health check**

```bash
curl http://localhost:8080/health
```

Expected: `{"status":"healthy","services":{"identity":"up","catalog":"up","subscriptions":"up","analytics":"up"}}`

**Step 5: Smoke test — create and get a user**

```bash
curl -X POST http://localhost:8080/users/test-1 \
  -H "Content-Type: application/json" \
  -d '{"email": "test@example.com", "displayName": "Test"}'

curl http://localhost:8080/users/test-1
```

Expected: 201 Created, then JSON with user data.

**Step 6: Smoke test — unknown path returns 404**

```bash
curl http://localhost:8080/unknown
```

Expected: 404 with `{"error":"No backend for path: /unknown"}`.

**Step 7: Fix any issues found during smoke testing**

Adapt the forwarding logic if:
- Header conversion fails between HTTPTypes and NIO HTTPHeaders
- Wildcard route doesn't capture the full path
- Body streaming doesn't work for POST requests
- Status code conversion needs adjustment

---

### Task 7: Changelog Entry

**Files:**
- Create: `changelog/0021-warbler-p2p-proxy.md`

**Step 1: Check the next changelog number**

```bash
ls changelog/ | tail -3
```

Use the next number after the highest existing entry.

**Step 2: Write the changelog entry**

Create `changelog/NNNN-warbler-p2p-proxy.md` (where NNNN is the next number):

```markdown
# Warbler P2P + Reverse Proxy Demo

Added the `warbler-p2p-proxy` demo — a thin reverse proxy on `:8080` that routes by URL prefix to the 4 Warbler P2P domain services.

## What Changed

### New Demo: demo/warbler-p2p-proxy/

**WarblerProxy executable** — Hummingbird app using AsyncHTTPClient for HTTP forwarding:
- URL-prefix routing: `/users` → `:8081`, `/videos` → `:8082`, `/subscriptions` → `:8083`, `/analytics` → `:8084`
- Request logging with method, path, backend, status code, and duration
- `GET /health` endpoint checking all 4 backend services
- 502 Bad Gateway response when a backend is unreachable

**Alternative configs:**
- `config/nginx.conf` — nginx reverse proxy config
- `config/Caddyfile` — Caddy reverse proxy config

**Launch script:** Starts all 4 P2P services + the proxy (5 processes) with signal handling.

## Architecture

Clients connect to `:8080` and see the same unified API as the monolith. The proxy has zero knowledge of event sourcing — it only routes by URL prefix. The 4 backend services are unchanged from the P2P demo.

## Feature Coverage

| Feature | Where |
|---------|-------|
| Unified API (single port) | WarblerProxy on :8080 |
| URL-prefix routing | /users, /videos, /subscriptions, /analytics |
| Request logging | Duration, backend, status code |
| Health check | GET /health (checks all 4 backends) |
| nginx alternative | config/nginx.conf |
| Caddy alternative | config/Caddyfile |
| Same P2P backend | Zero changes to domain services |
```

**Step 3: Commit**

```bash
git add changelog/NNNN-warbler-p2p-proxy.md
git commit -m "Add warbler-p2p-proxy changelog entry"
```
