/// Default configuration values for polling-based subscriptions and state streams.
///
/// These are used as default parameter values across `EventSubscription`,
/// `StreamSubscription`, `GatewayRunner`, `ProcessManagerRunner`,
/// `AggregateStateStream`, and `ProcessStateStream`.
public enum SubscriptionDefaults {
    /// Default number of events to read per polling batch.
    public static let batchSize: Int = 100

    /// Default interval between polling ticks when caught up.
    public static let tickInterval: Duration = .milliseconds(100)
}
