import Logging

/// An actor that runs a `ProcessManager` by subscribing to its declared categories,
/// dispatching events through the two-phase `AnyReaction` flow, managing per-entity state,
/// and appending output events to the event store.
///
/// The runner:
/// 1. Collects all categories from `PM.reactions` (deduplicating)
/// 2. Creates an `EventSubscription` for those categories
/// 3. For each incoming event, tries each reaction's `tryRoute` until one matches
/// 4. Looks up per-entity state from cache (or uses `PM.initialState`)
/// 5. Calls the matching reaction's `handle` to fold state and produce output events
/// 6. Appends output events to the store under `StreamName(category: PM.processId, id: route)`
/// 7. Updates the per-entity state cache
///
/// Only one reaction is applied per event (first match wins). Events that no reaction handles
/// are silently skipped. Decoding errors from `tryRoute` are silently skipped (the event type
/// matched by string but failed to decode, which may indicate a version mismatch or an event
/// from a different aggregate using the same category).
///
/// Usage:
/// ```swift
/// let runner = ProcessManagerRunner<FulfillmentPM>(
///     store: eventStore,
///     positionStore: positionStore
/// )
///
/// let task = Task { try await runner.run() }
///
/// // Later: cancel stops the subscription loop
/// task.cancel()
/// ```
public actor ProcessManagerRunner<PM: ProcessManager> {
    private let logger = Logger(label: "songbird.process-manager-runner")
    private let store: any EventStore
    private let positionStore: any PositionStore
    private let batchSize: Int
    private let tickInterval: Duration
    private let maxCacheSize: Int
    private var stateCache: [String: PM.State] = [:]

    public init(
        store: any EventStore,
        positionStore: any PositionStore,
        batchSize: Int = 100,
        tickInterval: Duration = .milliseconds(100),
        maxCacheSize: Int = 10_000
    ) {
        self.store = store
        self.positionStore = positionStore
        self.batchSize = batchSize
        self.tickInterval = tickInterval
        self.maxCacheSize = maxCacheSize
    }

    // MARK: - Lifecycle

    /// Starts the runner. This method blocks until the enclosing `Task` is cancelled.
    public func run() async throws {
        let allCategories = Array(Set(PM.reactions.flatMap(\.categories)))

        let subscription = EventSubscription(
            subscriberId: PM.processId,
            categories: allCategories,
            store: store,
            positionStore: positionStore,
            batchSize: batchSize,
            tickInterval: tickInterval
        )

        for try await event in subscription {
            try await processEvent(event)
        }
    }

    // MARK: - State Access

    /// Returns the current per-entity state for the given instance ID.
    /// Returns `PM.initialState` if no events have been processed for this entity.
    public func state(for instanceId: String) -> PM.State {
        stateCache[instanceId] ?? PM.initialState
    }

    // MARK: - Private

    private func processEvent(_ recorded: RecordedEvent) async throws {
        for reaction in PM.reactions {
            // Phase 1: Try to route the event
            let route: String?
            do {
                route = try reaction.tryRoute(recorded)
            } catch {
                logger.trace("Reaction route decode skipped",
                    metadata: [
                        "process_id": "\(PM.processId)",
                        "event_type": "\(recorded.eventType)",
                    ])
                continue
            }

            guard let route else { continue }

            // Phase 2: Look up state, apply, produce output
            let currentState = stateCache[route] ?? PM.initialState
            let (newState, output) = try reaction.handle(currentState, recorded)

            // Update state cache
            stateCache[route] = newState

            // Evict oldest entries if cache is too large.
            // Dictionary doesn't preserve insertion order, so we remove
            // arbitrary entries. Evicted entities fall back to PM.initialState.
            if stateCache.count > maxCacheSize {
                let excess = stateCache.count - maxCacheSize
                for key in stateCache.keys.prefix(excess) {
                    stateCache.removeValue(forKey: key)
                }
            }

            // Append output events
            let outputStream = StreamName(category: PM.processId, id: route)
            for event in output {
                _ = try await store.append(
                    event,
                    to: outputStream,
                    metadata: EventMetadata(),
                    expectedVersion: nil
                )
            }

            // First match wins -- stop trying other reactions
            break
        }
    }
}
