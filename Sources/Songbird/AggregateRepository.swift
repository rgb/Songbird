public struct AggregateRepository<A: Aggregate>: Sendable {
    public let store: any EventStore
    public let registry: EventTypeRegistry

    public init(store: any EventStore, registry: EventTypeRegistry) {
        self.store = store
        self.registry = registry
    }

    public func load(id: String) async throws -> (state: A.State, version: Int64) {
        let stream = StreamName(category: A.category, id: id)
        let records = try await store.readStream(stream, from: 0, maxCount: Int.max)
        var state = A.initialState
        for record in records {
            let decoded = try registry.decode(record)
            guard let event = decoded as? A.Event else {
                throw AggregateError.unexpectedEventType(record.eventType)
            }
            state = A.apply(state, event)
        }
        let version = records.last?.position ?? -1
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
        return recorded
    }
}

public enum AggregateError: Error {
    case unexpectedEventType(String)
}
