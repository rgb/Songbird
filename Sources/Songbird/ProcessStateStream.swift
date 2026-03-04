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
        batchSize: Int = 100,
        tickInterval: Duration = .milliseconds(100)
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
                    let batch = try await store.readCategories(
                        categories,
                        from: globalPosition,
                        maxCount: batchSize
                    )

                    for record in batch {
                        applyIfMatching(record)
                        globalPosition = record.globalPosition + 1
                    }

                    if batch.count < batchSize { break }
                }

                return state
            }

            // Phase 2: Poll for new events, yield state after each matching one
            while !Task.isCancelled {
                try Task.checkCancellation()

                let batch = try await store.readCategories(
                    categories,
                    from: globalPosition,
                    maxCount: batchSize
                )

                if !batch.isEmpty {
                    // Process all events in the batch, tracking whether any matched
                    for record in batch {
                        let matched = applyIfMatching(record)
                        globalPosition = record.globalPosition + 1
                        if matched {
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
        private mutating func applyIfMatching(_ record: RecordedEvent) -> Bool {
            for reaction in PM.reactions {
                let route: String?
                do {
                    route = try reaction.tryRoute(record)
                } catch {
                    continue
                }

                guard route == instanceId else { continue }

                // This event is for our instance -- apply it
                do {
                    let (newState, _) = try reaction.handle(state, record)
                    state = newState
                } catch {
                    // Handle error silently -- event matched route but failed to process.
                    // This could happen if the event payload is corrupted.
                }

                return true
            }
            return false
        }
    }
}
