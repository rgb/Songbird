import Foundation
import Hummingbird
import NIOCore
import Songbird
import SongbirdHummingbird
import SongbirdSQLite
import SongbirdSmew
import SongbirdTesting
import WarblerSubscriptions

@main
struct WarblerSubscriptionsService {
    static func main() async throws {
        // MARK: - Configuration

        let sqlitePath = "data/songbird.sqlite"
        let duckdbPath = "data/subscriptions.duckdb"
        let port = 8083

        // MARK: - Event Type Registry

        let registry = EventTypeRegistry()
        registry.register(SubscriptionEvent.self, eventTypes: ["SubscriptionRequested", "PaymentConfirmed", "PaymentFailed"])
        registry.register(SubscriptionLifecycleEvent.self, eventTypes: ["AccessGranted", "SubscriptionCancelled"])

        // MARK: - Stores

        let eventStore = try SQLiteEventStore(path: sqlitePath, registry: registry)
        let positionStore = InMemoryPositionStore()
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

        print("WarblerSubscriptionsService starting on http://localhost:\(port)")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await services.run() }
            group.addTask { try await app.runService() }
            try await group.waitForAll()
        }
    }
}
