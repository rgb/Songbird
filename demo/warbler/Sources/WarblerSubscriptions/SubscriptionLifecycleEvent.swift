import Songbird

public enum SubscriptionLifecycleEvent: Event, Equatable {
    case accessGranted(userId: String)
    case subscriptionCancelled(userId: String, reason: String)

    public var eventType: String {
        switch self {
        case .accessGranted: LifecycleEventTypes.accessGranted
        case .subscriptionCancelled: LifecycleEventTypes.subscriptionCancelled
        }
    }
}
