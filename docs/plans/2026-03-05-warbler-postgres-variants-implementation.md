# Warbler Postgres Variants Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create Postgres-backed versions of all three multi-process Warbler demos (distributed-pg, p2p-pg, p2p-proxy-pg), swapping SQLiteEventStore for PostgresEventStore.

**Architecture:** Each variant is a separate demo package that mirrors its SQLite counterpart. Domain code is completely unchanged — only store initialization differs. Workers/services create a `PostgresClient`, run migrations, and use `PostgresEventStore`, `PostgresPositionStore`, and `PostgresSnapshotStore` instead of their SQLite/in-memory equivalents. The proxy variant has no Swift code — just a launch script.

**Tech Stack:** SongbirdPostgres (PostgresNIO, postgres-migrations), Hummingbird, SongbirdDistributed, SongbirdSmew, Warbler domain modules

---

### Task 1: Scaffold warbler-distributed-pg Package

**Files:**
- Create: `demo/warbler-distributed-pg/Package.swift`

**Step 1: Create the Package.swift**

```bash
mkdir -p demo/warbler-distributed-pg/Sources/WarblerGateway
mkdir -p demo/warbler-distributed-pg/Sources/WarblerIdentityWorker
mkdir -p demo/warbler-distributed-pg/Sources/WarblerCatalogWorker
mkdir -p demo/warbler-distributed-pg/Sources/WarblerSubscriptionsWorker
mkdir -p demo/warbler-distributed-pg/Sources/WarblerAnalyticsWorker
```

Create `demo/warbler-distributed-pg/Package.swift`:

```swift
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WarblerDistributedPG",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(name: "Songbird", path: "../../"),
        .package(name: "Warbler", path: "../warbler"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        // MARK: - Gateway (HTTP → distributed actor calls) — unchanged from SQLite variant

        .executableTarget(
            name: "WarblerGateway",
            dependencies: [
                .product(name: "SongbirdHummingbird", package: "Songbird"),
                .product(name: "SongbirdDistributed", package: "Songbird"),
                .product(name: "WarblerIdentity", package: "Warbler"),
                .product(name: "WarblerCatalog", package: "Warbler"),
                .product(name: "WarblerSubscriptions", package: "Warbler"),
                .product(name: "WarblerAnalytics", package: "Warbler"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),

        // MARK: - Workers (Postgres-backed)

        .executableTarget(
            name: "WarblerIdentityWorker",
            dependencies: [
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdPostgres", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
                .product(name: "SongbirdHummingbird", package: "Songbird"),
                .product(name: "SongbirdDistributed", package: "Songbird"),
                .product(name: "WarblerIdentity", package: "Warbler"),
            ]
        ),

        .executableTarget(
            name: "WarblerCatalogWorker",
            dependencies: [
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdPostgres", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
                .product(name: "SongbirdHummingbird", package: "Songbird"),
                .product(name: "SongbirdDistributed", package: "Songbird"),
                .product(name: "WarblerCatalog", package: "Warbler"),
            ]
        ),

        .executableTarget(
            name: "WarblerSubscriptionsWorker",
            dependencies: [
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdPostgres", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
                .product(name: "SongbirdHummingbird", package: "Songbird"),
                .product(name: "SongbirdDistributed", package: "Songbird"),
                .product(name: "WarblerSubscriptions", package: "Warbler"),
            ]
        ),

        .executableTarget(
            name: "WarblerAnalyticsWorker",
            dependencies: [
                .product(name: "Songbird", package: "Songbird"),
                .product(name: "SongbirdPostgres", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
                .product(name: "SongbirdHummingbird", package: "Songbird"),
                .product(name: "SongbirdDistributed", package: "Songbird"),
                .product(name: "WarblerAnalytics", package: "Warbler"),
            ]
        ),
    ]
)
```

Note: The key change from `demo/warbler-distributed/Package.swift` is replacing `.product(name: "SongbirdSQLite", ...)` with `.product(name: "SongbirdPostgres", ...)` in all 4 worker targets. The Gateway target is unchanged.

**Step 2: Verify the directory structure was created**

Run: `find demo/warbler-distributed-pg -type f | sort`

**Step 3: Commit**

```bash
git add demo/warbler-distributed-pg/Package.swift
git commit -m "Scaffold warbler-distributed-pg package"
```

---

### Task 2: Gateway (unchanged copy)

**Files:**
- Create: `demo/warbler-distributed-pg/Sources/WarblerGateway/main.swift`

**Step 1: Copy the Gateway source unchanged**

The Gateway has no event store — it only forwards distributed actor calls. Copy it verbatim from the SQLite variant:

```bash
cp demo/warbler-distributed/Sources/WarblerGateway/main.swift demo/warbler-distributed-pg/Sources/WarblerGateway/main.swift
```

The file is identical — no changes needed. It imports `Songbird`, `SongbirdDistributed`, `SongbirdHummingbird`, `Hummingbird`, and the Warbler domain modules. No SQLite or Postgres imports.

**Step 2: Commit**

```bash
git add demo/warbler-distributed-pg/Sources/WarblerGateway/main.swift
git commit -m "Add distributed-pg gateway (unchanged from SQLite variant)"
```

---

### Task 3: Distributed Identity Worker (Postgres)

**Files:**
- Create: `demo/warbler-distributed-pg/Sources/WarblerIdentityWorker/main.swift`

**Step 1: Create the Postgres variant of the identity worker**

This is based on `demo/warbler-distributed/Sources/WarblerIdentityWorker/main.swift` with these changes:
- Replace `import SongbirdSQLite` with `import SongbirdPostgres`, `import PostgresNIO`, `import Logging`
- Remove SQLite path CLI argument (now 2 args: `<duckdb-path> <socket-path>`)
- Replace `SQLiteEventStore(path:registry:)` with `PostgresEventStore(client:registry:)`
- Replace `SQLitePositionStore(path:)` with `PostgresPositionStore(client:)`
- Add `PostgresClient` creation from env vars
- Add `SongbirdPostgresMigrations.apply(client:logger:)`
- Add `client.run()` to run alongside `services.run()`

Create `demo/warbler-distributed-pg/Sources/WarblerIdentityWorker/main.swift`:

