import Songbird
import SongbirdSmew

// This projector handles events from both "subscription" and "subscriptionLifecycle" categories.
// The ProjectionPipeline delivers all events from the event store, so both categories are covered.
public actor SubscriptionProjector: Projector {
    public let projectorId = "Subscriptions"
    public static let tableName = "subscriptions"
    private let readModel: ReadModelStore

    public init(readModel: ReadModelStore) {
        self.readModel = readModel
    }

    public func registerMigration() async {
        await readModel.registerTable(Self.tableName)
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
        case SubscriptionEventTypes.subscriptionRequested:
            let envelope = try event.decode(SubscriptionEvent.self)
            guard case .requested(let subId, let userId, let plan) = envelope.event else { return }
            try await readModel.withConnection { conn in
                try conn.execute(
                    "INSERT INTO subscriptions (id, user_id, plan, status) VALUES (\(param: subId), \(param: userId), \(param: plan), \(param: "pending"))"
                )
            }

        case LifecycleEventTypes.accessGranted:
            guard let subId = event.streamName.id else { return }
            try await readModel.withConnection { conn in
                try conn.execute(
                    "UPDATE subscriptions SET status = \(param: "active") WHERE id = \(param: subId)"
                )
            }

        case LifecycleEventTypes.subscriptionCancelled:
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
