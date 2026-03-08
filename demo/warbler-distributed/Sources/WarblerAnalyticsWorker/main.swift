import Distributed
import Foundation
import Logging
import Songbird
import SongbirdDistributed
import SongbirdHummingbird
import SongbirdSQLite
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
        guard args.count >= 4 else {
            print("Usage: WarblerAnalyticsWorker <sqlite-path> <duckdb-path> <socket-path>")
            Darwin.exit(1)
        }
        let sqlitePath = args[1]
        let duckdbPath = args[2]
        let socketPath = args[3]
        let logger = Logger(label: "warbler.analytics")

        let registry = EventTypeRegistry()
        registry.register(AnalyticsEvent.self, eventTypes: [AnalyticsEventTypes.videoViewed])

        let eventStore = try SQLiteEventStore(path: sqlitePath)
        let readModel = try ReadModelStore(path: duckdbPath)
        let positionStore = try SQLitePositionStore(path: sqlitePath)

        let playbackProjector = PlaybackAnalyticsProjector(readModel: readModel)
        await playbackProjector.registerMigration()
        try await readModel.migrate()

        let playbackInjector = PlaybackInjector()
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

        let system = SongbirdActorSystem(processName: "analytics-worker")
        try await system.startServer(socketPath: socketPath)

        let handler = AnalyticsCommandHandler(
            actorSystem: system,
            services: services,
            readModel: readModel,
            playbackInjector: playbackInjector
        )

        logger.info("Analytics worker started on \(socketPath)")

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
}