```swift
import Distributed
import Foundation
import Logging
import PostgresNIO
import Songbird
import SongbirdDistributed
import SongbirdHummingbird
import SongbirdPostgres
import SongbirdSmew
import WarblerIdentity

// MARK: - Distributed Command Handler

distributed actor IdentityCommandHandler {
    typealias ActorSystem = SongbirdActorSystem

    let services: SongbirdServices
    let repository: AggregateRepository<UserAggregate>
    let readModel: ReadModelStore

    init(
        actorSystem: SongbirdActorSystem,
        services: SongbirdServices,
        repository: AggregateRepository<UserAggregate>,
        readModel: ReadModelStore
    ) {
        self.actorSystem = actorSystem
        self.services = services
        self.repository = repository
        self.readModel = readModel
    }

    // MARK: - Commands

    distributed func registerUser(id: String, email: String, displayName: String) async throws {
        try await executeAndProject(
            RegisterUser(email: email, displayName: displayName),
            on: id,
            metadata: EventMetadata(),
            using: RegisterUserHandler.self,
            repository: repository,
            services: services
        )
    }

    distributed func updateProfile(userId: String, displayName: String) async throws {
        try await executeAndProject(
            UpdateProfile(displayName: displayName),
            on: userId,
            metadata: EventMetadata(),
            using: UpdateProfileHandler.self,
            repository: repository,
            services: services
        )
    }

    distributed func deactivateUser(userId: String) async throws {
        try await executeAndProject(
            DeactivateUser(),
            on: userId,
            metadata: EventMetadata(),
            using: DeactivateUserHandler.self,
            repository: repository,
            services: services
        )
    }

    // MARK: - Queries

    distributed func getUser(id: String) async throws -> UserDTO? {
        try await readModel.queryFirst(UserDTO.self) {
            "SELECT id, email, display_name, is_active FROM users WHERE id = \(param: id)"
        }
    }
}

/// DTO for the user query result (must be Codable for distributed transport).
public struct UserDTO: Codable, Sendable {
    public let id: String
    public let email: String
    public let displayName: String
    public let isActive: Bool
}

// MARK: - Bootstrap

@main
struct WarblerIdentityWorkerApp {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("Usage: WarblerIdentityWorker <duckdb-path> <socket-path>")
            return
        }
        let duckdbPath = args[1]
        let socketPath = args[2]

        // Postgres configuration from environment
        let pgConfig = PostgresClient.Configuration(
            host: ProcessInfo.processInfo.environment["POSTGRES_HOST"] ?? "localhost",
            port: Int(ProcessInfo.processInfo.environment["POSTGRES_PORT"] ?? "5432") ?? 5432,
            username: ProcessInfo.processInfo.environment["POSTGRES_USER"] ?? "warbler",
            password: ProcessInfo.processInfo.environment["POSTGRES_PASSWORD"] ?? "warbler",
            database: ProcessInfo.processInfo.environment["POSTGRES_DB"] ?? "warbler",
            tls: .disable
        )
        let client = PostgresClient(configuration: pgConfig)
        let logger = Logger(label: "warbler.identity")

        // Run migrations
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask {
                try await SongbirdPostgresMigrations.apply(client: client, logger: logger)
            }
            // Wait for migrations to complete, then cancel client.run()
            try await group.next()
            group.cancelAll()
        }

        // Event type registry
        let registry = EventTypeRegistry()
        registry.register(UserEvent.self, eventTypes: ["UserRegistered", "ProfileUpdated", "UserDeactivated"])

        // Stores (Postgres-backed)
        let eventStore = PostgresEventStore(client: client, registry: registry)
        let positionStore = PostgresPositionStore(client: client)

        // Read model (per-worker DuckDB)
        let readModel = try ReadModelStore(path: duckdbPath)

        // Projector
        let userProjector = UserProjector(readModel: readModel)
        await userProjector.registerMigration()
        try await readModel.migrate()

        // Projection pipeline
        let pipeline = ProjectionPipeline()

        // Services
        var mutableServices = SongbirdServices(
            eventStore: eventStore,
            projectionPipeline: pipeline,
            positionStore: positionStore,
            eventRegistry: registry
        )
        mutableServices.registerProjector(userProjector)
        let services = mutableServices

        // Aggregate repository
        let repository = AggregateRepository<UserAggregate>(
            store: eventStore, registry: registry
        )

        // Distributed actor system
        let system = SongbirdActorSystem(processName: "identity-worker")
        try await system.startServer(socketPath: socketPath)

        // Create and register the command handler
        let handler = IdentityCommandHandler(
            actorSystem: system,
            services: services,
            repository: repository,
            readModel: readModel
        )
        _ = handler  // Keep alive

        print("Identity worker (Postgres) started on \(socketPath)")

        // Run services + Postgres client
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask { try await services.run() }
            try await group.waitForAll()
        }
    }
}
```

**Key differences from SQLite variant:**
- Imports: `SongbirdPostgres`, `PostgresNIO`, `Logging` instead of `SongbirdSQLite`
- CLI args: 2 args (`duckdb-path`, `socket-path`) instead of 3 (no `sqlite-path`)
- Postgres client created from env vars with defaults
- Migrations run at startup (requires temporary task group for `client.run()`)
- `PostgresEventStore(client:registry:)` instead of `SQLiteEventStore(path:registry:)`
- `PostgresPositionStore(client:)` instead of `SQLitePositionStore(path:)`
- `client.run()` in final task group alongside `services.run()`

**Step 2: Commit**

```bash
git add demo/warbler-distributed-pg/Sources/WarblerIdentityWorker/main.swift
git commit -m "Add distributed-pg identity worker with Postgres stores"
```

---

### Task 4: Distributed Catalog Worker (Postgres)

**Files:**
- Create: `demo/warbler-distributed-pg/Sources/WarblerCatalogWorker/main.swift`

**Step 1: Create the Postgres variant of the catalog worker**

Same transformation as the identity worker, plus preserves the `VideoPublishedV1` upcast registration.

Create `demo/warbler-distributed-pg/Sources/WarblerCatalogWorker/main.swift`:

