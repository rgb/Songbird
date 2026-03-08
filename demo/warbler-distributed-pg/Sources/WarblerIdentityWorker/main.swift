import Distributed
import Foundation
import Logging
import PostgresNIO
import Songbird
import SongbirdDistributed
import SongbirdHummingbird
import SongbirdPostgres
import SongbirdSmew
import WarblerIdentity

// MARK: - Distributed Command Handler

distributed actor IdentityCommandHandler {
    typealias ActorSystem = SongbirdActorSystem

    let services: SongbirdServices
    let repository: AggregateRepository<UserAggregate>
    let readModel: ReadModelStore

    init(
        actorSystem: SongbirdActorSystem,
        services: SongbirdServices,
        repository: AggregateRepository<UserAggregate>,
        readModel: ReadModelStore
    ) {
        self.actorSystem = actorSystem
        self.services = services
        self.repository = repository
        self.readModel = readModel
    }

    // MARK: - Commands

    distributed func registerUser(id: String, email: String, displayName: String) async throws {
        try await executeAndProject(
            RegisterUser(email: email, displayName: displayName),
            on: id,
            metadata: EventMetadata(),
            using: RegisterUserHandler.self,
            repository: repository,
            services: services
        )
    }

    distributed func updateProfile(userId: String, displayName: String) async throws {
        try await executeAndProject(
            UpdateProfile(displayName: displayName),
            on: userId,
            metadata: EventMetadata(),
            using: UpdateProfileHandler.self,
            repository: repository,
            services: services
        )
    }

    distributed func deactivateUser(userId: String) async throws {
        try await executeAndProject(
            DeactivateUser(),
            on: userId,
            metadata: EventMetadata(),
            using: DeactivateUserHandler.self,
            repository: repository,
            services: services
        )
    }

    // MARK: - Queries

    distributed func getUser(id: String) async throws -> UserDTO? {
        try await readModel.queryFirst(UserDTO.self) {
            "SELECT id, email, display_name, is_active FROM users WHERE id = \(param: id)"
        }
    }
}

/// DTO for the user query result (must be Codable for distributed transport).
public struct UserDTO: Codable, Sendable {
    public let id: String
    public let email: String
    public let displayName: String
    public let isActive: Bool
}

// MARK: - Bootstrap

@main
struct WarblerIdentityWorkerApp {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("Usage: WarblerIdentityWorker <duckdb-path> <socket-path>")
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
        let logger = Logger(label: "warbler.identity")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask {
                // Run migrations first
                try await SongbirdPostgresMigrations.apply(client: client, logger: logger)

                // Event type registry
                let registry = EventTypeRegistry()
                registry.register(UserEvent.self, eventTypes: [IdentityEventTypes.userRegistered, IdentityEventTypes.userProfileUpdated, IdentityEventTypes.userDeactivated])

                // Stores (Postgres-backed)
                let eventStore = PostgresEventStore(client: client)
                let positionStore = PostgresPositionStore(client: client)

                // Read model (per-worker DuckDB)
                let readModel = try ReadModelStore(path: duckdbPath)

                // Projector
                let userProjector = UserProjector(readModel: readModel)
                await userProjector.registerMigration()
                try await readModel.migrate()

                // Projection pipeline
                let pipeline = ProjectionPipeline()

                // Services
                var mutableServices = SongbirdServices(
                    eventStore: eventStore,
                    projectionPipeline: pipeline,
                    positionStore: positionStore,
                    eventRegistry: registry
                )
                mutableServices.registerProjector(userProjector)
                let services = mutableServices

                // Aggregate repository
                let repository = AggregateRepository<UserAggregate>(
                    store: eventStore, registry: registry
                )

                // Distributed actor system
                let system = SongbirdActorSystem(processName: "identity-worker")
                try await system.startServer(socketPath: socketPath)

                // Create and register the command handler
                let handler = IdentityCommandHandler(
                    actorSystem: system,
                    services: services,
                    repository: repository,
                    readModel: readModel
                )

                logger.info("Identity worker (Postgres) started on \(socketPath)")

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
