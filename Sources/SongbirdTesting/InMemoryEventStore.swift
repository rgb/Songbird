import Foundation
import Songbird

public actor InMemoryEventStore: EventStore {
    private var events: [RecordedEvent] = []
    private var streamPositions: [StreamName: Int64] = [:]
    private var nextGlobalPosition: Int64 = 0
    private let registry: EventTypeRegistry

    public init(registry: EventTypeRegistry = EventTypeRegistry()) {
        self.registry = registry
    }

    public func append(
        _ event: some Event,
        to stream: StreamName,
        metadata: EventMetadata,
        expectedVersion: Int64?
    ) async throws -> RecordedEvent {
        let currentVersion = streamPositions[stream] ?? Int64(-1)

        if let expected = expectedVersion, expected != currentVersion {
            throw VersionConflictError(
                streamName: stream,
                expectedVersion: expected,
                actualVersion: currentVersion
            )
        }

        let position = currentVersion + 1
        let globalPosition = nextGlobalPosition
        let data = try JSONEncoder().encode(event)

        let recorded = RecordedEvent(
            id: UUID(),
            streamName: stream,
            position: position,
            globalPosition: globalPosition,
            eventType: event.eventType,
            data: data,
            metadata: metadata,
            timestamp: Date()
        )

        events.append(recorded)
        streamPositions[stream] = position
        nextGlobalPosition += 1

        return recorded
    }

    public func readStream(
        _ stream: StreamName,
        from position: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        Array(
            events
                .filter { $0.streamName == stream && $0.position >= position }
                .prefix(maxCount)
        )
    }

    public func readCategory(
        _ category: String,
        from globalPosition: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        Array(
            events
                .filter { $0.streamName.category == category && $0.globalPosition >= globalPosition }
                .prefix(maxCount)
        )
    }

    public func readLastEvent(
        in stream: StreamName
    ) async throws -> RecordedEvent? {
        events.last { $0.streamName == stream }
    }

    public func streamVersion(
        _ stream: StreamName
    ) async throws -> Int64 {
        streamPositions[stream] ?? -1
    }
}
