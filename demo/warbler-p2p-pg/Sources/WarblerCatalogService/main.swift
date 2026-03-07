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

        let eventStore = PostgresEventStore(client: client)
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
