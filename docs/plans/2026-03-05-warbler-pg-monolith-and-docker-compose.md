# Warbler PG Monolith + Docker Compose Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create a Postgres-backed warbler monolith demo and add Docker Compose files to all four Postgres demos.

**Architecture:** The monolith variant (`warbler-pg`) mirrors the existing `warbler` demo with a single `main.swift`, swapping `InMemoryEventStore/PositionStore/SnapshotStore` for `PostgresEventStore/PostgresPositionStore/PostgresSnapshotStore`. Docker Compose files provide a `postgres:16` service for each PG demo, plus an `nginx` reverse proxy for `warbler-p2p-proxy-pg`.

**Tech Stack:** SongbirdPostgres (PostgresNIO, postgres-migrations), Hummingbird, Docker Compose, nginx

---

### Task 1: Scaffold warbler-pg Package

**Files:**
- Create: `demo/warbler-pg/Package.swift`
- Create: `demo/warbler-pg/.gitignore`

**Step 1: Create directory structure**

```bash
mkdir -p demo/warbler-pg/Sources/Warbler
```

**Step 2: Create `.gitignore`**

Create `demo/warbler-pg/.gitignore`:

```
.build/
```

**Step 3: Create `Package.swift`**

Create `demo/warbler-pg/Package.swift`:

```swift
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WarblerPG",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(name: "Songbird", path: "../../"),
        .package(name: "Warbler", path: "../warbler"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Warbler",
            dependencies: [
                .product(name: "WarblerIdentity", package: "Warbler"),
                .product(name: "WarblerCatalog", package: "Warbler"),
                .product(name: "WarblerSubscriptions", package: "Warbler"),
                .product(name: "WarblerAnalytics", package: "Warbler"),
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdPostgres", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
                .product(name: "SongbirdHummingbird", package: "Songbird"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
    ]
)
```

**Step 4: Verify**

```bash
ls demo/warbler-pg/Package.swift demo/warbler-pg/.gitignore
```

---

### Task 2: Warbler PG main.swift

**Files:**
- Create: `demo/warbler-pg/Sources/Warbler/main.swift`

**Reference:** `demo/warbler/Sources/Warbler/main.swift` (the SQLite/in-memory monolith)

**Step 1: Create `main.swift`**

This is the monolith variant — all four domains in one process on port 8080. Identical routes and domain code to the in-memory warbler monolith, but with Postgres stores.

Create `demo/warbler-pg/Sources/Warbler/main.swift`:

```swift
import Foundation
import Hummingbird
import Logging
import NIOCore
import PostgresNIO
import Songbird
import SongbirdHummingbird
import SongbirdPostgres
import SongbirdSmew
import WarblerAnalytics
import WarblerCatalog
import WarblerIdentity
import WarblerSubscriptions

@main
struct WarblerApp {
    static func main() async throws {
        // MARK: - Postgres Configuration

        let pgConfig = PostgresClient.Configuration(
            host: ProcessInfo.processInfo.environment["POSTGRES_HOST"] ?? "localhost",
            port: Int(ProcessInfo.processInfo.environment["POSTGRES_PORT"] ?? "5432") ?? 5432,
            username: ProcessInfo.processInfo.environment["POSTGRES_USER"] ?? "warbler",
            password: ProcessInfo.processInfo.environment["POSTGRES_PASSWORD"] ?? "warbler",
            database: ProcessInfo.processInfo.environment["POSTGRES_DB"] ?? "warbler",
            tls: .disable
        )
        let client = PostgresClient(configuration: pgConfig)
        let logger = Logger(label: "warbler")

        // Run migrations
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask {
                try await SongbirdPostgresMigrations.apply(client: client, logger: logger)
            }
            try await group.next()
            group.cancelAll()
        }

        // MARK: - Event Type Registry

        let registry = EventTypeRegistry()

        // Identity events
        registry.register(UserEvent.self, eventTypes: ["UserRegistered", "ProfileUpdated", "UserDeactivated"])

        // Catalog events (current version)
        registry.register(VideoEvent.self, eventTypes: ["VideoPublished", "VideoMetadataUpdated", "TranscodingCompleted", "VideoUnpublished"])

        // Catalog event versioning: v1 → v2 upcast
        registry.registerUpcast(
            from: VideoPublishedV1.self,
            to: VideoEvent.self,
            upcast: VideoPublishedUpcast(),
            oldEventType: "VideoPublished_v1"
        )

        // Subscription events
        registry.register(SubscriptionEvent.self, eventTypes: ["SubscriptionRequested", "PaymentConfirmed", "PaymentFailed"])
        registry.register(SubscriptionLifecycleEvent.self, eventTypes: ["AccessGranted", "SubscriptionCancelled"])

        // Analytics events
        registry.register(AnalyticsEvent.self, eventTypes: ["VideoViewed"])
        registry.register(ViewCountEvent.self, eventTypes: ["ViewCounted"])

        // MARK: - Stores (Postgres-backed)

        let eventStore = PostgresEventStore(client: client, registry: registry)
        let positionStore = PostgresPositionStore(client: client)
        let snapshotStore = PostgresSnapshotStore(client: client)

        // MARK: - Read Model Store

        let readModel = try ReadModelStore()

        // MARK: - Projectors

        let userProjector = UserProjector(readModel: readModel)
        await userProjector.registerMigration()

        let videoCatalogProjector = VideoCatalogProjector(readModel: readModel)
        await videoCatalogProjector.registerMigration()

        let subscriptionProjector = SubscriptionProjector(readModel: readModel)
        await subscriptionProjector.registerMigration()

        let playbackProjector = PlaybackAnalyticsProjector(readModel: readModel)
        await playbackProjector.registerMigration()

        try await readModel.migrate()

        // MARK: - Repositories

        let userRepo = AggregateRepository<UserAggregate>(store: eventStore, registry: registry)
        let videoRepo = AggregateRepository<VideoAggregate>(store: eventStore, registry: registry)
        let _viewCountRepo = AggregateRepository<ViewCountAggregate>(
            store: eventStore,
            registry: registry,
            snapshotStore: snapshotStore,
            snapshotPolicy: .everyNEvents(100)
        )
        _ = _viewCountRepo // Reserved for future view-count routes

        // MARK: - Gateway & Injector

        let emailGateway = EmailNotificationGateway()
        let playbackInjector = PlaybackInjector()

        // MARK: - Services

        let pipeline = ProjectionPipeline()
        var mutableServices = SongbirdServices(
            eventStore: eventStore,
            projectionPipeline: pipeline,
            positionStore: positionStore,
            eventRegistry: registry
        )

        mutableServices.registerProjector(userProjector)
        mutableServices.registerProjector(videoCatalogProjector)
        mutableServices.registerProjector(subscriptionProjector)
        mutableServices.registerProjector(playbackProjector)
        mutableServices.registerProcessManager(SubscriptionLifecycleProcess.self, tickInterval: .seconds(1))
        mutableServices.registerGateway(emailGateway, tickInterval: .seconds(1))
        mutableServices.registerInjector(playbackInjector)

        let services = mutableServices

        // MARK: - Router

        let router = Router(context: SongbirdRequestContext.self)
        router.addMiddleware { RequestIdMiddleware() }
        router.addMiddleware { ProjectionFlushMiddleware<SongbirdRequestContext>(pipeline: pipeline) }

        // MARK: - Identity Routes

        router.post("/users/{id}") { request, context -> Response in
            let id = try context.parameters.require("id")
            struct Body: Codable { let email: String; let displayName: String }
            let body = try await request.decode(as: Body.self, context: context)
            try await executeAndProject(
                RegisterUser(email: body.email, displayName: body.displayName),
                on: id,
                metadata: EventMetadata(traceId: context.requestId),
                using: RegisterUserHandler.self,
                repository: userRepo,
                services: services
            )
            return Response(status: .created)
        }

        router.get("/users/{id}") { _, context -> Response in
            let id = try context.parameters.require("id")
            struct UserRow: Codable { let id: String; let email: String; let displayName: String; let isActive: Bool }
            let user: UserRow? = try await readModel.queryFirst(UserRow.self) {
                "SELECT id, email, display_name, is_active FROM users WHERE id = \(param: id)"
            }
            guard let user else { return Response(status: .notFound) }
            let data = try JSONEncoder().encode(user)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }

        router.patch("/users/{id}") { request, context -> Response in
            let id = try context.parameters.require("id")
            struct Body: Codable { let displayName: String }
            let body = try await request.decode(as: Body.self, context: context)
            try await executeAndProject(
                UpdateProfile(displayName: body.displayName),
                on: id,
                metadata: EventMetadata(traceId: context.requestId),
                using: UpdateProfileHandler.self,
                repository: userRepo,
                services: services
            )
            return Response(status: .ok)
        }

        router.delete("/users/{id}") { _, context -> Response in
            let id = try context.parameters.require("id")
            try await executeAndProject(
                DeactivateUser(),
                on: id,
                metadata: EventMetadata(traceId: context.requestId),
                using: DeactivateUserHandler.self,
                repository: userRepo,
                services: services
            )
            return Response(status: .ok)
        }

        // MARK: - Catalog Routes

        router.post("/videos/{id}") { request, context -> Response in
            let id = try context.parameters.require("id")
            struct Body: Codable { let title: String; let description: String; let creatorId: String }
            let body = try await request.decode(as: Body.self, context: context)
            try await executeAndProject(
                PublishVideo(title: body.title, description: body.description, creatorId: body.creatorId),
                on: id,
                metadata: EventMetadata(traceId: context.requestId),
                using: PublishVideoHandler.self,
                repository: videoRepo,
                services: services
            )
            return Response(status: .created)
        }

        router.get("/videos") { _, _ -> Response in
            struct VideoRow: Codable { let id: String; let title: String; let description: String; let creatorId: String; let status: String }
            let videos: [VideoRow] = try await readModel.query(VideoRow.self) {
                "SELECT id, title, description, creator_id, status FROM videos ORDER BY title"
            }
            let data = try JSONEncoder().encode(videos)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }

        router.get("/videos/{id}") { _, context -> Response in
            let id = try context.parameters.require("id")
            struct VideoRow: Codable { let id: String; let title: String; let description: String; let creatorId: String; let status: String }
            let video: VideoRow? = try await readModel.queryFirst(VideoRow.self) {
                "SELECT id, title, description, creator_id, status FROM videos WHERE id = \(param: id)"
            }
            guard let video else { return Response(status: .notFound) }
            let data = try JSONEncoder().encode(video)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }

        router.patch("/videos/{id}") { request, context -> Response in
            let id = try context.parameters.require("id")
            struct Body: Codable { let title: String; let description: String }
            let body = try await request.decode(as: Body.self, context: context)
            try await executeAndProject(
                UpdateVideoMetadata(title: body.title, description: body.description),
                on: id,
                metadata: EventMetadata(traceId: context.requestId),
                using: UpdateVideoMetadataHandler.self,
                repository: videoRepo,
                services: services
            )
            return Response(status: .ok)
        }

        router.post("/videos/{id}/transcode-complete") { _, context -> Response in
            let id = try context.parameters.require("id")
            try await executeAndProject(
                CompleteTranscoding(),
                on: id,
                metadata: EventMetadata(traceId: context.requestId),
                using: CompleteTranscodingHandler.self,
                repository: videoRepo,
                services: services
            )
            return Response(status: .ok)
        }

        router.delete("/videos/{id}") { _, context -> Response in
            let id = try context.parameters.require("id")
            try await executeAndProject(
                UnpublishVideo(),
                on: id,
                metadata: EventMetadata(traceId: context.requestId),
                using: UnpublishVideoHandler.self,
                repository: videoRepo,
                services: services
            )
            return Response(status: .ok)
        }

        // MARK: - Subscription Routes

        router.post("/subscriptions/{id}") { request, context -> Response in
            let id = try context.parameters.require("id")
            struct Body: Codable { let userId: String; let plan: String }
            let body = try await request.decode(as: Body.self, context: context)
            try await appendAndProject(
                SubscriptionEvent.requested(subscriptionId: id, userId: body.userId, plan: body.plan),
                to: StreamName(category: "subscription", id: id),
                metadata: EventMetadata(traceId: context.requestId),
                services: services
            )
            return Response(status: .created)
        }

        router.get("/subscriptions/{userId}") { _, context -> Response in
            let userId = try context.parameters.require("userId")
            struct SubRow: Codable { let id: String; let userId: String; let plan: String; let status: String }
            let subs: [SubRow] = try await readModel.query(SubRow.self) {
                "SELECT id, user_id, plan, status FROM subscriptions WHERE user_id = \(param: userId)"
            }
            let data = try JSONEncoder().encode(subs)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }

        router.post("/subscriptions/{id}/pay") { _, context -> Response in
            let id = try context.parameters.require("id")
            try await appendAndProject(
                SubscriptionEvent.paymentConfirmed(subscriptionId: id),
                to: StreamName(category: "subscription", id: id),
                metadata: EventMetadata(traceId: context.requestId),
                services: services
            )
            return Response(status: .ok)
        }

        // MARK: - Analytics Routes

        router.post("/analytics/views") { request, context -> Response in
            struct Body: Codable { let videoId: String; let userId: String; let watchedSeconds: Int }
            let body = try await request.decode(as: Body.self, context: context)
            let event = AnalyticsEvent.videoViewed(videoId: body.videoId, userId: body.userId, watchedSeconds: body.watchedSeconds)
            let inbound = InboundEvent(
                event: event,
                stream: StreamName(category: "analytics", id: body.videoId),
                metadata: EventMetadata(traceId: context.requestId)
            )
            await playbackInjector.inject(inbound)
            return Response(status: .accepted)
        }

        router.get("/analytics/videos/{id}/views") { _, context -> Response in
            let id = try context.parameters.require("id")
            struct CountRow: Codable { let viewCount: Int64; let totalSeconds: Int64 }
            let result: CountRow? = try await readModel.queryFirst(CountRow.self) {
                "SELECT COUNT(*) AS view_count, COALESCE(SUM(watched_seconds), 0) AS total_seconds FROM video_views WHERE video_id = \(param: id)"
            }
            let data = try JSONEncoder().encode(result)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }

        router.get("/analytics/top-videos") { _, _ -> Response in
            struct TopVideo: Codable { let videoId: String; let viewCount: Int64; let totalSeconds: Int64 }
            let top: [TopVideo] = try await readModel.query(TopVideo.self) {
                "SELECT video_id, COUNT(*) AS view_count, SUM(watched_seconds) AS total_seconds FROM video_views GROUP BY video_id ORDER BY view_count DESC LIMIT 10"
            }
            let data = try JSONEncoder().encode(top)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }

        // MARK: - Start

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("localhost", port: 8080))
        )

        print("Warbler (Postgres) starting on http://localhost:8080")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask { try await services.run() }
            group.addTask { try await app.runService() }
            try await group.waitForAll()
        }
    }
}
```

