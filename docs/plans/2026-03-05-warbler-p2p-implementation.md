# Warbler P2P Demo App Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a peer-to-peer multi-process version of the Warbler demo — 4 independent Hummingbird servers on separate ports, communicating solely through a shared SQLite event store (Garofolo's "message store as transport" pattern).

**Architecture:** Each bounded context (Identity, Catalog, Subscriptions, Analytics) runs as its own Hummingbird executable with its own DuckDB read model, all sharing a single SQLite event store file. No gateway, no distributed actors. Cross-domain coordination happens through event subscriptions polling the shared store.

**Tech Stack:** Swift 6.2+, Songbird (core), SongbirdSQLite, SongbirdSmew, SongbirdHummingbird, SongbirdTesting, Hummingbird 2, WarblerIdentity/Catalog/Subscriptions/Analytics domain modules

**Prerequisites:** The SQLiteEventStore TOCTOU fix (`BEGIN IMMEDIATE` transaction) must already be in place. Check that `Sources/SongbirdSQLite/SQLiteEventStore.swift` wraps its append method in `db.transaction(.immediate)`. The Warbler monolith domain modules must be complete.

---

### Task 1: Scaffold Package.swift and Directory Structure

**Context:** We're creating `demo/warbler-p2p/` as a new Swift package alongside the existing `demo/warbler/`. It depends on the Songbird framework (path dependency `../../`) and the Warbler monolith (path dependency `../warbler/`) for its domain modules. Each domain gets its own executable target.

**Files:**
- Create: `demo/warbler-p2p/Package.swift`
- Create: `demo/warbler-p2p/Sources/WarblerIdentityService/main.swift` (placeholder)
- Create: `demo/warbler-p2p/Sources/WarblerCatalogService/main.swift` (placeholder)
- Create: `demo/warbler-p2p/Sources/WarblerSubscriptionsService/main.swift` (placeholder)
- Create: `demo/warbler-p2p/Sources/WarblerAnalyticsService/main.swift` (placeholder)

**Step 1: Create the directory structure**

```bash
mkdir -p demo/warbler-p2p/Sources/WarblerIdentityService
mkdir -p demo/warbler-p2p/Sources/WarblerCatalogService
mkdir -p demo/warbler-p2p/Sources/WarblerSubscriptionsService
mkdir -p demo/warbler-p2p/Sources/WarblerAnalyticsService
```

**Step 2: Create Package.swift**

```swift
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WarblerP2P",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(name: "Songbird", path: "../../"),
        .package(name: "Warbler", path: "../warbler"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        // MARK: - Identity Service (:8081)

        .executableTarget(
            name: "WarblerIdentityService",
            dependencies: [
                .product(name: "WarblerIdentity", package: "Warbler"),
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdSQLite", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
                .product(name: "SongbirdHummingbird", package: "Songbird"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),

        // MARK: - Catalog Service (:8082)

        .executableTarget(
            name: "WarblerCatalogService",
            dependencies: [
                .product(name: "WarblerCatalog", package: "Warbler"),
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdSQLite", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
                .product(name: "SongbirdHummingbird", package: "Songbird"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),

        // MARK: - Subscriptions Service (:8083)

        .executableTarget(
            name: "WarblerSubscriptionsService",
            dependencies: [
                .product(name: "WarblerSubscriptions", package: "Warbler"),
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdSQLite", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
                .product(name: "SongbirdHummingbird", package: "Songbird"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),

        // MARK: - Analytics Service (:8084)

        .executableTarget(
            name: "WarblerAnalyticsService",
            dependencies: [
                .product(name: "WarblerAnalytics", package: "Warbler"),
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdSQLite", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
                .product(name: "SongbirdHummingbird", package: "Songbird"),
                .product(name: "SongbirdTesting", package: "Songbird"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
    ]
)
```

