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
        // MARK: - Configuration

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

        let eventStore = PostgresEventStore(client: client)
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
