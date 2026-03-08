import Distributed
import Foundation
import Songbird
import SongbirdDistributed
import SongbirdHummingbird
import SongbirdSQLite
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
        guard args.count >= 4 else {
            print("Usage: WarblerIdentityWorker <sqlite-path> <duckdb-path> <socket-path>")
            return
        }
        let sqlitePath = args[1]
        let duckdbPath = args[2]
        let socketPath = args[3]

        // Event type registry
        let registry = EventTypeRegistry()
        registry.register(UserEvent.self, eventTypes: [IdentityEventTypes.userRegistered, IdentityEventTypes.userProfileUpdated, IdentityEventTypes.userDeactivated])

        // Event store (shared SQLite file)
        let eventStore = try SQLiteEventStore(path: sqlitePath)

        // Read model (per-worker DuckDB)
        let readModel = try ReadModelStore(path: duckdbPath)

        // Position store
        let positionStore = try SQLitePositionStore(path: sqlitePath)

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
        _ = handler  // Keep alive

        print("Identity worker started on \(socketPath)")

        // Run services (blocks until cancelled)
        try await services.run()
    }
}