**Step 2: Verify build**

```bash
cd demo/warbler-pg && swift build
```

Expected: Build complete (long first build due to dependency resolution).

---

### Task 3: Warbler PG Launch Script and README

**Files:**
- Create: `demo/warbler-pg/launch.sh`
- Create: `demo/warbler-pg/README.md`

**Step 1: Create `launch.sh`**

Create `demo/warbler-pg/launch.sh`:

```bash
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
```

Make executable: `chmod +x demo/warbler-pg/launch.sh`

**Step 2: Create `README.md`**

Create `demo/warbler-pg/README.md`:

```markdown
# Warbler (Postgres)

Postgres-backed version of the Warbler monolith demo. Identical to the in-memory `warbler` demo — all four domains in a single process on `:8080` — but uses PostgreSQL for event storage, position tracking, and snapshots.

## Prerequisites

A running PostgreSQL instance. Start one with Docker Compose:

` ` `bash
docker compose up -d
` ` `

Or manually:

` ` `bash
docker run -d --name warbler-postgres \
  -e POSTGRES_USER=warbler -e POSTGRES_PASSWORD=warbler \
  -e POSTGRES_DB=warbler -p 5432:5432 postgres:16
` ` `

## Quick Start

` ` `bash
./launch.sh
` ` `

## Configuration

Postgres connection is configured via environment variables:

| Variable | Default |
|----------|---------|
| `POSTGRES_HOST` | `localhost` |
| `POSTGRES_PORT` | `5432` |
| `POSTGRES_USER` | `warbler` |
| `POSTGRES_PASSWORD` | `warbler` |
| `POSTGRES_DB` | `warbler` |

## API Examples

` ` `bash
# Create a user
curl -X POST http://localhost:8080/users/alice \
  -H "Content-Type: application/json" \
  -d '{"email": "alice@example.com", "displayName": "Alice"}'