```swift
import Distributed
import Foundation
import Logging
import PostgresNIO
import Songbird
import SongbirdDistributed
import SongbirdHummingbird
import SongbirdPostgres
import SongbirdSmew
import WarblerCatalog

// MARK: - Distributed Command Handler

distributed actor CatalogCommandHandler {
    typealias ActorSystem = SongbirdActorSystem

    let services: SongbirdServices
    let repository: AggregateRepository<VideoAggregate>
    let readModel: ReadModelStore

    init(
        actorSystem: SongbirdActorSystem,
        services: SongbirdServices,
        repository: AggregateRepository<VideoAggregate>,
        readModel: ReadModelStore
    ) {
        self.actorSystem = actorSystem
        self.services = services
        self.repository = repository
        self.readModel = readModel
    }

    // MARK: - Commands

    distributed func publishVideo(id: String, title: String, description: String, creatorId: String) async throws {
        try await executeAndProject(
            PublishVideo(title: title, description: description, creatorId: creatorId),
            on: id,
            metadata: EventMetadata(),
            using: PublishVideoHandler.self,
            repository: repository,
            services: services
        )
    }

    distributed func updateVideoMetadata(id: String, title: String, description: String) async throws {
        try await executeAndProject(
            UpdateVideoMetadata(title: title, description: description),
            on: id,
            metadata: EventMetadata(),
            using: UpdateVideoMetadataHandler.self,
            repository: repository,
            services: services
        )
    }

    distributed func completeTranscoding(id: String) async throws {
        try await executeAndProject(
            CompleteTranscoding(),
            on: id,
            metadata: EventMetadata(),
            using: CompleteTranscodingHandler.self,
            repository: repository,
            services: services
        )
    }

    distributed func unpublishVideo(id: String) async throws {
        try await executeAndProject(
            UnpublishVideo(),
            on: id,
            metadata: EventMetadata(),
            using: UnpublishVideoHandler.self,
            repository: repository,
            services: services
        )
    }

    // MARK: - Queries

    distributed func getVideo(id: String) async throws -> VideoDTO? {
        try await readModel.queryFirst(VideoDTO.self) {
            "SELECT id, title, description, creator_id, status FROM videos WHERE id = \(param: id)"
        }
    }

    distributed func listVideos() async throws -> [VideoDTO] {
        try await readModel.query(VideoDTO.self) {
            "SELECT id, title, description, creator_id, status FROM videos ORDER BY title"
        }
    }
}

public struct VideoDTO: Codable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    public let creatorId: String
    public let status: String
}

// MARK: - Bootstrap

@main
struct WarblerCatalogWorkerApp {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("Usage: WarblerCatalogWorker <duckdb-path> <socket-path>")
            return
        }
        let duckdbPath = args[1]
        let socketPath = args[2]

        // Postgres configuration from environment
        let pgConfig = PostgresClient.Configuration(
            host: ProcessInfo.processInfo.environment["POSTGRES_HOST"] ?? "localhost",
            port: Int(ProcessInfo.processInfo.environment["POSTGRES_PORT"] ?? "5432") ?? 5432,
            username: ProcessInfo.processInfo.environment["POSTGRES_USER"] ?? "warbler",
            password: ProcessInfo.processInfo.environment["POSTGRES_PASSWORD"] ?? "warbler",
            database: ProcessInfo.processInfo.environment["POSTGRES_DB"] ?? "warbler",
            tls: .disable
        )
        let client = PostgresClient(configuration: pgConfig)
        let logger = Logger(label: "warbler.catalog")

        // Run migrations
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask {
                try await SongbirdPostgresMigrations.apply(client: client, logger: logger)
            }
            try await group.next()
            group.cancelAll()
        }

        // Event type registry (with versioning upcast)
        let registry = EventTypeRegistry()
        registry.register(VideoEvent.self, eventTypes: ["VideoPublished", "VideoMetadataUpdated", "TranscodingCompleted", "VideoUnpublished"])
        registry.registerUpcast(
            from: VideoPublishedV1.self,
            to: VideoEvent.self,
            upcast: VideoPublishedUpcast(),
            oldEventType: "VideoPublished_v1"
        )

        // Stores (Postgres-backed)
        let eventStore = PostgresEventStore(client: client, registry: registry)
        let positionStore = PostgresPositionStore(client: client)

        // Read model (per-worker DuckDB)
        let readModel = try ReadModelStore(path: duckdbPath)

        let videoCatalogProjector = VideoCatalogProjector(readModel: readModel)
        await videoCatalogProjector.registerMigration()
        try await readModel.migrate()

        let pipeline = ProjectionPipeline()

        var mutableServices = SongbirdServices(
            eventStore: eventStore,
            projectionPipeline: pipeline,
            positionStore: positionStore,
            eventRegistry: registry
        )
        mutableServices.registerProjector(videoCatalogProjector)
        let services = mutableServices

        let repository = AggregateRepository<VideoAggregate>(
            store: eventStore, registry: registry
        )

        let system = SongbirdActorSystem(processName: "catalog-worker")
        try await system.startServer(socketPath: socketPath)

        let handler = CatalogCommandHandler(
            actorSystem: system,
            services: services,
            repository: repository,
            readModel: readModel
        )
        _ = handler

        print("Catalog worker (Postgres) started on \(socketPath)")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask { try await services.run() }
            try await group.waitForAll()
        }
    }
}
```

**Step 2: Commit**

```bash
git add demo/warbler-distributed-pg/Sources/WarblerCatalogWorker/main.swift
git commit -m "Add distributed-pg catalog worker with Postgres stores"
```

---

### Task 5: Distributed Subscriptions Worker (Postgres)

**Files:**
- Create: `demo/warbler-distributed-pg/Sources/WarblerSubscriptionsWorker/main.swift`

**Step 1: Create the Postgres variant of the subscriptions worker**

Same transformation. Preserves process manager and gateway registration.

Create `demo/warbler-distributed-pg/Sources/WarblerSubscriptionsWorker/main.swift`:

