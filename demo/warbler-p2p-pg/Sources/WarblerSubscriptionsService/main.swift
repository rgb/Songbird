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

        let duckdbPath = ProcessInfo.processInfo.environment["DUCKDB_PATH"] ?? "data/subscriptions.duckdb"
        let port = Int(ProcessInfo.processInfo.environment["PORT"] ?? "8083") ?? 8083
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
        let logger = Logger(label: "warbler.subscriptions")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask {
                // Run migrations first
                try await SongbirdPostgresMigrations.apply(client: client, logger: logger)

                // MARK: - Event Type Registry

                let registry = EventTypeRegistry()
                registry.register(SubscriptionEvent.self, eventTypes: [SubscriptionEventTypes.subscriptionRequested, SubscriptionEventTypes.paymentConfirmed, SubscriptionEventTypes.paymentFailed])
                registry.register(SubscriptionLifecycleEvent.self, eventTypes: [LifecycleEventTypes.accessGranted, LifecycleEventTypes.subscriptionCancelled])

                // MARK: - Stores (Postgres-backed)

                let eventStore = PostgresEventStore(client: client)
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
                    configuration: .init(address: .hostname(bindHost, port: port))
                )

                logger.info("WarblerSubscriptionsService (Postgres) starting on http://\(bindHost):\(port)")

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
