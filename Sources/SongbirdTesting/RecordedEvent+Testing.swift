import Foundation
import Songbird

extension RecordedEvent {
    /// Creates a `RecordedEvent` from a typed `Event` by JSON-encoding it.
    ///
    /// Provides sensible defaults for all metadata fields, making it easy to
    /// construct test events without boilerplate.
    public init<E: Event>(
        event: E,
        id: UUID = UUID(),
        streamName: StreamName = StreamName(category: "test", id: "1"),
        position: Int64 = 0,
        globalPosition: Int64 = 0,
        metadata: EventMetadata = EventMetadata(),
        timestamp: Date = Date()
    ) throws {
        self.init(
            id: id,
            streamName: streamName,
            position: position,
            globalPosition: globalPosition,
            eventType: event.eventType,
            data: try JSONEncoder().encode(event),
            metadata: metadata,
            timestamp: timestamp
        )
    }
}
