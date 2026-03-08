import Songbird
import SongbirdSmew

public actor UserProjector: Projector {
    public let projectorId = "Users"
    private let readModel: ReadModelStore

    public init(readModel: ReadModelStore) {
        self.readModel = readModel
    }

    /// Registers the users table migration. Call before `readModel.migrate()`.
    public func registerMigration() async {
        await readModel.registerMigration { conn in
            try conn.execute("""
                CREATE TABLE users (
                    id VARCHAR PRIMARY KEY,
                    email VARCHAR NOT NULL,
                    display_name VARCHAR NOT NULL,
                    is_active BOOLEAN NOT NULL DEFAULT TRUE
                )
            """)
        }
    }

    public func apply(_ event: RecordedEvent) async throws {
        guard let userId = event.streamName.id else { return }

        switch event.eventType {
        case IdentityEventTypes.userRegistered:
            let envelope = try event.decode(UserEvent.self)
            guard case .registered(let email, let displayName) = envelope.event else { return }
            try await readModel.withConnection { conn in
                try conn.execute(
                    "INSERT INTO users (id, email, display_name, is_active) VALUES (\(param: userId), \(param: email), \(param: displayName), \(param: true))"
                )
            }

        case IdentityEventTypes.userProfileUpdated:
            let envelope = try event.decode(UserEvent.self)
            guard case .profileUpdated(let displayName) = envelope.event else { return }
            try await readModel.withConnection { conn in
                try conn.execute(
                    "UPDATE users SET display_name = \(param: displayName) WHERE id = \(param: userId)"
                )
            }

        case IdentityEventTypes.userDeactivated:
            try await readModel.withConnection { conn in
                try conn.execute(
                    "UPDATE users SET is_active = \(param: false) WHERE id = \(param: userId)"
                )
            }

        default:
            break
        }
    }
}
