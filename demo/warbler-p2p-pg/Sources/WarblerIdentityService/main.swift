import Foundation
import Hummingbird
import Logging
import NIOCore
import PostgresNIO
import Songbird
import SongbirdHummingbird
import SongbirdPostgres
import SongbirdSmew
import WarblerIdentity

@main
struct WarblerIdentityService {
    static func main() async throws {
        // MARK: - Configuration

        let duckdbPath = ProcessInfo.processInfo.environment["DUCKDB_PATH"] ?? "data/identity.duckdb"
        let port = Int(ProcessInfo.processInfo.environment["PORT"] ?? "8081") ?? 8081
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
        let logger = Logger(label: "warbler.identity")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask {
                // Run migrations first
                try await SongbirdPostgresMigrations.apply(client: client, logger: logger)

                // MARK: - Event Type Registry

                let registry = EventTypeRegistry()
                registry.register(UserEvent.self, eventTypes: [IdentityEventTypes.userRegistered, IdentityEventTypes.userProfileUpdated, IdentityEventTypes.userDeactivated])

                // MARK: - Stores (Postgres-backed)

                let eventStore = PostgresEventStore(client: client)
                let positionStore = PostgresPositionStore(client: client)
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
                    configuration: .init(address: .hostname(bindHost, port: port))
                )

                print("WarblerIdentityService (Postgres) starting on http://\(bindHost):\(port)")

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