```swift
import Distributed
import Foundation
import Logging
import PostgresNIO
import Songbird
import SongbirdDistributed
import SongbirdHummingbird
import SongbirdPostgres
import SongbirdSmew
import WarblerSubscriptions

// MARK: - Distributed Command Handler

distributed actor SubscriptionsCommandHandler {
    typealias ActorSystem = SongbirdActorSystem

    let services: SongbirdServices
    let readModel: ReadModelStore

    init(
        actorSystem: SongbirdActorSystem,
        services: SongbirdServices,
        readModel: ReadModelStore
    ) {
        self.actorSystem = actorSystem
        self.services = services
        self.readModel = readModel
    }

    // MARK: - Commands

    distributed func requestSubscription(id: String, userId: String, plan: String) async throws {
        try await appendAndProject(
            SubscriptionEvent.requested(subscriptionId: id, userId: userId, plan: plan),
            to: StreamName(category: "subscription", id: id),
            metadata: EventMetadata(),
            services: services
        )
    }

    distributed func confirmPayment(subscriptionId: String) async throws {
        try await appendAndProject(
            SubscriptionEvent.paymentConfirmed(subscriptionId: subscriptionId),
            to: StreamName(category: "subscription", id: subscriptionId),
            metadata: EventMetadata(),
            services: services
        )
    }

    // MARK: - Queries

    distributed func getSubscriptions(userId: String) async throws -> [SubscriptionDTO] {
        try await readModel.query(SubscriptionDTO.self) {
            "SELECT id, user_id, plan, status FROM subscriptions WHERE user_id = \(param: userId)"
        }
    }
}

public struct SubscriptionDTO: Codable, Sendable {
    public let id: String
    public let userId: String
    public let plan: String
    public let status: String
}

// MARK: - Bootstrap

@main
struct WarblerSubscriptionsWorkerApp {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("Usage: WarblerSubscriptionsWorker <duckdb-path> <socket-path>")
            return
        }
        let duckdbPath = args[1]
        let socketPath = args[2]

        // Postgres configuration from environment
        let pgConfig = PostgresClient.Configuration(
            host: ProcessInfo.processInfo.environment["POSTGRES_HOST"] ?? "localhost",
            port: Int(ProcessInfo.processInfo.environment["POSTGRES_PORT"] ?? "5432") ?? 5432,
            username: ProcessInfo.processInfo.environment["POSTGRES_USER"] ?? "warbler",
            password: ProcessInfo.processInfo.environment["POSTGRES_PASSWORD"] ?? "warbler",
            database: ProcessInfo.processInfo.environment["POSTGRES_DB"] ?? "warbler",
            tls: .disable
        )
        let client = PostgresClient(configuration: pgConfig)
        let logger = Logger(label: "warbler.subscriptions")

        // Run migrations
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask {
                try await SongbirdPostgresMigrations.apply(client: client, logger: logger)
            }
            try await group.next()
            group.cancelAll()
        }

        let registry = EventTypeRegistry()
        registry.register(SubscriptionEvent.self, eventTypes: ["SubscriptionRequested", "PaymentConfirmed", "PaymentFailed"])
        registry.register(SubscriptionLifecycleEvent.self, eventTypes: ["AccessGranted", "SubscriptionCancelled"])

        // Stores (Postgres-backed)
        let eventStore = PostgresEventStore(client: client, registry: registry)
        let positionStore = PostgresPositionStore(client: client)

        // Read model (per-worker DuckDB)
        let readModel = try ReadModelStore(path: duckdbPath)

        let subscriptionProjector = SubscriptionProjector(readModel: readModel)
        await subscriptionProjector.registerMigration()
        try await readModel.migrate()

        let emailGateway = EmailNotificationGateway()
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

        let system = SongbirdActorSystem(processName: "subscriptions-worker")
        try await system.startServer(socketPath: socketPath)

        let handler = SubscriptionsCommandHandler(
            actorSystem: system,
            services: services,
            readModel: readModel
        )
        _ = handler

        print("Subscriptions worker (Postgres) started on \(socketPath)")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask { try await services.run() }
            try await group.waitForAll()
        }
    }
}
```

**Step 2: Commit**

```bash
git add demo/warbler-distributed-pg/Sources/WarblerSubscriptionsWorker/main.swift
git commit -m "Add distributed-pg subscriptions worker with Postgres stores"
```

---

### Task 6: Distributed Analytics Worker (Postgres)

**Files:**
- Create: `demo/warbler-distributed-pg/Sources/WarblerAnalyticsWorker/main.swift`

**Step 1: Create the Postgres variant of the analytics worker**

Same transformation. Replaces `SQLiteSnapshotStore` with `PostgresSnapshotStore`. Preserves the `PlaybackInjector`.

Create `demo/warbler-distributed-pg/Sources/WarblerAnalyticsWorker/main.swift`:

```swift
import Distributed
import Foundation
import Logging
import PostgresNIO
import Songbird
import SongbirdDistributed
import SongbirdHummingbird
import SongbirdPostgres
import SongbirdSmew
import WarblerAnalytics

// MARK: - Distributed Command Handler

distributed actor AnalyticsCommandHandler {
    typealias ActorSystem = SongbirdActorSystem

    let services: SongbirdServices
    let readModel: ReadModelStore
    let playbackInjector: PlaybackInjector

    init(
        actorSystem: SongbirdActorSystem,
        services: SongbirdServices,
        readModel: ReadModelStore,
        playbackInjector: PlaybackInjector
    ) {
        self.actorSystem = actorSystem
        self.services = services
        self.readModel = readModel
        self.playbackInjector = playbackInjector
    }

    // MARK: - Commands

    distributed func recordView(videoId: String, userId: String, watchedSeconds: Int) async throws {
        let event = AnalyticsEvent.videoViewed(videoId: videoId, userId: userId, watchedSeconds: watchedSeconds)
        let inbound = InboundEvent(
            event: event,
            stream: StreamName(category: "analytics", id: videoId),
            metadata: EventMetadata()
        )
        await playbackInjector.inject(inbound)
    }

    // MARK: - Queries

    distributed func getVideoViews(videoId: String) async throws -> ViewCountDTO? {
        try await readModel.queryFirst(ViewCountDTO.self) {
            "SELECT COUNT(*) AS view_count, COALESCE(SUM(watched_seconds), 0) AS total_seconds FROM video_views WHERE video_id = \(param: videoId)"
        }
    }

    distributed func getTopVideos() async throws -> [TopVideoDTO] {
        try await readModel.query(TopVideoDTO.self) {
            "SELECT video_id, COUNT(*) AS view_count, SUM(watched_seconds) AS total_seconds FROM video_views GROUP BY video_id ORDER BY view_count DESC LIMIT 10"
        }
    }
}

public struct ViewCountDTO: Codable, Sendable {
    public let viewCount: Int64
    public let totalSeconds: Int64
}

public struct TopVideoDTO: Codable, Sendable {
    public let videoId: String
    public let viewCount: Int64
    public let totalSeconds: Int64
}

// MARK: - Bootstrap

@main
struct WarblerAnalyticsWorkerApp {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("Usage: WarblerAnalyticsWorker <duckdb-path> <socket-path>")
            return
        }
        let duckdbPath = args[1]
        let socketPath = args[2]

        // Postgres configuration from environment
        let pgConfig = PostgresClient.Configuration(
            host: ProcessInfo.processInfo.environment["POSTGRES_HOST"] ?? "localhost",
            port: Int(ProcessInfo.processInfo.environment["POSTGRES_PORT"] ?? "5432") ?? 5432,
            username: ProcessInfo.processInfo.environment["POSTGRES_USER"] ?? "warbler",
            password: ProcessInfo.processInfo.environment["POSTGRES_PASSWORD"] ?? "warbler",
            database: ProcessInfo.processInfo.environment["POSTGRES_DB"] ?? "warbler",
            tls: .disable
        )
        let client = PostgresClient(configuration: pgConfig)
        let logger = Logger(label: "warbler.analytics")

        // Run migrations
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask {
                try await SongbirdPostgresMigrations.apply(client: client, logger: logger)
            }
            try await group.next()
            group.cancelAll()
        }

        let registry = EventTypeRegistry()
        registry.register(AnalyticsEvent.self, eventTypes: ["VideoViewed"])
        registry.register(ViewCountEvent.self, eventTypes: ["ViewCounted"])

        // Stores (Postgres-backed)
        let eventStore = PostgresEventStore(client: client, registry: registry)
        let positionStore = PostgresPositionStore(client: client)
        let snapshotStore = PostgresSnapshotStore(client: client)

        // Read model (per-worker DuckDB)
        let readModel = try ReadModelStore(path: duckdbPath)

        let playbackProjector = PlaybackAnalyticsProjector(readModel: readModel)
        await playbackProjector.registerMigration()
        try await readModel.migrate()

        let playbackInjector = PlaybackInjector()
        let pipeline = ProjectionPipeline()

        let _viewCountRepo = AggregateRepository<ViewCountAggregate>(
            store: eventStore,
            registry: registry,
            snapshotStore: snapshotStore,
            snapshotPolicy: .everyNEvents(100)
        )
        _ = _viewCountRepo  // Reserved for future view-count routes

        var mutableServices = SongbirdServices(
            eventStore: eventStore,
            projectionPipeline: pipeline,
            positionStore: positionStore,
            eventRegistry: registry
        )
        mutableServices.registerProjector(playbackProjector)
        mutableServices.registerInjector(playbackInjector)
        let services = mutableServices

        let system = SongbirdActorSystem(processName: "analytics-worker")
        try await system.startServer(socketPath: socketPath)

        let handler = AnalyticsCommandHandler(
            actorSystem: system,
            services: services,
            readModel: readModel,
            playbackInjector: playbackInjector
        )
        _ = handler

        print("Analytics worker (Postgres) started on \(socketPath)")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask { try await services.run() }
            try await group.waitForAll()
        }
    }
}
```

