import Songbird
import SongbirdSmew

public actor SubscriptionProjector: Projector {
    public let projectorId = "Subscriptions"
    private let readModel: ReadModelStore

    public init(readModel: ReadModelStore) {
        self.readModel = readModel
    }

    public func registerMigration() async {
        await readModel.registerMigration { conn in
            try conn.execute("""
                CREATE TABLE subscriptions (
                    id VARCHAR PRIMARY KEY,
                    user_id VARCHAR NOT NULL,
                    plan VARCHAR NOT NULL,
                    status VARCHAR NOT NULL DEFAULT 'pending'
                )
            """)
        }
    }

    public func apply(_ event: RecordedEvent) async throws {
        switch event.eventType {
        case "SubscriptionRequested":
            let envelope = try event.decode(SubscriptionEvent.self)
            guard case .requested(let subId, let userId, let plan) = envelope.event else { return }
            try await readModel.withConnection { conn in
                try conn.execute(
                    "INSERT INTO subscriptions (id, user_id, plan, status) VALUES (\(param: subId), \(param: userId), \(param: plan), \(param: "pending"))"
                )
            }

        case "AccessGranted":
            guard let subId = event.streamName.id else { return }
            try await readModel.withConnection { conn in
                try conn.execute(
                    "UPDATE subscriptions SET status = \(param: "active") WHERE id = \(param: subId)"
                )
            }

        case "SubscriptionCancelled":
            guard let subId = event.streamName.id else { return }
            try await readModel.withConnection { conn in
                try conn.execute(
                    "UPDATE subscriptions SET status = \(param: "cancelled") WHERE id = \(param: subId)"
                )
            }

        default:
            break
        }
    }
}
