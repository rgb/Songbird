import Songbird

public actor EmailNotificationGateway: Gateway {
    public let gatewayId = "EmailNotification"
    public static let categories = ["subscriptionLifecycle"]

    /// Tracks notifications sent (for testing and logging).
    public private(set) var sentNotifications: [(type: String, userId: String)] = []

    public init() {}

    public func handle(_ event: RecordedEvent) async throws {
        switch event.eventType {
        case "AccessGranted":
            let envelope = try event.decode(SubscriptionLifecycleEvent.self)
            guard case .accessGranted(let userId) = envelope.event else { return }
            sentNotifications.append((type: "welcome", userId: userId))

        case "SubscriptionCancelled":
            let envelope = try event.decode(SubscriptionLifecycleEvent.self)
            guard case .subscriptionCancelled = envelope.event else { return }
            let subId = event.streamName.id ?? "unknown"
            sentNotifications.append((type: "cancellation", userId: subId))

        default:
            break
        }
    }
}
