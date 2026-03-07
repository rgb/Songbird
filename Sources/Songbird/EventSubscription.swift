import Foundation
import Metrics

/// A polling-based subscription that reads events from one or more categories as an `AsyncSequence`.
///
/// The subscription polls `EventStore.readCategories` in batches and yields events one at a time.
/// Position is persisted to a `PositionStore` after each batch is fully consumed, enabling
/// restartability. When caught up (no new events), the subscription sleeps for `tickInterval`
/// before polling again. The sequence ends when the enclosing `Task` is cancelled.
///
/// When `categories` is empty, the subscription reads all events across all categories.
///
/// Usage:
/// ```swift
/// // Single category
/// let subscription = EventSubscription(
///     subscriberId: "order-projector",
///     categories: ["order"],
///     store: eventStore,
///     positionStore: positionStore
/// )
///
/// // Multiple categories
/// let subscription = EventSubscription(
///     subscriberId: "cross-domain-projector",
///     categories: ["order", "invoice"],
///     store: eventStore,
///     positionStore: positionStore
/// )
///
/// // All events
/// let subscription = EventSubscription(
///     subscriberId: "audit-log",
///     categories: [],
///     store: eventStore,
///     positionStore: positionStore
/// )
///
/// let task = Task {
///     for try await event in subscription {
///         try await projector.apply(event)
///     }
/// }
///
/// // Later: cancel stops the polling loop
/// task.cancel()
/// ```
public struct EventSubscription: AsyncSequence, Sendable {
    public typealias Element = RecordedEvent

    public let subscriberId: String
    public let categories: [String]
    public let store: any EventStore
    public let positionStore: any PositionStore
    public let batchSize: Int
    public let tickInterval: Duration

    public init(
        subscriberId: String,
        categories: [String],
        store: any EventStore,
        positionStore: any PositionStore,
        batchSize: Int = SubscriptionDefaults.batchSize,
        tickInterval: Duration = SubscriptionDefaults.tickInterval
    ) {
        self.subscriberId = subscriberId
        self.categories = categories
        self.store = store
        self.positionStore = positionStore
        self.batchSize = batchSize
        self.tickInterval = tickInterval
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(
            subscriberId: subscriberId,
            categories: categories,
            store: store,
            positionStore: positionStore,
            batchSize: batchSize,
            tickInterval: tickInterval
        )
    }

    public struct Iterator: AsyncIteratorProtocol {
        let subscriberId: String
        let categories: [String]
        let store: any EventStore
        let positionStore: any PositionStore
        let batchSize: Int
        let tickInterval: Duration
        private var currentBatch: [RecordedEvent] = []
        private var batchIndex: Int = 0
        private var globalPosition: Int64 = -1
        private var positionLoaded: Bool = false
        private let positionGauge: Gauge
        private let batchSizeGauge: Gauge
        private let tickDurationTimer: Metrics.Timer

        init(
            subscriberId: String,
            categories: [String],
            store: any EventStore,
            positionStore: any PositionStore,
            batchSize: Int,
            tickInterval: Duration
        ) {
            self.subscriberId = subscriberId
            self.categories = categories
            self.store = store
            self.positionStore = positionStore
            self.batchSize = batchSize
            self.tickInterval = tickInterval
            self.positionGauge = Gauge(
                label: "songbird_subscription_position",
                dimensions: [("subscriber_id", subscriberId)]
            )
            self.batchSizeGauge = Gauge(
                label: "songbird_subscription_batch_size",
                dimensions: [("subscriber_id", subscriberId)]
            )
            self.tickDurationTimer = Metrics.Timer(
                label: "songbird_subscription_tick_duration_seconds",
                dimensions: [("subscriber_id", subscriberId)]
            )
        }

        public mutating func next() async throws -> RecordedEvent? {
            // Load persisted position on first call
            if !positionLoaded {
                globalPosition = try await positionStore.load(subscriberId: subscriberId) ?? -1
                positionLoaded = true
            }

            // Return next event from current batch if available
            if batchIndex < currentBatch.count {
                let event = currentBatch[batchIndex]
                batchIndex += 1
                return event
            }

            // Current batch exhausted -- save position if we had events
            if !currentBatch.isEmpty {
                let lastPosition = currentBatch[currentBatch.count - 1].globalPosition
                try await positionStore.save(
                    subscriberId: subscriberId,
                    globalPosition: lastPosition
                )
                globalPosition = lastPosition
                positionGauge.record(Double(lastPosition))
            }

            // Poll for next batch
            while !Task.isCancelled {
                try Task.checkCancellation()

                let tickStart = ContinuousClock.now
                let batch = try await store.readCategories(
                    categories,
                    from: globalPosition + 1,
                    maxCount: batchSize
                )
                let tickElapsed = ContinuousClock.now - tickStart
                tickDurationTimer.recordNanoseconds(tickElapsed.nanoseconds)

                if !batch.isEmpty {
                    batchSizeGauge.record(Double(batch.count))
                    currentBatch = batch
                    batchIndex = 1  // return first element now, start from second next time
                    return batch[0]
                }

                // Caught up -- sleep before polling again
                try await Task.sleep(for: tickInterval)
            }

            // Flush position on cancellation if we had events
            if !currentBatch.isEmpty && batchIndex > 0 {
                let lastDeliveredIndex = Swift.min(batchIndex, currentBatch.count) - 1
                let lastDelivered = currentBatch[lastDeliveredIndex].globalPosition
                if lastDelivered > globalPosition {
                    try? await positionStore.save(
                        subscriberId: subscriberId,
                        globalPosition: lastDelivered
                    )
                }
            }

            return nil  // cancelled
        }
    }
}