# Publish a video
curl -X POST http://localhost:8080/videos/vid-1 \
  -H "Content-Type: application/json" \
  -d '{"title": "Swift Concurrency", "description": "A deep dive", "creatorId": "alice"}'

# Record a view
curl -X POST http://localhost:8080/analytics/views \
  -H "Content-Type: application/json" \
  -d '{"videoId": "vid-1", "userId": "alice", "watchedSeconds": 120}'
` ` `

## Differences from In-Memory Variant

| Aspect | In-Memory | Postgres |
|--------|-----------|----------|
| Event store | InMemoryEventStore | PostgresEventStore |
| Position store | InMemoryPositionStore | PostgresPositionStore |
| Snapshot store | InMemorySnapshotStore | PostgresSnapshotStore |
| Data persistence | Lost on restart | Survives restart |
| Dependencies | SongbirdSQLite, SongbirdTesting | SongbirdPostgres |
| Prerequisites | None | Running Postgres instance |
```

Note: Replace the ` ` ` sequences in the README with actual triple backticks when creating the file.

---

### Task 4: Docker Compose for warbler-pg

**Files:**
- Create: `demo/warbler-pg/docker-compose.yml`

**Step 1: Create `docker-compose.yml`**

Create `demo/warbler-pg/docker-compose.yml`:

```yaml
services:
  postgres:
    image: postgres:16
    ports:
      - "5432:5432"
    environment:
      POSTGRES_USER: warbler
      POSTGRES_PASSWORD: warbler
      POSTGRES_DB: warbler
    volumes:
      - warbler-pg-data:/var/lib/postgresql/data

