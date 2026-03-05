import Distributed
import Foundation
import Songbird
import SongbirdDistributed
import SongbirdHummingbird
import SongbirdSQLite
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
        guard args.count >= 4 else {
            print("Usage: WarblerCatalogWorker <sqlite-path> <duckdb-path> <socket-path>")
            return
        }
        let sqlitePath = args[1]
        let duckdbPath = args[2]
        let socketPath = args[3]

        // Event type registry (with versioning upcast)
        let registry = EventTypeRegistry()
        registry.register(VideoEvent.self, eventTypes: ["VideoPublished", "VideoMetadataUpdated", "TranscodingCompleted", "VideoUnpublished"])
        registry.registerUpcast(
            from: VideoPublishedV1.self,
            to: VideoEvent.self,
            upcast: VideoPublishedUpcast(),
            oldEventType: "VideoPublished_v1"
        )

        let eventStore = try SQLiteEventStore(path: sqlitePath, registry: registry)
        let readModel = try ReadModelStore(path: duckdbPath)
        let positionStore = try SQLitePositionStore(path: sqlitePath)

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

        print("Catalog worker started on \(socketPath)")
        try await services.run()
    }
}
