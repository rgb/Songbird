import Foundation
import Logging
import PostgresNIO
import Songbird

/// An actor that manages a dedicated PostgresConnection for LISTEN/NOTIFY signals.
///
/// When a notification arrives on the `songbird_events` channel, waiting callers are
/// resumed immediately. Callers that arrive when no notification is pending will block
/// until either a notification fires or the timeout expires.
private actor NotificationSignal {
    private var connection: PostgresConnection?
    private var listenTask: Task<Void, any Error>?

    /// Pending waiters -- each continuation is resumed exactly once (with `true` for
    /// notification, or `false` for timeout).
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    /// Establishes the LISTEN connection and begins listening for notifications.
    func start(config: PostgresConnection.Configuration, logger: Logger) async throws {
        let conn = try await PostgresConnection.connect(
            configuration: config,
            id: 0,
            logger: logger
        )
        self.connection = conn

        // Background task that listens for notifications.
        // Uses the closure-based `listen(on:)` API so UNLISTEN is handled automatically.
        self.listenTask = Task { [weak self = self] in
            try await conn.listen(on: "songbird_events") { notifications in
                for try await _ in notifications {
                    await self?.notifyWaiters()
                }
            }
        }
    }

    /// Called from the listen task when a notification arrives.
    private func notifyWaiters() {
        for (id, continuation) in waiters {
            continuation.resume(returning: true)
            waiters.removeValue(forKey: id)
        }
    }

    /// Waits for a notification signal or timeout. Returns `true` if a notification was received.
    func wait(timeout: Duration) async -> Bool {
        let id = UUID()

        return await withCheckedContinuation { continuation in
            waiters[id] = continuation

            // Launch a timeout task that will resume the continuation if no notification arrives
            Task { [weak self = self] in
                try? await Task.sleep(for: timeout)
                await self?.timeoutWaiter(id: id)
            }
        }
    }

    /// Called from the timeout task. Resumes the waiter with `false` if it hasn't
    /// already been resumed by a notification.
    private func timeoutWaiter(id: UUID) {
        if let continuation = waiters.removeValue(forKey: id) {
            continuation.resume(returning: false)
        }
    }

    /// Closes the LISTEN connection and cancels the background listener task.
    /// Any pending waiters are resumed with `false`.
    func stop() async {
        listenTask?.cancel()
        for (id, continuation) in waiters {
            continuation.resume(returning: false)
            waiters.removeValue(forKey: id)
        }
        if let connection {
            try? await connection.close()
        }
        self.connection = nil
        self.listenTask = nil
    }

    /// Tears down and re-establishes the LISTEN connection.
    func reconnect(config: PostgresConnection.Configuration, logger: Logger) async throws {
        await stop()
        try await start(config: config, logger: logger)
    }
}

/// A LISTEN/NOTIFY-based subscription that reads events from one or more categories as an `AsyncSequence`.
///
/// This subscription uses a dedicated `PostgresConnection` to listen for `songbird_events`
/// notifications, waking up immediately when new events are appended to the store. A fallback
/// poll interval ensures events are not missed if LISTEN notifications are lost.
///
/// Position is persisted to a `PositionStore` after each batch is fully consumed, enabling
/// restartability. When `categories` is empty, the subscription reads all events across all categories.
/// The sequence ends when the enclosing `Task` is cancelled.
///
/// Usage:
/// ```swift
/// let subscription = PostgresEventSubscription(
///     store: postgresStore,
///     connectionConfig: connectionConfig,
///     subscriberId: "order-projector",
///     categories: ["order"],
///     positionStore: positionStore
/// )
///
/// let task = Task {
///     for try await event in subscription {
///         try await projector.apply(event)
///     }
/// }
///
/// // Later: cancel stops the subscription
/// task.cancel()
/// ```
public struct PostgresEventSubscription: AsyncSequence, Sendable {
    public typealias Element = RecordedEvent

    public let store: PostgresEventStore
    public let connectionConfig: PostgresConnection.Configuration
    public let subscriberId: String
    public let categories: [String]
    public let positionStore: any PositionStore
    public let batchSize: Int
    public let fallbackPollInterval: Duration

    public init(
        store: PostgresEventStore,
        connectionConfig: PostgresConnection.Configuration,
        subscriberId: String,
        categories: [String],
        positionStore: any PositionStore,
        batchSize: Int = 100,
        fallbackPollInterval: Duration = .seconds(5)
    ) {
        self.store = store
        self.connectionConfig = connectionConfig
        self.subscriberId = subscriberId
        self.categories = categories
        self.positionStore = positionStore
        self.batchSize = batchSize
        self.fallbackPollInterval = fallbackPollInterval
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(
            store: store,
            connectionConfig: connectionConfig,
            subscriberId: subscriberId,
            categories: categories,
            positionStore: positionStore,
            batchSize: batchSize,
            fallbackPollInterval: fallbackPollInterval
        )
    }

    public struct Iterator: AsyncIteratorProtocol {
        let store: PostgresEventStore
        let connectionConfig: PostgresConnection.Configuration
        let subscriberId: String
        let categories: [String]
        let positionStore: any PositionStore
        let batchSize: Int
        let fallbackPollInterval: Duration
        let logger = Logger(label: "songbird.postgres.subscription")

        private let notificationSignal = NotificationSignal()
        private var currentBatch: [RecordedEvent] = []
        private var batchIndex: Int = 0
        private var globalPosition: Int64 = -1
        private var positionLoaded: Bool = false
        private var listenStarted: Bool = false

        init(
            store: PostgresEventStore,
            connectionConfig: PostgresConnection.Configuration,
            subscriberId: String,
            categories: [String],
            positionStore: any PositionStore,
            batchSize: Int,
            fallbackPollInterval: Duration
        ) {
            self.store = store
            self.connectionConfig = connectionConfig
            self.subscriberId = subscriberId
            self.categories = categories
            self.positionStore = positionStore
            self.batchSize = batchSize
            self.fallbackPollInterval = fallbackPollInterval
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

            // Ensure LISTEN connection is started
            if !listenStarted {
                try await notificationSignal.start(config: connectionConfig, logger: logger)
                listenStarted = true
            }

            // Poll loop with LISTEN wakeup
            while !Task.isCancelled {
                try Task.checkCancellation()

                // Poll for events
                let batch = try await store.readCategories(
                    categories,
                    from: globalPosition + 1,
                    maxCount: batchSize
                )

                if !batch.isEmpty {
                    currentBatch = batch
                    batchIndex = 1  // return first element now, start from second next time
                    return batch[0]
                }

                // Caught up -- wait for LISTEN notification or fallback timeout
                let notified = await notificationSignal.wait(timeout: fallbackPollInterval)

                if !notified {
                    // Timeout with no notification -- do a fallback poll
                    let fallbackBatch = try await store.readCategories(
                        categories,
                        from: globalPosition + 1,
                        maxCount: batchSize
                    )

                    if !fallbackBatch.isEmpty {
                        // Events found via fallback that LISTEN missed -- re-establish connection
                        logger.warning(
                            "Fallback poll found events missed by LISTEN -- re-establishing connection",
                            metadata: ["subscriberId": "\(subscriberId)"]
                        )
                        try await notificationSignal.reconnect(
                            config: connectionConfig,
                            logger: logger
                        )
                        currentBatch = fallbackBatch
                        batchIndex = 1
                        return fallbackBatch[0]
                    }
                }
                // If notified, loop back to poll for the actual events
            }

            // Cancelled -- clean up LISTEN connection
            await notificationSignal.stop()
            return nil
        }
    }
}
