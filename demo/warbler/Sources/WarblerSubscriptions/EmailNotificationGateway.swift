import Songbird

public actor EmailNotificationGateway: Gateway {
    public let gatewayId = "EmailNotification"
    public static let categories = ["subscriptionLifecycle"]

    public struct Notification: Sendable, Equatable {
        public let type: String
        public let userId: String
    }

    /// Tracks sent notifications for testing and observability.
    /// In production, replace with metrics emission or a bounded ring buffer.
    public private(set) var sentNotifications: [Notification] = []

    public init() {}

    public func handle(_ event: RecordedEvent) async throws {
        switch event.eventType {
        case LifecycleEventTypes.accessGranted:
            let envelope = try event.decode(SubscriptionLifecycleEvent.self)
            guard case .accessGranted(let userId) = envelope.event else { return }
            sentNotifications.append(Notification(type: "welcome", userId: userId))

        case LifecycleEventTypes.subscriptionCancelled:
            let envelope = try event.decode(SubscriptionLifecycleEvent.self)
            guard case .subscriptionCancelled(let userId, _) = envelope.event else { return }
            sentNotifications.append(Notification(type: "cancellation", userId: userId))

        default:
            break
        }
    }
}
