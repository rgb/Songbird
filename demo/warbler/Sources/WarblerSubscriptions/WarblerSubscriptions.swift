import Songbird

/// Event type string constants for the WarblerSubscriptions domain.
public enum SubscriptionEventTypes {
    public static let subscriptionRequested = "SubscriptionRequested"
    public static let paymentConfirmed = "PaymentConfirmed"
    public static let paymentFailed = "PaymentFailed"
}

/// Event type string constants for subscription lifecycle output events.
public enum LifecycleEventTypes {
    public static let accessGranted = "AccessGranted"
    public static let subscriptionCancelled = "SubscriptionCancelled"
}