volumes:
  warbler-pg-data:
```

---

### Task 5: Docker Compose for warbler-distributed-pg

**Files:**
- Create: `demo/warbler-distributed-pg/docker-compose.yml`

**Step 1: Create `docker-compose.yml`**

Create `demo/warbler-distributed-pg/docker-compose.yml`:

```yaml
services:
  postgres:
    image: postgres:16
    ports:
      - "5432:5432"
    environment:
      POSTGRES_USER: warbler
      POSTGRES_PASSWORD: warbler
      POSTGRES_DB: warbler
    volumes:
      - warbler-distributed-pg-data:/var/lib/postgresql/data

volumes:
  warbler-distributed-pg-data:
```

---

### Task 6: Docker Compose for warbler-p2p-pg

**Files:**
- Create: `demo/warbler-p2p-pg/docker-compose.yml`

**Step 1: Create `docker-compose.yml`**

Create `demo/warbler-p2p-pg/docker-compose.yml`:

```yaml
services:
  postgres:
    image: postgres:16
    ports:
      - "5432:5432"
    environment:
      POSTGRES_USER: warbler
      POSTGRES_PASSWORD: warbler
      POSTGRES_DB: warbler
    volumes:
      - warbler-p2p-pg-data:/var/lib/postgresql/data

volumes:
  warbler-p2p-pg-data:
