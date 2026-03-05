import Songbird

public enum SubscriptionLifecycleEvent: Event {
    case accessGranted(userId: String)
    case subscriptionCancelled(reason: String)

    public var eventType: String {
        switch self {
        case .accessGranted: "AccessGranted"
        case .subscriptionCancelled: "SubscriptionCancelled"
        }
    }
}
