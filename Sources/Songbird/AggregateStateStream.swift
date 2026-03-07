import Foundation

/// A reactive `AsyncSequence` that yields the current state of an aggregate, updating live
/// as new events arrive in the entity stream.
///
/// On the first iteration call, the stream reads all existing events, decodes them via the
/// provided `EventTypeRegistry`, folds them through `Aggregate.apply`, and yields the resulting
/// state. If no events exist, `Aggregate.initialState` is yielded. After the initial fold,
/// the stream polls for new events from the last known position, applies each one, and yields
/// the updated state for every event.
///
/// When an optional `SnapshotStore` is provided, the initial fold loads the latest snapshot
/// and folds only events after the snapshot version — skipping full replay. Without a snapshot
/// store, the stream folds from the beginning on creation.
///
/// This makes it suitable for live UI updates, in-memory caches, and reactive projections.
///
/// Usage:
/// ```swift
/// let stateStream = AggregateStateStream<BankAccountAggregate>(
///     id: "acct-123",
///     store: eventStore,
///     registry: registry
/// )
///
/// let task = Task {
///     for try await state in stateStream {
///         print("Balance: \(state.balance)")
///     }
/// }
///
/// // Later: cancel stops the polling loop
/// task.cancel()
/// ```
public struct AggregateStateStream<A: Aggregate>: AsyncSequence, Sendable {
    public typealias Element = A.State

    public let id: String
    public let store: any EventStore
    public let registry: EventTypeRegistry
    public let snapshotStore: (any SnapshotStore)?
    public let batchSize: Int
    public let tickInterval: Duration

    public init(
        id: String,
        store: any EventStore,
        registry: EventTypeRegistry,
        snapshotStore: (any SnapshotStore)? = nil,
        batchSize: Int = SubscriptionDefaults.batchSize,
        tickInterval: Duration = SubscriptionDefaults.tickInterval
    ) {
        precondition(batchSize > 0, "batchSize must be positive")
        self.id = id
        self.store = store
        self.registry = registry
        self.snapshotStore = snapshotStore
        self.batchSize = batchSize
        self.tickInterval = tickInterval
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(
            stream: StreamName(category: A.category, id: id),
            store: store,
            registry: registry,
            snapshotStore: snapshotStore,
            batchSize: batchSize,
            tickInterval: tickInterval
        )
    }

    public struct Iterator: AsyncIteratorProtocol {
        let stream: StreamName
        let store: any EventStore
        let registry: EventTypeRegistry
        let snapshotStore: (any SnapshotStore)?
        let batchSize: Int
        let tickInterval: Duration
        private var state: A.State = A.initialState
        private var position: Int64 = 0
        private var initialFoldDone: Bool = false
        private var pendingBatch: [RecordedEvent] = []
        private var pendingBatchIndex: Int = 0

        init(
            stream: StreamName,
            store: any EventStore,
            registry: EventTypeRegistry,
            snapshotStore: (any SnapshotStore)?,
            batchSize: Int,
            tickInterval: Duration
        ) {
            self.stream = stream
            self.store = store
            self.registry = registry
            self.snapshotStore = snapshotStore
            self.batchSize = batchSize
            self.tickInterval = tickInterval
        }

        public mutating func next() async throws -> A.State? {
            // Phase 1: Initial fold -- read all existing events and yield folded state
            if !initialFoldDone {
                initialFoldDone = true

                // Try loading a snapshot
                if let snapshotStore,
                   let snapshot: (state: A.State, version: Int64) = try await snapshotStore.load(for: stream) {
                    state = snapshot.state
                    position = snapshot.version + 1
                }

                while true {
                    try Task.checkCancellation()
                    let batch = try await store.readStream(
                        stream,
                        from: position,
                        maxCount: batchSize
                    )

                    for record in batch {
                        let decoded = try registry.decode(record)
                        guard let event = decoded as? A.Event else {
                            throw AggregateError.unexpectedEventType(record.eventType)
                        }
                        state = A.apply(state, event)
                        position = record.position + 1
                    }

                    if batch.count < batchSize { break }
                }

                return state
            }

            // Phase 2: Poll for new events, yield state after each one
            // Return next event from pending batch if available
            if pendingBatchIndex < pendingBatch.count {
                let record = pendingBatch[pendingBatchIndex]
                pendingBatchIndex += 1
                let decoded = try registry.decode(record)
                guard let event = decoded as? A.Event else {
                    throw AggregateError.unexpectedEventType(record.eventType)
                }
                state = A.apply(state, event)
                position = record.position + 1
                return state
            }

            // Pending batch exhausted -- poll for new events
            while !Task.isCancelled {
                try Task.checkCancellation()

                let batch = try await store.readStream(
                    stream,
                    from: position,
                    maxCount: batchSize
                )

                if !batch.isEmpty {
                    let record = batch[0]
                    let decoded = try registry.decode(record)
                    guard let event = decoded as? A.Event else {
                        throw AggregateError.unexpectedEventType(record.eventType)
                    }
                    state = A.apply(state, event)
                    position = record.position + 1

                    // Cache remaining events for subsequent next() calls
                    pendingBatch = batch
                    pendingBatchIndex = 1

                    return state
                }

                // Caught up -- sleep before polling again
                try await Task.sleep(for: tickInterval)
            }

            return nil  // cancelled
        }
    }
}
