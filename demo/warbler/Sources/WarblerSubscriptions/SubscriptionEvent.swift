import Songbird

public enum SubscriptionEvent: Event {
    case requested(subscriptionId: String, userId: String, plan: String)
    case paymentConfirmed(subscriptionId: String)
    case paymentFailed(subscriptionId: String, reason: String)

    public var eventType: String {
        switch self {
        case .requested: "SubscriptionRequested"
        case .paymentConfirmed: "PaymentConfirmed"
        case .paymentFailed: "PaymentFailed"
        }
    }
}
