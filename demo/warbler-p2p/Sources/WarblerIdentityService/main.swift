import Foundation
import Hummingbird
import NIOCore
import Songbird
import SongbirdHummingbird
import SongbirdSQLite
import SongbirdSmew
import SongbirdTesting
import WarblerIdentity

@main
struct WarblerIdentityService {
    static func main() async throws {
        // MARK: - Configuration

        let sqlitePath = "data/songbird.sqlite"
        let duckdbPath = "data/identity.duckdb"
        let port = 8081

        // MARK: - Event Type Registry

        let registry = EventTypeRegistry()
        registry.register(UserEvent.self, eventTypes: ["UserRegistered", "ProfileUpdated", "UserDeactivated"])

        // MARK: - Stores

        let eventStore = try SQLiteEventStore(path: sqlitePath)
        let positionStore = InMemoryPositionStore()
        let readModel = try ReadModelStore(path: duckdbPath)

        // MARK: - Projectors

        let userProjector = UserProjector(readModel: readModel)
        await userProjector.registerMigration()
        try await readModel.migrate()

        // MARK: - Repositories

        let userRepo = AggregateRepository<UserAggregate>(store: eventStore, registry: registry)

        // MARK: - Services

        let pipeline = ProjectionPipeline()
        var mutableServices = SongbirdServices(
            eventStore: eventStore,
            projectionPipeline: pipeline,
            positionStore: positionStore,
            eventRegistry: registry
        )
        mutableServices.registerProjector(userProjector)
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

        // MARK: - Start

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("localhost", port: port))
        )

        print("WarblerIdentityService starting on http://localhost:\(port)")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await services.run() }
            group.addTask { try await app.runService() }
            try await group.waitForAll()
        }
    }
}