**Note:** The Analytics service needs `SongbirdTesting` for `InMemorySnapshotStore` (used by `ViewCountAggregate`'s snapshot policy — same as the monolith). All other services use only the core Songbird modules.

**Step 3: Create placeholder main.swift files**

Each placeholder should be a minimal `@main` struct that prints a startup message:

```swift
// For each of the 4 services, create main.swift with:
@main
struct <ServiceName> {
    static func main() async throws {
        print("<ServiceName> starting...")
    }
}
```

For example, `WarblerIdentityService/main.swift`:
```swift
@main
struct WarblerIdentityService {
    static func main() async throws {
        print("WarblerIdentityService starting...")
    }
}
```

**Step 4: Verify the package resolves**

```bash
cd demo/warbler-p2p && swift package resolve
```

Expected: Package resolves successfully, fetching hummingbird dependencies.

**Step 5: Verify the package builds**

```bash
cd demo/warbler-p2p && swift build 2>&1 | tail -5
```

Expected: Build succeeds with 4 executables.

**Step 6: Commit**

```bash
git add demo/warbler-p2p/
git commit -m "Scaffold Warbler P2P demo package with 4 executable targets"
```

---

### Task 2: WarblerIdentityService — Full Implementation

**Context:** The Identity service is the simplest domain — just aggregates, command handlers, and a projector. No process managers, gateways, or injectors. This serves as the template for all other services. The code is essentially the Identity section of the monolith's `main.swift` extracted into its own executable.

**Reference:** Read `demo/warbler/Sources/Warbler/main.swift` lines 1-170 for the Identity setup and routes. Read the monolith's registry setup (lines 18-21) for Identity event registration.

**Files:**
- Modify: `demo/warbler-p2p/Sources/WarblerIdentityService/main.swift`

**Step 1: Implement the full Identity service**

Replace the placeholder `main.swift` with:

```swift
import Foundation
import Hummingbird
import NIOCore
import Songbird
import SongbirdHummingbird
import SongbirdSQLite
import SongbirdSmew
import WarblerIdentity

@main
struct WarblerIdentityService {
    static func main() async throws {
        // MARK: - Configuration

        let sqlitePath = "data/songbird.sqlite"
        let duckdbPath = "data/identity.duckdb"
        let port = 8081

        // MARK: - Event Type Registry

        let registry = EventTypeRegistry()
        registry.register(UserEvent.self, eventTypes: ["UserRegistered", "ProfileUpdated", "UserDeactivated"])

        // MARK: - Stores

        let eventStore = try SQLiteEventStore(path: sqlitePath, registry: registry)
        let positionStore = InMemoryPositionStore()
        let readModel = try ReadModelStore(path: duckdbPath)

        // MARK: - Projectors

        let userProjector = UserProjector(readModel: readModel)
        await userProjector.registerMigration()
        try await readModel.migrate()

        // MARK: - Repositories

        let userRepo = AggregateRepository<UserAggregate>(store: eventStore, registry: registry)

        // MARK: - Services

        let pipeline = ProjectionPipeline()
        var mutableServices = SongbirdServices(
            eventStore: eventStore,
            projectionPipeline: pipeline,
            positionStore: positionStore,
            eventRegistry: registry
        )
        mutableServices.registerProjector(userProjector)
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

        // MARK: - Start

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("localhost", port: port))
        )

        print("WarblerIdentityService starting on http://localhost:\(port)")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await services.run() }
            group.addTask { try await app.runService() }
            try await group.waitForAll()
        }
    }
}
```

**Key differences from monolith:**
- Uses `SQLiteEventStore` with a file path instead of `InMemoryEventStore`
- Uses `ReadModelStore(path:)` with a file path instead of in-memory
- Only registers Identity events (not all 4 domains)
- Only registers the Identity projector
- No snapshot store, no process managers, no gateways, no injectors
- Listens on port 8081 instead of 8080
- Uses `InMemoryPositionStore` (imported from SongbirdTesting — wait, SongbirdTesting isn't a dependency for this target)

**Important fix:** The Identity service needs `InMemoryPositionStore` from `SongbirdTesting`, but we didn't add that dependency. Either:
1. Add `SongbirdTesting` as a dependency, OR
2. Use a different position store

Looking at the monolith, it uses `InMemoryPositionStore` which is in `SongbirdTesting`. The import in the monolith is `import SongbirdTesting`. We need to add `SongbirdTesting` to each service that needs a position store.

**Go back to Package.swift (Task 1) and add `SongbirdTesting` to ALL 4 targets.** Each needs:
```swift
.product(name: "SongbirdTesting", package: "Songbird"),
```

Then add `import SongbirdTesting` to the main.swift.

**Step 2: Create the data directory**

```bash
mkdir -p demo/warbler-p2p/data
echo "data/" > demo/warbler-p2p/.gitignore
```

**Step 3: Build and verify**

```bash
cd demo/warbler-p2p && swift build 2>&1 | tail -5
```

Expected: Build succeeds.

**Step 4: Commit**

```bash
git add demo/warbler-p2p/
git commit -m "Implement WarblerIdentityService (P2P demo)"
```

---

### Task 3: WarblerCatalogService — Full Implementation

**Context:** The Catalog service has aggregates, command handlers, a projector, and event versioning (VideoPublished v1 → v2 upcast). No process managers, gateways, or injectors.

**Reference:** Read `demo/warbler/Sources/Warbler/main.swift` lines 23-32 for Catalog event registration (including upcast), lines 57-58 for projector setup, lines 70-71 for repository, and lines 171-255 for Catalog routes.

**Files:**
- Modify: `demo/warbler-p2p/Sources/WarblerCatalogService/main.swift`

**Step 1: Implement the full Catalog service**

Replace the placeholder `main.swift` with:

```swift
import Foundation
import Hummingbird
import NIOCore
import Songbird
import SongbirdHummingbird
import SongbirdSQLite
import SongbirdSmew
import SongbirdTesting
import WarblerCatalog

@main
struct WarblerCatalogService {
    static func main() async throws {
        // MARK: - Configuration

        let sqlitePath = "data/songbird.sqlite"
        let duckdbPath = "data/catalog.duckdb"
        let port = 8082

        // MARK: - Event Type Registry

        let registry = EventTypeRegistry()

        // Catalog events (current version)
        registry.register(VideoEvent.self, eventTypes: ["VideoPublished", "VideoMetadataUpdated", "TranscodingCompleted", "VideoUnpublished"])

        // Catalog event versioning: v1 → v2 upcast
        registry.registerUpcast(
            from: VideoPublishedV1.self,
            to: VideoEvent.self,
            upcast: VideoPublishedUpcast(),
            oldEventType: "VideoPublished_v1"
        )

        // MARK: - Stores

        let eventStore = try SQLiteEventStore(path: sqlitePath, registry: registry)
        let positionStore = InMemoryPositionStore()
        let readModel = try ReadModelStore(path: duckdbPath)

        // MARK: - Projectors

        let videoCatalogProjector = VideoCatalogProjector(readModel: readModel)
        await videoCatalogProjector.registerMigration()
        try await readModel.migrate()

        // MARK: - Repositories

        let videoRepo = AggregateRepository<VideoAggregate>(store: eventStore, registry: registry)

        // MARK: - Services

        let pipeline = ProjectionPipeline()
        var mutableServices = SongbirdServices(
            eventStore: eventStore,
            projectionPipeline: pipeline,
            positionStore: positionStore,
            eventRegistry: registry
        )
        mutableServices.registerProjector(videoCatalogProjector)
        let services = mutableServices

        // MARK: - Router

        let router = Router(context: SongbirdRequestContext.self)
        router.addMiddleware { RequestIdMiddleware() }
        router.addMiddleware { ProjectionFlushMiddleware<SongbirdRequestContext>(pipeline: pipeline) }

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

        // MARK: - Start

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("localhost", port: port))
        )

        print("WarblerCatalogService starting on http://localhost:\(port)")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await services.run() }
            group.addTask { try await app.runService() }
            try await group.waitForAll()
        }
    }
}
```

**Step 2: Build and verify**

```bash
cd demo/warbler-p2p && swift build 2>&1 | tail -5
```

Expected: Build succeeds.

**Step 3: Commit**

```bash
git add demo/warbler-p2p/Sources/WarblerCatalogService/
git commit -m "Implement WarblerCatalogService (P2P demo)"
```

---

### Task 4: WarblerSubscriptionsService — Full Implementation

**Context:** The Subscriptions service is the most complex — it has a process manager (`SubscriptionLifecycleProcess`), a gateway (`EmailNotificationGateway`), and a projector. It handles both direct event appends (subscriptions) and process manager output events (lifecycle).

**Reference:** Read `demo/warbler/Sources/Warbler/main.swift` lines 34-36 for Subscription event registration, lines 60-61 for projector, lines 82-83 for gateway, lines 88-101 for services registration, and lines 257-295 for Subscription routes.

**Files:**
- Modify: `demo/warbler-p2p/Sources/WarblerSubscriptionsService/main.swift`

**Step 1: Implement the full Subscriptions service**

Replace the placeholder `main.swift` with:

```swift
import Foundation
import Hummingbird
import NIOCore
import Songbird
import SongbirdHummingbird
import SongbirdSQLite
import SongbirdSmew
import SongbirdTesting
import WarblerSubscriptions

@main
struct WarblerSubscriptionsService {
    static func main() async throws {
        // MARK: - Configuration

        let sqlitePath = "data/songbird.sqlite"
        let duckdbPath = "data/subscriptions.duckdb"
        let port = 8083

        // MARK: - Event Type Registry

        let registry = EventTypeRegistry()
        registry.register(SubscriptionEvent.self, eventTypes: ["SubscriptionRequested", "PaymentConfirmed", "PaymentFailed"])
        registry.register(SubscriptionLifecycleEvent.self, eventTypes: ["AccessGranted", "SubscriptionCancelled"])

        // MARK: - Stores

        let eventStore = try SQLiteEventStore(path: sqlitePath, registry: registry)
        let positionStore = InMemoryPositionStore()
        let readModel = try ReadModelStore(path: duckdbPath)

        // MARK: - Projectors

        let subscriptionProjector = SubscriptionProjector(readModel: readModel)
        await subscriptionProjector.registerMigration()
        try await readModel.migrate()

        // MARK: - Gateway

        let emailGateway = EmailNotificationGateway()

        // MARK: - Services

        let pipeline = ProjectionPipeline()
        var mutableServices = SongbirdServices(
            eventStore: eventStore,
            projectionPipeline: pipeline,
            positionStore: positionStore,
            eventRegistry: registry
        )
        mutableServices.registerProjector(subscriptionProjector)
        mutableServices.registerProcessManager(SubscriptionLifecycleProcess.self, tickInterval: .seconds(1))
        mutableServices.registerGateway(emailGateway, tickInterval: .seconds(1))
        let services = mutableServices

        // MARK: - Router

        let router = Router(context: SongbirdRequestContext.self)
        router.addMiddleware { RequestIdMiddleware() }
        router.addMiddleware { ProjectionFlushMiddleware<SongbirdRequestContext>(pipeline: pipeline) }

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

        // MARK: - Start

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("localhost", port: port))
        )

        print("WarblerSubscriptionsService starting on http://localhost:\(port)")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await services.run() }
            group.addTask { try await app.runService() }
            try await group.waitForAll()
        }
    }
}
```

**Key points:**
- Registers both `SubscriptionEvent` and `SubscriptionLifecycleEvent` (the process manager's output events)
- Registers the `SubscriptionLifecycleProcess` process manager with 1-second tick interval
- Registers the `EmailNotificationGateway` with 1-second tick interval
- Subscription routes use `appendAndProject` (not `executeAndProject`) — subscriptions don't use aggregates

**Step 2: Build and verify**

```bash
cd demo/warbler-p2p && swift build 2>&1 | tail -5
```

Expected: Build succeeds.

**Step 3: Commit**

```bash
git add demo/warbler-p2p/Sources/WarblerSubscriptionsService/
git commit -m "Implement WarblerSubscriptionsService (P2P demo)"
```

---

### Task 5: WarblerAnalyticsService — Full Implementation

**Context:** The Analytics service has a projector, an injector (`PlaybackInjector`), and a view-count aggregate with snapshot support. It also demonstrates tiered storage for the `video_views` table.

**Reference:** Read `demo/warbler/Sources/Warbler/main.swift` lines 38-40 for Analytics event registration, lines 63-64 for projector, lines 72-78 for view count repo with snapshots, lines 83 for injector, and lines 297-337 for Analytics routes.

**Files:**
- Modify: `demo/warbler-p2p/Sources/WarblerAnalyticsService/main.swift`

**Step 1: Implement the full Analytics service**

Replace the placeholder `main.swift` with:

```swift
import Foundation
import Hummingbird
import NIOCore
import Songbird
import SongbirdHummingbird
import SongbirdSQLite
import SongbirdSmew
import SongbirdTesting
import WarblerAnalytics

@main
struct WarblerAnalyticsService {
    static func main() async throws {
        // MARK: - Configuration

        let sqlitePath = "data/songbird.sqlite"
        let duckdbPath = "data/analytics.duckdb"
        let port = 8084

        // MARK: - Event Type Registry

        let registry = EventTypeRegistry()
        registry.register(AnalyticsEvent.self, eventTypes: ["VideoViewed"])
        registry.register(ViewCountEvent.self, eventTypes: ["ViewCounted"])

        // MARK: - Stores

        let eventStore = try SQLiteEventStore(path: sqlitePath, registry: registry)
        let positionStore = InMemoryPositionStore()
        let snapshotStore = InMemorySnapshotStore()
        let readModel = try ReadModelStore(path: duckdbPath)

        // MARK: - Projectors

        let playbackProjector = PlaybackAnalyticsProjector(readModel: readModel)
        await playbackProjector.registerMigration()
        try await readModel.migrate()

        // MARK: - Repositories

        let _viewCountRepo = AggregateRepository<ViewCountAggregate>(
            store: eventStore,
            registry: registry,
            snapshotStore: snapshotStore,
            snapshotPolicy: .everyNEvents(100)
        )
        _ = _viewCountRepo // Reserved for future view-count routes

        // MARK: - Injector

        let playbackInjector = PlaybackInjector()

        // MARK: - Services

        let pipeline = ProjectionPipeline()
        var mutableServices = SongbirdServices(
            eventStore: eventStore,
            projectionPipeline: pipeline,
            positionStore: positionStore,
            eventRegistry: registry
        )
        mutableServices.registerProjector(playbackProjector)
        mutableServices.registerInjector(playbackInjector)
        let services = mutableServices

        // MARK: - Router

        let router = Router(context: SongbirdRequestContext.self)
        router.addMiddleware { RequestIdMiddleware() }
        router.addMiddleware { ProjectionFlushMiddleware<SongbirdRequestContext>(pipeline: pipeline) }

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
            configuration: .init(address: .hostname("localhost", port: port))
        )

        print("WarblerAnalyticsService starting on http://localhost:\(port)")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await services.run() }
            group.addTask { try await app.runService() }
            try await group.waitForAll()
        }
    }
}
```

**Key points:**
- Registers `AnalyticsEvent` and `ViewCountEvent`
- Creates `InMemorySnapshotStore` for the `ViewCountAggregate` snapshot policy
- Registers `PlaybackInjector` as an injector
- The `POST /analytics/views` route injects events via the injector (returns 202 Accepted)
- The view count repo is created but unused (reserved for future routes), matching the monolith

**Step 2: Build and verify**

```bash
cd demo/warbler-p2p && swift build 2>&1 | tail -5
```

Expected: Build succeeds with all 4 executables.

**Step 3: Commit**

```bash
git add demo/warbler-p2p/Sources/WarblerAnalyticsService/
git commit -m "Implement WarblerAnalyticsService (P2P demo)"
```

---

### Task 6: Launch Script

**Context:** Create a shell script that starts all 4 services, ensures the data directory exists, and handles graceful shutdown.

**Files:**
- Create: `demo/warbler-p2p/launch.sh`

**Step 1: Create the launch script**

```bash
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
```

**Step 2: Make the script executable**

```bash
chmod +x demo/warbler-p2p/launch.sh
```

**Step 3: Commit**

```bash
git add demo/warbler-p2p/launch.sh
git commit -m "Add launch script for Warbler P2P demo"
```

---

### Task 7: README.md

**Context:** Create documentation explaining what the P2P demo is, how to run it, and how to interact with the API.

**Files:**
- Create: `demo/warbler-p2p/README.md`

**Step 1: Create the README**

```markdown
# Warbler P2P

Peer-to-peer multi-process version of the Warbler demo app. Each bounded context runs as its own Hummingbird HTTP server on a dedicated port, communicating solely through a shared SQLite event store.

This demonstrates Garofolo's "message store as transport" pattern — no gateway, no distributed actors. The event store IS the communication mechanism between services.

## Quick Start

```bash
./launch.sh
```

This builds and starts all 4 services. Press Ctrl+C to stop.

## Services

| Port | Service | Domain |
|------|---------|--------|
| 8081 | WarblerIdentityService | Users |
| 8082 | WarblerCatalogService | Videos |
| 8083 | WarblerSubscriptionsService | Subscriptions |
| 8084 | WarblerAnalyticsService | Analytics |

## API Examples

### Create a user
```bash
curl -X POST http://localhost:8081/users/alice \
  -H "Content-Type: application/json" \
  -d '{"email": "alice@example.com", "displayName": "Alice"}'
```

### Get a user
```bash
curl http://localhost:8081/users/alice
```

### Publish a video
```bash
curl -X POST http://localhost:8082/videos/vid-1 \
  -H "Content-Type: application/json" \
  -d '{"title": "Swift Concurrency", "description": "A deep dive", "creatorId": "alice"}'
```

### List videos
```bash
curl http://localhost:8082/videos
```

### Create a subscription
```bash
curl -X POST http://localhost:8083/subscriptions/sub-1 \
  -H "Content-Type: application/json" \
  -d '{"userId": "alice", "plan": "premium"}'
```

### Confirm payment
```bash
curl -X POST http://localhost:8083/subscriptions/sub-1/pay
```

### Record a video view
```bash
curl -X POST http://localhost:8084/analytics/views \
  -H "Content-Type: application/json" \
  -d '{"videoId": "vid-1", "userId": "alice", "watchedSeconds": 120}'
```

### Get video analytics
```bash
curl http://localhost:8084/analytics/videos/vid-1/views
```

### Top videos
```bash
curl http://localhost:8084/analytics/top-videos
```

## Architecture

```
HTTP Clients
    │
    ├── :8081 ──▶ Identity (users)
    ├── :8082 ──▶ Catalog (videos)
    ├── :8083 ──▶ Subscriptions (plans, payments)
    └── :8084 ──▶ Analytics (views, metrics)
                      │
                      ▼
            ┌───────────────────┐
            │ songbird.sqlite   │  ← Shared event store
            │ (all 4 write)     │
            └───────────────────┘
```

Each service has its own DuckDB read model (`data/*.duckdb`). Cross-domain coordination happens through event subscriptions polling the shared event store.

## Data

All data is stored in the `data/` directory:
- `songbird.sqlite` — Shared event store
- `identity.duckdb` — Identity read model
- `catalog.duckdb` — Catalog read model
- `subscriptions.duckdb` — Subscriptions read model
- `analytics.duckdb` — Analytics read model

To reset, delete the `data/` directory and restart.

## Comparison with Other Demos

| Aspect | Monolith | P2P |
|--------|----------|-----|
| Processes | 1 | 4 |
| Communication | In-process | Shared event store |
| Single entry point | :8080 | 4 ports |
| Domain code changes | — | Zero |
```

**Step 2: Commit**

```bash
git add demo/warbler-p2p/README.md
git commit -m "Add README for Warbler P2P demo"
```

---

### Task 8: Update Package.swift — Add SongbirdTesting Dependency

**Context:** During Task 2 implementation, we realized all 4 services need `InMemoryPositionStore` from `SongbirdTesting`. Go back and fix the Package.swift to add this dependency to all targets that need it (Identity, Catalog, and Subscriptions — Analytics already has it from Task 1).

**Important:** This task should actually be done as part of Task 1 before any service is implemented. It's listed separately here as a reminder. If you're executing tasks in order, fold this fix into Task 1's Package.swift.

**Files:**
- Modify: `demo/warbler-p2p/Package.swift`

**Step 1: Add SongbirdTesting to Identity, Catalog, and Subscriptions targets**

In the Package.swift, add to each target's dependencies:
```swift
.product(name: "SongbirdTesting", package: "Songbird"),
```

The final target dependencies should be:

**WarblerIdentityService:**
```swift
dependencies: [
    .product(name: "WarblerIdentity", package: "Warbler"),
    .product(name: "Songbird", package: "Songbird"),
    .product(name: "SongbirdSQLite", package: "Songbird"),
    .product(name: "SongbirdSmew", package: "Songbird"),
    .product(name: "SongbirdHummingbird", package: "Songbird"),
    .product(name: "SongbirdTesting", package: "Songbird"),
    .product(name: "Hummingbird", package: "hummingbird"),
]
```

**WarblerCatalogService:**
```swift
dependencies: [
    .product(name: "WarblerCatalog", package: "Warbler"),
    .product(name: "Songbird", package: "Songbird"),
    .product(name: "SongbirdSQLite", package: "Songbird"),
    .product(name: "SongbirdSmew", package: "Songbird"),
    .product(name: "SongbirdHummingbird", package: "Songbird"),
    .product(name: "SongbirdTesting", package: "Songbird"),
    .product(name: "Hummingbird", package: "hummingbird"),
]
```

**WarblerSubscriptionsService:**
```swift
dependencies: [
    .product(name: "WarblerSubscriptions", package: "Warbler"),
    .product(name: "Songbird", package: "Songbird"),
    .product(name: "SongbirdSQLite", package: "Songbird"),
    .product(name: "SongbirdSmew", package: "Songbird"),
    .product(name: "SongbirdHummingbird", package: "Songbird"),
    .product(name: "SongbirdTesting", package: "Songbird"),
    .product(name: "Hummingbird", package: "hummingbird"),
]
```

**Note for implementer:** This is already reflected in the Task 1 Package.swift code above. If you implemented Task 1 correctly, this task is already done. This exists as a verification checkpoint.

**Step 2: Verify build**

```bash
cd demo/warbler-p2p && swift build 2>&1 | tail -5
```

**Step 3: Commit (if changes were needed)**

```bash
git add demo/warbler-p2p/Package.swift
git commit -m "Add SongbirdTesting dependency to all P2P service targets"
```

---

### Task 9: End-to-End Smoke Test

**Context:** Manually verify that the P2P demo works end-to-end. Start all services, create data through the API, and verify cross-domain event flow.

**Step 1: Start all services**

```bash
cd demo/warbler-p2p && ./launch.sh
```

Wait for all 4 "starting on http://localhost:808X" messages.

**Step 2: Test Identity service**

```bash
# Create a user
curl -s -X POST http://localhost:8081/users/alice \
  -H "Content-Type: application/json" \
  -d '{"email": "alice@example.com", "displayName": "Alice"}'
# Expected: 201 Created

# Read the user
curl -s http://localhost:8081/users/alice | python3 -m json.tool
# Expected: {"id": "alice", "email": "alice@example.com", "displayName": "Alice", "isActive": true}
```

**Step 3: Test Catalog service**

```bash
# Publish a video
curl -s -X POST http://localhost:8082/videos/vid-1 \
  -H "Content-Type: application/json" \
  -d '{"title": "Swift Concurrency", "description": "A deep dive", "creatorId": "alice"}'
# Expected: 201 Created

# List videos
curl -s http://localhost:8082/videos | python3 -m json.tool
# Expected: Array with one video, status "transcoding"
```

**Step 4: Test Subscriptions service**

```bash
# Create subscription
curl -s -X POST http://localhost:8083/subscriptions/sub-1 \
  -H "Content-Type: application/json" \
  -d '{"userId": "alice", "plan": "premium"}'
# Expected: 201 Created

# Confirm payment
curl -s -X POST http://localhost:8083/subscriptions/sub-1/pay
# Expected: 200 OK

# Check subscription status (wait 1-2 seconds for process manager)
sleep 2
curl -s http://localhost:8083/subscriptions/alice | python3 -m json.tool
# Expected: subscription with status "active" (after process manager processes)
```

**Step 5: Test Analytics service**

```bash
# Record a view
curl -s -X POST http://localhost:8084/analytics/views \
  -H "Content-Type: application/json" \
  -d '{"videoId": "vid-1", "userId": "alice", "watchedSeconds": 120}'
# Expected: 202 Accepted

# Wait for injector to process
sleep 1

# Check analytics
curl -s http://localhost:8084/analytics/videos/vid-1/views | python3 -m json.tool
# Expected: {"viewCount": 1, "totalSeconds": 120}
```

**Step 6: Stop all services (Ctrl+C)**

**Step 7: Verify shared event store**

The SQLite file should contain events from all 4 services:

```bash
sqlite3 demo/warbler-p2p/data/songbird.sqlite "SELECT stream_category, event_type, COUNT(*) FROM events GROUP BY stream_category, event_type"
```

Expected output should show events in categories: `user`, `video`, `subscription`, `subscription-lifecycle`, `analytics`.

---

### Task 10: Changelog Entry

**Context:** Document the Warbler P2P demo in the changelog.

**Files:**
- Create: `changelog/0019-warbler-p2p-demo.md`

**Step 1: Write the changelog entry**

```markdown
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
```

**Step 2: Commit**

```bash
git add changelog/0019-warbler-p2p-demo.md
git commit -m "Add Warbler P2P demo changelog entry"
```

---

### Task 11: Final Build Verification & Clean Up

**Context:** Ensure everything builds cleanly with zero warnings and the full Songbird test suite still passes.

**Step 1: Clean build of the P2P package**

```bash
cd demo/warbler-p2p && swift package clean && swift build 2>&1
```

Expected: Build succeeds with zero warnings.

**Step 2: Run the Songbird framework test suite**

```bash
cd /Users/greg/Development/Songbird && swift test 2>&1 | tail -20
```

Expected: All existing tests pass. The P2P demo is a separate package, so framework tests should be unaffected.

**Step 3: Verify all 4 executables exist**

```bash
ls -la demo/warbler-p2p/.build/debug/WarblerIdentityService demo/warbler-p2p/.build/debug/WarblerCatalogService demo/warbler-p2p/.build/debug/WarblerSubscriptionsService demo/warbler-p2p/.build/debug/WarblerAnalyticsService
```

Expected: All 4 executables present.

**Step 4: Final commit if any cleanup was needed**

```bash
git status
# If there are changes:
git add -A && git commit -m "Final cleanup for Warbler P2P demo"
```
