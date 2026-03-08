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

        let duckdbPath = ProcessInfo.processInfo.environment["DUCKDB_PATH"] ?? "data/analytics.duckdb"
        let port = Int(ProcessInfo.processInfo.environment["PORT"] ?? "8084") ?? 8084
        let bindHost = ProcessInfo.processInfo.environment["BIND_HOST"] ?? "localhost"

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

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask {
                // Run migrations first
                try await SongbirdPostgresMigrations.apply(client: client, logger: logger)

                // MARK: - Event Type Registry

                let registry = EventTypeRegistry()
                registry.register(AnalyticsEvent.self, eventTypes: [AnalyticsEventTypes.videoViewed])

                // MARK: - Stores (Postgres-backed)

                let eventStore = PostgresEventStore(client: client)
                let positionStore = PostgresPositionStore(client: client)
                let readModel = try ReadModelStore(path: duckdbPath)

                // MARK: - Projectors

                let playbackProjector = PlaybackAnalyticsProjector(readModel: readModel)
                await playbackProjector.registerMigration()
                try await readModel.migrate()

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
                    playbackInjector.inject(inbound)
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
                    configuration: .init(address: .hostname(bindHost, port: port))
                )

                logger.info("WarblerAnalyticsService (Postgres) starting on http://\(bindHost):\(port)")

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
