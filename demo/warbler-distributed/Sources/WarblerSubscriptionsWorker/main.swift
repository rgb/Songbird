import Distributed
import Foundation
import Logging
import Songbird
import SongbirdDistributed
import SongbirdHummingbird
import SongbirdSQLite
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
        guard args.count >= 4 else {
            print("Usage: WarblerSubscriptionsWorker <sqlite-path> <duckdb-path> <socket-path>")
            Darwin.exit(1)
        }
        let sqlitePath = args[1]
        let duckdbPath = args[2]
        let socketPath = args[3]
        let logger = Logger(label: "warbler.subscriptions")

        let registry = EventTypeRegistry()
        registry.register(SubscriptionEvent.self, eventTypes: [SubscriptionEventTypes.subscriptionRequested, SubscriptionEventTypes.paymentConfirmed, SubscriptionEventTypes.paymentFailed])
        registry.register(SubscriptionLifecycleEvent.self, eventTypes: [LifecycleEventTypes.accessGranted, LifecycleEventTypes.subscriptionCancelled])

        let eventStore = try SQLiteEventStore(path: sqlitePath)
        let readModel = try ReadModelStore(path: duckdbPath)
        let positionStore = try SQLitePositionStore(path: sqlitePath)

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

        logger.info("Subscriptions worker started on \(socketPath)")

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