**Key difference from other workers:** Uses `PostgresSnapshotStore(client:)` instead of `SQLiteSnapshotStore(path:)`.

**Step 2: Commit**

```bash
git add demo/warbler-distributed-pg/Sources/WarblerAnalyticsWorker/main.swift
git commit -m "Add distributed-pg analytics worker with Postgres stores"
```

---

### Task 7: Distributed-PG Launch Script and README

**Files:**
- Create: `demo/warbler-distributed-pg/launch.sh`
- Create: `demo/warbler-distributed-pg/README.md`

**Step 1: Create the launch script**

Based on `demo/warbler-distributed/launch.sh` with these changes:
- Removes `SQLITE_PATH` — Postgres config from env vars
- Adds Postgres readiness check via `pg_isready`
- Workers take 2 CLI args (`duckdb-path`, `socket-path`) instead of 3

Create `demo/warbler-distributed-pg/launch.sh`:

```bash
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
swift build 2>/dev/null || true

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
```

Make it executable:

```bash
chmod +x demo/warbler-distributed-pg/launch.sh
```

**Step 2: Create the README**

Create `demo/warbler-distributed-pg/README.md`:

```markdown
# Warbler Distributed (Postgres)

Postgres-backed version of the distributed Warbler demo. Identical architecture to `warbler-distributed` — a Gateway process on `:8080` forwards HTTP requests to 4 domain workers via distributed actors — but uses PostgreSQL instead of SQLite for the event store, position store, and snapshot store.

## Prerequisites

A running PostgreSQL instance. Start one with Docker:

```bash
docker run -d --name warbler-postgres \
  -e POSTGRES_USER=warbler -e POSTGRES_PASSWORD=warbler \
  -e POSTGRES_DB=warbler -p 5432:5432 postgres:16
```

## Quick Start

```bash
./launch.sh
```

This checks Postgres is running, builds, and starts 5 processes (4 workers + gateway). Press Ctrl+C to stop.

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

Same API as the SQLite variant, all on `:8080`:

```bash
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
```

## Architecture

```
HTTP Client
    │
    ▼
┌──────────────────────┐
│  Gateway :8080       │  No event store — pure forwarding
│  (Hummingbird)       │
└──────┬───────────────┘
       │ Distributed Actors (Unix sockets)
       ├── Identity Worker     → PostgreSQL + identity.duckdb
       ├── Catalog Worker      → PostgreSQL + catalog.duckdb
       ├── Subscriptions Worker → PostgreSQL + subscriptions.duckdb
       └── Analytics Worker    → PostgreSQL + analytics.duckdb
```

All workers share the same PostgreSQL database for events, positions, and snapshots. Each worker has its own DuckDB read model.

## Differences from SQLite Variant

| Aspect | SQLite Variant | Postgres Variant |
|--------|---------------|-----------------|
| Event store | SQLiteEventStore (shared file) | PostgresEventStore (shared database) |
| Position store | SQLitePositionStore | PostgresPositionStore |
| Snapshot store | SQLiteSnapshotStore | PostgresSnapshotStore |
| Concurrency | `BEGIN IMMEDIATE` file lock | UNIQUE constraint + transactions |
| Position persistence | Survives restart | Survives restart |
| Prerequisites | None | Running Postgres instance |
| Worker CLI args | `<sqlite-path> <duckdb-path> <socket-path>` | `<duckdb-path> <socket-path>` |
```

**Step 3: Commit**

```bash
git add demo/warbler-distributed-pg/launch.sh demo/warbler-distributed-pg/README.md
git commit -m "Add distributed-pg launch script and README"
```

---

### Task 8: Scaffold warbler-p2p-pg Package

**Files:**
- Create: `demo/warbler-p2p-pg/Package.swift`

**Step 1: Create the Package.swift**

```bash
mkdir -p demo/warbler-p2p-pg/Sources/WarblerIdentityService
mkdir -p demo/warbler-p2p-pg/Sources/WarblerCatalogService
mkdir -p demo/warbler-p2p-pg/Sources/WarblerSubscriptionsService
mkdir -p demo/warbler-p2p-pg/Sources/WarblerAnalyticsService
```

Create `demo/warbler-p2p-pg/Package.swift`:

```swift
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WarblerP2PPG",
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
                .product(name: "SongbirdPostgres", package: "Songbird"),
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
                .product(name: "SongbirdPostgres", package: "Songbird"),
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
                .product(name: "SongbirdPostgres", package: "Songbird"),
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
                .product(name: "SongbirdPostgres", package: "Songbird"),
                .product(name: "SongbirdSmew", package: "Songbird"),
                .product(name: "SongbirdHummingbird", package: "Songbird"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
    ]
)
```

Note: The key change from `demo/warbler-p2p/Package.swift` is replacing `SongbirdSQLite` + `SongbirdTesting` with just `SongbirdPostgres` in all 4 targets.

**Step 2: Commit**

```bash
git add demo/warbler-p2p-pg/Package.swift
git commit -m "Scaffold warbler-p2p-pg package"
```

---

### Task 9: P2P Identity Service (Postgres)

**Files:**
- Create: `demo/warbler-p2p-pg/Sources/WarblerIdentityService/main.swift`

**Step 1: Create the Postgres variant of the identity service**

