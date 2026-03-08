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
            Darwin.exit(1)
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

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask {
                // Run migrations first
                try await SongbirdPostgresMigrations.apply(client: client, logger: logger)

                // Event type registry (with versioning upcast)
                let registry = EventTypeRegistry()
                registry.register(VideoEvent.self, eventTypes: [CatalogEventTypes.videoPublished, CatalogEventTypes.videoMetadataUpdated, CatalogEventTypes.videoTranscodingCompleted, CatalogEventTypes.videoUnpublished])
                registry.registerUpcast(
                    from: VideoPublishedV1.self,
                    to: VideoEvent.self,
                    upcast: VideoPublishedUpcast(),
                    oldEventType: CatalogEventTypes.videoPublishedV1
                )

                // Stores (Postgres-backed)
                let eventStore = PostgresEventStore(client: client)
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

                logger.info("Catalog worker (Postgres) started on \(socketPath)")

                // Run services (blocks until cancelled)
                do {
                    try await services.run()
                } catch {
                    _ = handler  // ensure handler stays alive through services.run()
                    try? await system.shutdown()
                    throw error
                }
                _ = handler  // ensure handler stays alive through services.run()
                try await system.shutdown()
            }
            try await group.next()
            group.cancelAll()
        }
    }
}
