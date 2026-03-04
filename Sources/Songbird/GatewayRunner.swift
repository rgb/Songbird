/// An actor that runs a `Gateway` by subscribing to its declared categories and calling
/// `handle(_:)` for each event.
///
/// The runner:
/// 1. Creates an `EventSubscription` for `G.categories` with `gateway.gatewayId` as subscriber ID
/// 2. For each incoming event, calls `gateway.handle(event)`
/// 3. Errors from `handle()` are swallowed and do not stop the subscription loop
///
/// Position is persisted by the underlying `EventSubscription`, providing at-least-once delivery.
/// Gateways must be idempotent since events may be redelivered after a crash.
///
/// Usage:
/// ```swift
/// let runner = GatewayRunner(
///     gateway: webhookNotifier,
///     store: eventStore,
///     positionStore: positionStore
/// )
///
/// let task = Task { try await runner.run() }
///
/// // Later: cancel stops the subscription loop
/// task.cancel()
/// ```
public actor GatewayRunner<G: Gateway> {
    private let gateway: G
    private let store: any EventStore
    private let positionStore: any PositionStore
    private let batchSize: Int
    private let tickInterval: Duration

    public init(
        gateway: G,
        store: any EventStore,
        positionStore: any PositionStore,
        batchSize: Int = 100,
        tickInterval: Duration = .milliseconds(100)
    ) {
        self.gateway = gateway
        self.store = store
        self.positionStore = positionStore
        self.batchSize = batchSize
        self.tickInterval = tickInterval
    }

    // MARK: - Lifecycle

    /// Starts the runner. This method blocks until the enclosing `Task` is cancelled.
    public func run() async throws {
        let subscription = EventSubscription(
            subscriberId: gateway.gatewayId,
            categories: G.categories,
            store: store,
            positionStore: positionStore,
            batchSize: batchSize,
            tickInterval: tickInterval
        )

        for try await event in subscription {
            do {
                try await gateway.handle(event)
            } catch {
                // Gateway errors are swallowed and do not stop the subscription.
                // The gateway is responsible for its own retry/logging logic.
            }
        }
    }
}