Based on `demo/warbler-p2p/Sources/WarblerIdentityService/main.swift` with these changes:
- Replace `import SongbirdSQLite` + `import SongbirdTesting` with `import SongbirdPostgres`, `import PostgresNIO`, `import Logging`
- Replace hardcoded `sqlitePath` with Postgres env var config
- Replace `SQLiteEventStore(path:registry:)` with `PostgresEventStore(client:registry:)`
- Replace `InMemoryPositionStore()` with `PostgresPositionStore(client:)`
- Add `PostgresClient` creation, migrations, and `client.run()` in task group

Create `demo/warbler-p2p-pg/Sources/WarblerIdentityService/main.swift`:

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
import WarblerIdentity

@main
struct WarblerIdentityService {
    static func main() async throws {
        // MARK: - Configuration

        let duckdbPath = "data/identity.duckdb"
        let port = 8081

        // Postgres configuration from environment
        let pgConfig = PostgresClient.Configuration(
            host: ProcessInfo.processInfo.environment["POSTGRES_HOST"] ?? "localhost",
            port: Int(ProcessInfo.processInfo.environment["POSTGRES_PORT"] ?? "5432") ?? 5432,
            username: ProcessInfo.processInfo.environment["POSTGRES_USER"] ?? "warbler",
            password: ProcessInfo.processInfo.environment["POSTGRES_PASSWORD"] ?? "warbler",
            database: ProcessInfo.processInfo.environment["POSTGRES_DB"] ?? "warbler",
            tls: .disable
        )
        let client = PostgresClient(configuration: pgConfig)
        let logger = Logger(label: "warbler.identity")

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
        registry.register(UserEvent.self, eventTypes: ["UserRegistered", "ProfileUpdated", "UserDeactivated"])

        // MARK: - Stores (Postgres-backed)

        let eventStore = PostgresEventStore(client: client, registry: registry)
        let positionStore = PostgresPositionStore(client: client)
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

        print("WarblerIdentityService (Postgres) starting on http://localhost:\(port)")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask { try await services.run() }
            group.addTask { try await app.runService() }
            try await group.waitForAll()
        }
    }
}
```

**Key differences from SQLite P2P variant:**
- No `import SongbirdSQLite`, `import SongbirdTesting`
- Adds `import SongbirdPostgres`, `import PostgresNIO`, `import Logging`
- Postgres client + migrations at startup
- `PostgresEventStore` and `PostgresPositionStore` instead of `SQLiteEventStore` and `InMemoryPositionStore`
- `client.run()` added to the final task group (3 tasks: client, services, app)

**Step 2: Commit**

```bash
git add demo/warbler-p2p-pg/Sources/WarblerIdentityService/main.swift
git commit -m "Add p2p-pg identity service with Postgres stores"
```

---

### Task 10: P2P Catalog Service (Postgres)

**Files:**
- Create: `demo/warbler-p2p-pg/Sources/WarblerCatalogService/main.swift`

**Step 1: Create the Postgres variant of the catalog service**

Same transformation as identity service, plus preserves the `VideoPublishedV1` upcast.

Create `demo/warbler-p2p-pg/Sources/WarblerCatalogService/main.swift`:

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
import WarblerCatalog

@main
struct WarblerCatalogService {
    static func main() async throws {
        // MARK: - Configuration

        let duckdbPath = "data/catalog.duckdb"
        let port = 8082

        // Postgres configuration from environment
        let pgConfig = PostgresClient.Configuration(
            host: ProcessInfo.processInfo.environment["POSTGRES_HOST"] ?? "localhost",
            port: Int(ProcessInfo.processInfo.environment["POSTGRES_PORT"] ?? "5432") ?? 5432,
            username: ProcessInfo.processInfo.environment["POSTGRES_USER"] ?? "warbler",
            password: ProcessInfo.processInfo.environment["POSTGRES_PASSWORD"] ?? "warbler",
            database: ProcessInfo.processInfo.environment["POSTGRES_DB"] ?? "warbler",
            tls: .disable
        )
        let client = PostgresClient(configuration: pgConfig)
        let logger = Logger(label: "warbler.catalog")

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
        registry.register(VideoEvent.self, eventTypes: ["VideoPublished", "VideoMetadataUpdated", "TranscodingCompleted", "VideoUnpublished"])
        registry.registerUpcast(
            from: VideoPublishedV1.self,
            to: VideoEvent.self,
            upcast: VideoPublishedUpcast(),
            oldEventType: "VideoPublished_v1"
        )

        // MARK: - Stores (Postgres-backed)

        let eventStore = PostgresEventStore(client: client, registry: registry)
        let positionStore = PostgresPositionStore(client: client)
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

        print("WarblerCatalogService (Postgres) starting on http://localhost:\(port)")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask { try await services.run() }
            group.addTask { try await app.runService() }
            try await group.waitForAll()
        }
    }
}
```

**Step 2: Commit**

```bash
git add demo/warbler-p2p-pg/Sources/WarblerCatalogService/main.swift
git commit -m "Add p2p-pg catalog service with Postgres stores"
```

---

### Task 11: P2P Subscriptions Service (Postgres)

**Files:**
- Create: `demo/warbler-p2p-pg/Sources/WarblerSubscriptionsService/main.swift`

**Step 1: Create the Postgres variant of the subscriptions service**

Create `demo/warbler-p2p-pg/Sources/WarblerSubscriptionsService/main.swift`:

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
import WarblerSubscriptions

