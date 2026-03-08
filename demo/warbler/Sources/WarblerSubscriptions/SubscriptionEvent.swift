import Songbird

public enum SubscriptionEvent: Event, Equatable {
    case requested(subscriptionId: String, userId: String, plan: String)
    case paymentConfirmed(subscriptionId: String)
    case paymentFailed(subscriptionId: String, reason: String)

    public var eventType: String {
        switch self {
        case .requested: SubscriptionEventTypes.subscriptionRequested
        case .paymentConfirmed: SubscriptionEventTypes.paymentConfirmed
        case .paymentFailed: SubscriptionEventTypes.paymentFailed
        }
    }
}
