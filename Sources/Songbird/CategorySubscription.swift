import Foundation

/// A polling-based subscription that reads events from a single category as an `AsyncSequence`.
///
/// The subscription polls `EventStore.readCategory` in batches and yields events one at a time.
/// Position is persisted to a `PositionStore` after each batch is fully consumed, enabling
/// restartability. When caught up (no new events), the subscription sleeps for `tickInterval`
/// before polling again. The sequence ends when the enclosing `Task` is cancelled.
///
/// Usage:
/// ```swift
/// let subscription = CategorySubscription(
///     subscriberId: "order-projector",
///     category: "order",
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
public struct CategorySubscription: AsyncSequence, Sendable {
    public typealias Element = RecordedEvent

    public let subscriberId: String
    public let category: String
    public let store: any EventStore
    public let positionStore: any PositionStore
    public let batchSize: Int
    public let tickInterval: Duration

    public init(
        subscriberId: String,
        category: String,
        store: any EventStore,
        positionStore: any PositionStore,
        batchSize: Int = 100,
        tickInterval: Duration = .milliseconds(100)
    ) {
        self.subscriberId = subscriberId
        self.category = category
        self.store = store
        self.positionStore = positionStore
        self.batchSize = batchSize
        self.tickInterval = tickInterval
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(
            subscriberId: subscriberId,
            category: category,
            store: store,
            positionStore: positionStore,
            batchSize: batchSize,
            tickInterval: tickInterval
        )
    }

    public struct Iterator: AsyncIteratorProtocol {
        let subscriberId: String
        let category: String
        let store: any EventStore
        let positionStore: any PositionStore
        let batchSize: Int
        let tickInterval: Duration
        private var currentBatch: [RecordedEvent] = []
        private var batchIndex: Int = 0
        private var globalPosition: Int64 = -1
        private var positionLoaded: Bool = false

        init(
            subscriberId: String,
            category: String,
            store: any EventStore,
            positionStore: any PositionStore,
            batchSize: Int,
            tickInterval: Duration
        ) {
            self.subscriberId = subscriberId
            self.category = category
            self.store = store
            self.positionStore = positionStore
            self.batchSize = batchSize
            self.tickInterval = tickInterval
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
            }

            // Poll for next batch
            while !Task.isCancelled {
                try Task.checkCancellation()

                let batch = try await store.readCategory(
                    category,
                    from: globalPosition + 1,
                    maxCount: batchSize
                )

                if !batch.isEmpty {
                    currentBatch = batch
                    batchIndex = 1  // return first element now, start from second next time
                    return batch[0]
                }

                // Caught up -- sleep before polling again
                try await Task.sleep(for: tickInterval)
            }

            return nil  // cancelled
        }
    }
}
