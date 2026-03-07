import Foundation

/// A reactive `AsyncSequence` that yields the current state of a process manager entity,
/// updating live as new events arrive across the PM's subscribed categories.
///
/// On the first iteration call, the stream reads all existing events from the PM's categories
/// (via `readCategories`), filters them by trying each reaction's `tryRoute` for the target
/// instance ID, folds matching events through the reaction's `apply`, and yields the resulting
/// state. If no matching events exist, `PM.initialState` is yielded. After the initial fold,
/// the stream polls for new events, applies matching ones, and yields the updated state for
/// each matching event.
///
/// The stream does not persist position -- it always folds from the beginning on creation.
/// This makes it suitable for live UI updates, in-memory caches, and reactive projections.
///
/// Usage:
/// ```swift
/// let stateStream = ProcessStateStream<FulfillmentPM>(
///     instanceId: "order-123",
///     store: eventStore
/// )
///
/// let task = Task {
///     for try await state in stateStream {
///         print("State: \(state)")
///     }
/// }
///
/// // Later: cancel stops the polling loop
/// task.cancel()
/// ```
public struct ProcessStateStream<PM: ProcessManager>: AsyncSequence, Sendable {
    public typealias Element = PM.State

    public let instanceId: String
    public let store: any EventStore
    public let batchSize: Int
    public let tickInterval: Duration

    public init(
        instanceId: String,
        store: any EventStore,
        batchSize: Int = SubscriptionDefaults.batchSize,
        tickInterval: Duration = SubscriptionDefaults.tickInterval
    ) {
        self.instanceId = instanceId
        self.store = store
        self.batchSize = batchSize
        self.tickInterval = tickInterval
    }

    public func makeAsyncIterator() -> Iterator {
        let allCategories = Array(Set(PM.reactions.flatMap(\.categories)))
        return Iterator(
            instanceId: instanceId,
            categories: allCategories,
            store: store,
            batchSize: batchSize,
            tickInterval: tickInterval
        )
    }

    public struct Iterator: AsyncIteratorProtocol {
        let instanceId: String
        let categories: [String]
        let store: any EventStore
        let batchSize: Int
        let tickInterval: Duration
        private var state: PM.State = PM.initialState
        private var globalPosition: Int64 = 0
        private var initialFoldDone: Bool = false
        private var pendingBatch: [RecordedEvent] = []
        private var pendingBatchIndex: Int = 0

        init(
            instanceId: String,
            categories: [String],
            store: any EventStore,
            batchSize: Int,
            tickInterval: Duration
        ) {
            self.instanceId = instanceId
            self.categories = categories
            self.store = store
            self.batchSize = batchSize
            self.tickInterval = tickInterval
        }

        public mutating func next() async throws -> PM.State? {
            // Phase 1: Initial fold -- read all existing events and yield folded state
            if !initialFoldDone {
                initialFoldDone = true

                while true {
                    try Task.checkCancellation()
                    let batch = try await store.readCategories(
                        categories,
                        from: globalPosition,
                        maxCount: batchSize
                    )

                    for record in batch {
                        try applyIfMatching(record)
                        globalPosition = record.globalPosition + 1
                    }

                    if batch.count < batchSize { break }
                }

                return state
            }

            // Phase 2: Poll for new events, yield state after each matching one
            // Return from pending batch if available
            while pendingBatchIndex < pendingBatch.count {
                let record = pendingBatch[pendingBatchIndex]
                pendingBatchIndex += 1
                let matched = try applyIfMatching(record)
                globalPosition = record.globalPosition + 1
                if matched {
                    return state
                }
            }

            // Pending batch exhausted -- poll for new events
            while !Task.isCancelled {
                try Task.checkCancellation()

                let batch = try await store.readCategories(
                    categories,
                    from: globalPosition,
                    maxCount: batchSize
                )

                if !batch.isEmpty {
                    for (index, record) in batch.enumerated() {
                        let matched = try applyIfMatching(record)
                        globalPosition = record.globalPosition + 1
                        if matched {
                            // Cache remaining events for subsequent next() calls
                            pendingBatch = batch
                            pendingBatchIndex = index + 1
                            return state
                        }
                    }
                    // No events in this batch matched our instance -- continue polling
                    continue
                }

                // Caught up -- sleep before polling again
                try await Task.sleep(for: tickInterval)
            }

            return nil  // cancelled
        }

        /// Tries each reaction's `tryRoute` for this event. If one matches the instance ID,
        /// applies the reaction's `handle` to fold state. Returns true if a match was found.
        @discardableResult
        private mutating func applyIfMatching(_ record: RecordedEvent) throws -> Bool {
            for reaction in PM.reactions {
                let route: String?
                do {
                    route = try reaction.tryRoute(record)
                } catch {
                    continue
                }

                guard route == instanceId else { continue }

                // This event is for our instance -- apply it.
                // Errors propagate to the caller so events are not silently lost.
                let (newState, _) = try reaction.handle(state, record)
                state = newState

                return true
            }
            return false
        }
    }
}