```

---

### Task 7: Docker Compose for warbler-p2p-proxy-pg (Postgres + nginx)

**Files:**
- Create: `demo/warbler-p2p-proxy-pg/docker-compose.yml`
- Create: `demo/warbler-p2p-proxy-pg/nginx.conf`

**Step 1: Create `nginx.conf`**

Create `demo/warbler-p2p-proxy-pg/nginx.conf`:

```nginx
upstream identity {
    server host.docker.internal:8081;
}

upstream catalog {
    server host.docker.internal:8082;
}

upstream subscriptions {
    server host.docker.internal:8083;
}

upstream analytics {
    server host.docker.internal:8084;
}

server {
    listen 8080;

    location /users/ {
        proxy_pass http://identity;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location /videos/ {
        proxy_pass http://catalog;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location /subscriptions/ {
        proxy_pass http://catalog;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location /analytics/ {
        proxy_pass http://analytics;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location /health {
        return 200 '{"status":"healthy"}';
        add_header Content-Type application/json;
    }
}
```

**Step 2: Create `docker-compose.yml`**

Create `demo/warbler-p2p-proxy-pg/docker-compose.yml`:

```yaml
services:
  postgres:
    image: postgres:16
    ports:
      - "5432:5432"
    environment:
      POSTGRES_USER: warbler
      POSTGRES_PASSWORD: warbler
      POSTGRES_DB: warbler
    volumes:
      - warbler-p2p-proxy-pg-data:/var/lib/postgresql/data

  nginx:
    image: nginx:alpine
    ports:
      - "8080:8080"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    extra_hosts:
      - "host.docker.internal:host-gateway"

volumes:
  warbler-p2p-proxy-pg-data:
```

---

### Task 8: Update READMEs with Docker Compose instructions

**Files:**
- Modify: `demo/warbler-distributed-pg/README.md`
- Modify: `demo/warbler-p2p-pg/README.md`
- Modify: `demo/warbler-p2p-proxy-pg/README.md`

For each of the three existing PG demo READMEs, add a Docker Compose alternative in the Prerequisites section. After the manual `docker run` block, add:

```markdown
Or use Docker Compose:

` ` `bash
docker compose up -d
` ` `
```

For `warbler-p2p-proxy-pg/README.md`, also mention the nginx proxy:

```markdown
Or use Docker Compose (includes nginx reverse proxy on `:8080`):

` ` `bash
docker compose up -d
` ` `

With Docker Compose, the nginx container replaces the Swift WarblerProxy. Start only the 4 P2P services:

` ` `bash
cd ../warbler-p2p-pg && ./launch.sh
` ` `
```

Note: Replace the ` ` ` sequences with actual triple backticks when editing the files.

---

### Task 9: Build Verification

**Step 1: Build warbler-pg**

```bash
cd demo/warbler-pg && swift build
```

Expected: `Build complete!`

**Step 2: Verify Docker Compose files are valid**

```bash
docker compose -f demo/warbler-pg/docker-compose.yml config --quiet
docker compose -f demo/warbler-distributed-pg/docker-compose.yml config --quiet
docker compose -f demo/warbler-p2p-pg/docker-compose.yml config --quiet
docker compose -f demo/warbler-p2p-proxy-pg/docker-compose.yml config --quiet
```

Expected: No output (valid YAML).

---

### Task 10: Changelog Entry

**Files:**
- Create: `changelog/0023-warbler-pg-monolith-and-docker-compose.md`

**Step 1: Create changelog**

Create `changelog/0023-warbler-pg-monolith-and-docker-compose.md`:

```markdown
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
```