@main
struct WarblerSubscriptionsService {
    static func main() async throws {
        // MARK: - Configuration

        let duckdbPath = "data/subscriptions.duckdb"
        let port = 8083

        // Postgres configuration from environment
        let pgConfig = PostgresClient.Configuration(
            host: ProcessInfo.processInfo.environment["POSTGRES_HOST"] ?? "localhost",
            port: Int(ProcessInfo.processInfo.environment["POSTGRES_PORT"] ?? "5432") ?? 5432,
            username: ProcessInfo.processInfo.environment["POSTGRES_USER"] ?? "warbler",
            password: ProcessInfo.processInfo.environment["POSTGRES_PASSWORD"] ?? "warbler",
            database: ProcessInfo.processInfo.environment["POSTGRES_DB"] ?? "warbler",
            tls: .disable
        )
        let client = PostgresClient(configuration: pgConfig)
        let logger = Logger(label: "warbler.subscriptions")

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
        registry.register(SubscriptionEvent.self, eventTypes: ["SubscriptionRequested", "PaymentConfirmed", "PaymentFailed"])
        registry.register(SubscriptionLifecycleEvent.self, eventTypes: ["AccessGranted", "SubscriptionCancelled"])

        // MARK: - Stores (Postgres-backed)

        let eventStore = PostgresEventStore(client: client, registry: registry)
        let positionStore = PostgresPositionStore(client: client)
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

        print("WarblerSubscriptionsService (Postgres) starting on http://localhost:\(port)")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask { try await services.run() }
            group.addTask { try await app.runService() }
            try await group.waitForAll()
        }
    }
}
```

**Step 2: Commit**

```bash
git add demo/warbler-p2p-pg/Sources/WarblerSubscriptionsService/main.swift
git commit -m "Add p2p-pg subscriptions service with Postgres stores"
```

---

### Task 12: P2P Analytics Service (Postgres)

**Files:**
- Create: `demo/warbler-p2p-pg/Sources/WarblerAnalyticsService/main.swift`

**Step 1: Create the Postgres variant of the analytics service**

Replaces `InMemorySnapshotStore()` with `PostgresSnapshotStore(client:)`.

Create `demo/warbler-p2p-pg/Sources/WarblerAnalyticsService/main.swift`:

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

@main
struct WarblerAnalyticsService {
    static func main() async throws {
        // MARK: - Configuration

        let duckdbPath = "data/analytics.duckdb"
        let port = 8084

        // Postgres configuration from environment
        let pgConfig = PostgresClient.Configuration(
            host: ProcessInfo.processInfo.environment["POSTGRES_HOST"] ?? "localhost",
            port: Int(ProcessInfo.processInfo.environment["POSTGRES_PORT"] ?? "5432") ?? 5432,
            username: ProcessInfo.processInfo.environment["POSTGRES_USER"] ?? "warbler",
            password: ProcessInfo.processInfo.environment["POSTGRES_PASSWORD"] ?? "warbler",
            database: ProcessInfo.processInfo.environment["POSTGRES_DB"] ?? "warbler",
            tls: .disable
        )
        let client = PostgresClient(configuration: pgConfig)
        let logger = Logger(label: "warbler.analytics")

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
        registry.register(AnalyticsEvent.self, eventTypes: ["VideoViewed"])
        registry.register(ViewCountEvent.self, eventTypes: ["ViewCounted"])

        // MARK: - Stores (Postgres-backed)

        let eventStore = PostgresEventStore(client: client, registry: registry)
        let positionStore = PostgresPositionStore(client: client)
        let snapshotStore = PostgresSnapshotStore(client: client)
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

        print("WarblerAnalyticsService (Postgres) starting on http://localhost:\(port)")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask { try await services.run() }
            group.addTask { try await app.runService() }
            try await group.waitForAll()
        }
    }
}
```

**Step 2: Commit**

```bash
git add demo/warbler-p2p-pg/Sources/WarblerAnalyticsService/main.swift
git commit -m "Add p2p-pg analytics service with Postgres stores"
```

---

### Task 13: P2P-PG Launch Script and README

**Files:**
- Create: `demo/warbler-p2p-pg/launch.sh`
- Create: `demo/warbler-p2p-pg/README.md`

**Step 1: Create the launch script**

Based on `demo/warbler-p2p/launch.sh` with Postgres readiness check added.

Create `demo/warbler-p2p-pg/launch.sh`:

```bash
#!/bin/bash
set -e

# Warbler P2P (Postgres) — Launch all 4 domain services
# Each service writes to a shared PostgreSQL event store and its own DuckDB read model.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Check Postgres is running
pg_isready -h "${POSTGRES_HOST:-localhost}" -p "${POSTGRES_PORT:-5432}" -U "${POSTGRES_USER:-warbler}" || {
    echo "Postgres is not running. Start it with:"
    echo "  docker run -d --name warbler-postgres \\"
    echo "    -e POSTGRES_USER=warbler -e POSTGRES_PASSWORD=warbler \\"
    echo "    -e POSTGRES_DB=warbler -p 5432:5432 postgres:16"
    exit 1
}

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
echo "Warbler P2P (Postgres) is running:"
echo "  Identity      → http://localhost:8081"
echo "  Catalog       → http://localhost:8082"
echo "  Subscriptions → http://localhost:8083"
echo "  Analytics     → http://localhost:8084"
echo ""
echo "Press Ctrl+C to stop all services."

# Wait for any process to exit
wait
```

Make it executable:

```bash
chmod +x demo/warbler-p2p-pg/launch.sh
```

**Step 2: Create the README**

Create `demo/warbler-p2p-pg/README.md`:

```markdown
# Warbler P2P (Postgres)

Postgres-backed version of the P2P Warbler demo. Identical architecture to `warbler-p2p` — 4 independent Hummingbird services on dedicated ports, communicating through a shared event store — but uses PostgreSQL instead of SQLite.

## Prerequisites

A running PostgreSQL instance. Start one with Docker:

```bash
docker run -d --name warbler-postgres \
  -e POSTGRES_USER=warbler -e POSTGRES_PASSWORD=warbler \
  -e POSTGRES_DB=warbler -p 5432:5432 postgres:16
```

## Quick Start

```bash
./launch.sh
```

This checks Postgres is running, builds, and starts all 4 services. Press Ctrl+C to stop.

## Configuration

Postgres connection is configured via environment variables:

| Variable | Default |
|----------|---------|
| `POSTGRES_HOST` | `localhost` |
| `POSTGRES_PORT` | `5432` |
| `POSTGRES_USER` | `warbler` |
| `POSTGRES_PASSWORD` | `warbler` |
| `POSTGRES_DB` | `warbler` |

## Services

| Port | Service | Domain |
|------|---------|--------|
| 8081 | WarblerIdentityService | Users |
| 8082 | WarblerCatalogService | Videos |
| 8083 | WarblerSubscriptionsService | Subscriptions |
| 8084 | WarblerAnalyticsService | Analytics |

## API Examples

Same API as the SQLite P2P variant:

```bash
# Create a user
curl -X POST http://localhost:8081/users/alice \
  -H "Content-Type: application/json" \
  -d '{"email": "alice@example.com", "displayName": "Alice"}'

# Publish a video
curl -X POST http://localhost:8082/videos/vid-1 \
  -H "Content-Type: application/json" \
  -d '{"title": "Swift Concurrency", "description": "A deep dive", "creatorId": "alice"}'

# Record a view
curl -X POST http://localhost:8084/analytics/views \
  -H "Content-Type: application/json" \
  -d '{"videoId": "vid-1", "userId": "alice", "watchedSeconds": 120}'
```

## Architecture

```
HTTP Clients
    |
    +-- :8081 --> Identity (users)
    +-- :8082 --> Catalog (videos)
    +-- :8083 --> Subscriptions (plans, payments)
    +-- :8084 --> Analytics (views, metrics)
                      |
                      v
            +-------------------+
            | PostgreSQL        |  <-- Shared event store
            | (all 4 write)     |
            +-------------------+
