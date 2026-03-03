import Foundation

/// A polling-based subscription that reads events from a single entity stream as an `AsyncSequence`.
///
/// The subscription polls `EventStore.readStream` in batches and yields events one at a time.
/// Unlike `EventSubscription`, `StreamSubscription` does not persist position -- it is designed
/// for reactive use cases where you fold events from a known start position and track live updates.
///
/// When caught up (no new events), the subscription sleeps for `tickInterval` before polling again.
/// The sequence ends when the enclosing `Task` is cancelled.
///
/// Usage:
/// ```swift
/// let subscription = StreamSubscription(
///     stream: StreamName(category: "account", id: "123"),
///     store: eventStore
/// )
///
/// let task = Task {
///     for try await event in subscription {
///         // process event
///     }
/// }
///
/// // Later: cancel stops the polling loop
/// task.cancel()
/// ```
public struct StreamSubscription: AsyncSequence, Sendable {
    public typealias Element = RecordedEvent

    public let stream: StreamName
    public let store: any EventStore
    public let startPosition: Int64
    public let batchSize: Int
    public let tickInterval: Duration

    public init(
        stream: StreamName,
        store: any EventStore,
        startPosition: Int64 = 0,
        batchSize: Int = 100,
        tickInterval: Duration = .milliseconds(100)
    ) {
        self.stream = stream
        self.store = store
        self.startPosition = startPosition
        self.batchSize = batchSize
        self.tickInterval = tickInterval
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(
            stream: stream,
            store: store,
            position: startPosition,
            batchSize: batchSize,
            tickInterval: tickInterval
        )
    }

    public struct Iterator: AsyncIteratorProtocol {
        let stream: StreamName
        let store: any EventStore
        let batchSize: Int
        let tickInterval: Duration
        private var currentBatch: [RecordedEvent] = []
        private var batchIndex: Int = 0
        private var position: Int64

        init(
            stream: StreamName,
            store: any EventStore,
            position: Int64,
            batchSize: Int,
            tickInterval: Duration
        ) {
            self.stream = stream
            self.store = store
            self.position = position
            self.batchSize = batchSize
            self.tickInterval = tickInterval
        }

        public mutating func next() async throws -> RecordedEvent? {
            // Return next event from current batch if available
            if batchIndex < currentBatch.count {
                let event = currentBatch[batchIndex]
                batchIndex += 1
                return event
            }

            // Current batch exhausted -- advance position
            if !currentBatch.isEmpty {
                position = currentBatch[currentBatch.count - 1].position + 1
            }

            // Poll for next batch
            while !Task.isCancelled {
                try Task.checkCancellation()

                let batch = try await store.readStream(
                    stream,
                    from: position,
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
