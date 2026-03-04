public struct AggregateRepository<A: Aggregate>: Sendable {
    public let store: any EventStore
    public let registry: EventTypeRegistry
    public let snapshotStore: (any SnapshotStore)?
    public let snapshotPolicy: SnapshotPolicy

    public init(
        store: any EventStore,
        registry: EventTypeRegistry,
        snapshotStore: (any SnapshotStore)? = nil,
        snapshotPolicy: SnapshotPolicy = .none
    ) {
        self.store = store
        self.registry = registry
        self.snapshotStore = snapshotStore
        self.snapshotPolicy = snapshotPolicy
    }

    public func load(id: String) async throws -> (state: A.State, version: Int64) {
        let stream = StreamName(category: A.category, id: id)

        // Try loading a snapshot
        var state = A.initialState
        var fromPosition: Int64 = 0
        if let snapshotStore {
            if let snapshot: (state: A.State, version: Int64) = try await snapshotStore.load(for: stream) {
                state = snapshot.state
                fromPosition = snapshot.version + 1
            }
        }

        // Fold events from the snapshot version (or 0 if no snapshot)
        let records = try await store.readStream(stream, from: fromPosition, maxCount: Int.max)
        for record in records {
            let decoded = try registry.decode(record)
            guard let event = decoded as? A.Event else {
                throw AggregateError.unexpectedEventType(record.eventType)
            }
            state = A.apply(state, event)
        }
        let version = records.last?.position ?? (fromPosition > 0 ? fromPosition - 1 : -1)
        return (state, version)
    }

    public func execute<H: CommandHandler>(
        _ command: H.Cmd,
        on id: String,
        metadata: EventMetadata,
        using handler: H.Type
    ) async throws -> [RecordedEvent] where H.Agg == A {
        let (state, version) = try await load(id: id)
        let events = try handler.handle(command, given: state)
        let stream = StreamName(category: A.category, id: id)
        var recorded: [RecordedEvent] = []
        for (index, event) in events.enumerated() {
            let result = try await store.append(
                event,
                to: stream,
                metadata: metadata,
                expectedVersion: version + Int64(index)
            )
            recorded.append(result)
        }

        // Auto-snapshot based on policy
        if case .everyNEvents(let n) = snapshotPolicy, let snapshotStore, !recorded.isEmpty {
            let newVersion = version + Int64(recorded.count)
            // Bucket comparison: snapshot when the new total event count crosses
            // an N-event boundary. This handles multi-event commands correctly —
            // modulo would miss boundaries when commands skip over them.
            let oldBucket = (version + 1) / Int64(n)
            let newBucket = (newVersion + 1) / Int64(n)
            if newBucket > oldBucket {
                var snapshotState = state
                for event in events {
                    snapshotState = A.apply(snapshotState, event)
                }
                try await snapshotStore.save(snapshotState, version: newVersion, for: stream)
            }
        }

        return recorded
    }

    /// Explicitly saves a snapshot of the aggregate's current state.
    public func saveSnapshot(id: String) async throws {
        guard let snapshotStore else { return }
        let stream = StreamName(category: A.category, id: id)
        let (state, version) = try await load(id: id)
        guard version >= 0 else { return }
        try await snapshotStore.save(state, version: version, for: stream)
    }
}

public enum AggregateError: Error {
    case unexpectedEventType(String)
}