```

Each service has its own DuckDB read model (`data/*.duckdb`). Cross-domain coordination happens through event subscriptions polling the shared Postgres event store.

## Differences from SQLite P2P Variant

| Aspect | SQLite P2P | Postgres P2P |
|--------|-----------|-------------|
| Event store | SQLiteEventStore (shared file) | PostgresEventStore (shared database) |
| Position store | InMemoryPositionStore | PostgresPositionStore |
| Snapshot store | InMemorySnapshotStore | PostgresSnapshotStore |
| Concurrency | `BEGIN IMMEDIATE` file lock | UNIQUE constraint + transactions |
| Position persistence | Lost on restart | Survives restart |
| Dependencies | SongbirdSQLite, SongbirdTesting | SongbirdPostgres |
| Prerequisites | None | Running Postgres instance |
```

**Step 3: Commit**

```bash
git add demo/warbler-p2p-pg/launch.sh demo/warbler-p2p-pg/README.md
git commit -m "Add p2p-pg launch script and README"
```

---

### Task 14: warbler-p2p-proxy-pg (Launch Script + README Only)

**Files:**
- Create: `demo/warbler-p2p-proxy-pg/launch.sh`
- Create: `demo/warbler-p2p-proxy-pg/README.md`

No new Swift code — the proxy is pure HTTP forwarding and has no event store dependency. This variant just starts the Postgres P2P services from `warbler-p2p-pg` and the proxy from `warbler-p2p-proxy`.

**Step 1: Create directory**

```bash
mkdir -p demo/warbler-p2p-proxy-pg
```

**Step 2: Create the launch script**

Create `demo/warbler-p2p-proxy-pg/launch.sh`:

```bash
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
sleep 2

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
```

Make it executable:

```bash
chmod +x demo/warbler-p2p-proxy-pg/launch.sh
```

**Step 3: Create the README**

Create `demo/warbler-p2p-proxy-pg/README.md`:

```markdown
# Warbler P2P + Proxy (Postgres)

Postgres-backed version of the P2P + Proxy Warbler demo. A reverse proxy on `:8080` forwards requests to 4 Postgres-backed P2P services, providing a unified API identical to the monolith.

This variant contains no Swift code — it launches the Postgres P2P services from `warbler-p2p-pg` and the proxy from `warbler-p2p-proxy`.

## Prerequisites

A running PostgreSQL instance. Start one with Docker:

```bash
docker run -d --name warbler-postgres \
  -e POSTGRES_USER=warbler -e POSTGRES_PASSWORD=warbler \
  -e POSTGRES_DB=warbler -p 5432:5432 postgres:16
```

## Quick Start

```bash
./launch.sh
```

This checks Postgres is running, builds both packages, and starts 5 processes (4 services + proxy). Press Ctrl+C to stop.

## API Examples

All requests go through the proxy on `:8080`:

```bash
# Create a user
curl -X POST http://localhost:8080/users/alice \
  -H "Content-Type: application/json" \
  -d '{"email": "alice@example.com", "displayName": "Alice"}'

# Publish a video
curl -X POST http://localhost:8080/videos/vid-1 \
  -H "Content-Type: application/json" \
  -d '{"title": "Swift Concurrency", "description": "A deep dive", "creatorId": "alice"}'

# Health check
curl http://localhost:8080/health
```

## Architecture

```
HTTP Client
    │
    ▼
┌──────────────────────┐
│  WarblerProxy :8080  │  Pure HTTP forwarding (no event store)
│  (from warbler-p2p-  │
│   proxy package)     │
└──────┬───────────────┘
       │ HTTP
       ├── /users/*          → :8081 (Identity)
       ├── /videos/*         → :8082 (Catalog)
       ├── /subscriptions/*  → :8083 (Subscriptions)
       └── /analytics/*      → :8084 (Analytics)
                                  │
                                  ▼
                          ┌──────────────┐
                          │  PostgreSQL   │
                          │  (shared)     │
                          └──────────────┘
```

## Comparison

| Aspect | P2P (SQLite) | P2P + Proxy (Postgres) |
|--------|-------------|----------------------|
| Entry point | 4 ports | Single port (:8080) |
| Event store | Shared SQLite file | Shared Postgres database |
| Position persistence | Lost on restart | Survives restart |
| Proxy intelligence | N/A | Pure HTTP forwarding |
| Prerequisites | None | Running Postgres instance |
```

**Step 4: Commit**

```bash
git add demo/warbler-p2p-proxy-pg/launch.sh demo/warbler-p2p-proxy-pg/README.md
git commit -m "Add p2p-proxy-pg launch script and README"
```

---

### Task 15: Build Verification

**Step 1: Verify warbler-distributed-pg builds**

Run from the demo directory:

```bash
cd demo/warbler-distributed-pg && swift build
```

Expected: Clean build with no warnings or errors.

**Step 2: Verify warbler-p2p-pg builds**

```bash
cd demo/warbler-p2p-pg && swift build
```

Expected: Clean build with no warnings or errors.

**Step 3: Fix any compilation issues**

If there are compilation errors, fix them in the appropriate files and re-run `swift build` until both packages compile cleanly.

**Step 4: Commit any fixes**

```bash
git add -A && git commit -m "Fix compilation issues in Postgres demo variants"
```

(Only if fixes were needed.)

---

### Task 16: Changelog Entry

**Files:**
- Create: `changelog/0021-warbler-postgres-variants.md`

**Step 1: Write the changelog entry**

Create `changelog/0021-warbler-postgres-variants.md`:

```markdown
# Warbler Postgres Variants

Added Postgres-backed versions of all three multi-process Warbler demos:

## warbler-distributed-pg

Gateway + 4 workers using PostgresEventStore, PostgresPositionStore, and PostgresSnapshotStore instead of SQLite equivalents. Gateway is unchanged (no event store). Workers take 2 CLI args (duckdb-path, socket-path) instead of 3 — Postgres config comes from environment variables.

## warbler-p2p-pg

4 independent Hummingbird services using Postgres stores instead of SQLite + in-memory stores. Positions and snapshots now survive restarts (PostgresPositionStore/PostgresSnapshotStore replace InMemoryPositionStore/InMemorySnapshotStore).

## warbler-p2p-proxy-pg

Launch script + README only — starts 4 Postgres P2P services from warbler-p2p-pg plus the proxy from warbler-p2p-proxy. No new Swift code.

## Key Changes

- **Dependency swap**: SongbirdSQLite (+ SongbirdTesting) → SongbirdPostgres
- **Store initialization**: PostgresClient with env var config, SongbirdPostgresMigrations at startup, client.run() in task group
- **Launch scripts**: Postgres readiness check via pg_isready, Docker instructions on failure
- **Domain code**: Zero changes — only store initialization differs
```

**Step 2: Commit**

```bash
git add changelog/0021-warbler-postgres-variants.md
git commit -m "Add Warbler Postgres variants changelog entry"
```
