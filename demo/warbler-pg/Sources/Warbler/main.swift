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

// NOTE: This helper is duplicated in warbler. If extracting to a shared module,
// move to a SongbirdHummingbird convenience extension.
private func jsonResponse(_ value: some Encodable, status: HTTPResponse.Status = .ok) throws -> Response {
    let data = try JSONEncoder().encode(value)
    return Response(
        status: status,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(data: data))
    )
}

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
        let port = Int(ProcessInfo.processInfo.environment["PORT"] ?? "8080") ?? 8080
        let client = PostgresClient(configuration: pgConfig)
        let logger = Logger(label: "warbler")

        // MARK: - Event Type Registry

        let registry = EventTypeRegistry()

        // Identity events
        registry.register(UserEvent.self, eventTypes: [IdentityEventTypes.userRegistered, IdentityEventTypes.userProfileUpdated, IdentityEventTypes.userDeactivated])

        // Catalog events (current version)
        registry.register(VideoEvent.self, eventTypes: [CatalogEventTypes.videoPublished, CatalogEventTypes.videoMetadataUpdated, CatalogEventTypes.videoTranscodingCompleted, CatalogEventTypes.videoUnpublished])

        // Catalog event versioning: v1 → v2 upcast
        registry.registerUpcast(
            from: VideoPublishedV1.self,
            to: VideoEvent.self,
            upcast: VideoPublishedUpcast(),
            oldEventType: CatalogEventTypes.videoPublishedV1
        )

        // Subscription events
        registry.register(SubscriptionEvent.self, eventTypes: [SubscriptionEventTypes.subscriptionRequested, SubscriptionEventTypes.paymentConfirmed, SubscriptionEventTypes.paymentFailed])
        registry.register(SubscriptionLifecycleEvent.self, eventTypes: [LifecycleEventTypes.accessGranted, LifecycleEventTypes.subscriptionCancelled])

        // Analytics events
        registry.register(AnalyticsEvent.self, eventTypes: [AnalyticsEventTypes.videoViewed])
        registry.register(ViewCountEvent.self, eventTypes: [ViewCountEventTypes.viewCounted])

        // MARK: - Stores (Postgres-backed)

        let eventStore = PostgresEventStore(client: client)
        let positionStore = PostgresPositionStore(client: client)

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
            return try jsonResponse(user)
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
            return try jsonResponse(videos)
        }

        router.get("/videos/{id}") { _, context -> Response in
            let id = try context.parameters.require("id")
            struct VideoRow: Codable { let id: String; let title: String; let description: String; let creatorId: String; let status: String }
            let video: VideoRow? = try await readModel.queryFirst(VideoRow.self) {
                "SELECT id, title, description, creator_id, status FROM videos WHERE id = \(param: id)"
            }
            guard let video else { return Response(status: .notFound) }
            return try jsonResponse(video)
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
            return try jsonResponse(subs)
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
            return try jsonResponse(result)
        }

        router.get("/analytics/top-videos") { _, _ -> Response in
            struct TopVideo: Codable { let videoId: String; let viewCount: Int64; let totalSeconds: Int64 }
            let top: [TopVideo] = try await readModel.query(TopVideo.self) {
                "SELECT video_id, COUNT(*) AS view_count, SUM(watched_seconds) AS total_seconds FROM video_views GROUP BY video_id ORDER BY view_count DESC LIMIT 10"
            }
            return try jsonResponse(top)
        }

        // MARK: - Start

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("localhost", port: port))
        )

        logger.info("Warbler (Postgres) starting on http://localhost:\(port)")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask {
                try await SongbirdPostgresMigrations.apply(client: client, logger: logger)
                try await withThrowingTaskGroup(of: Void.self) { serviceGroup in
                    serviceGroup.addTask { try await services.run() }
                    serviceGroup.addTask { try await app.runService() }
                    try await serviceGroup.waitForAll()
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }
}
