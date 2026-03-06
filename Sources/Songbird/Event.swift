import Foundation

public protocol Event: Message {
    var eventType: String { get }
    static var version: Int { get }
}

extension Event {
    public var messageType: String { eventType }
    public static var version: Int { 1 }
}

public struct EventMetadata: Sendable, Codable, Equatable {
    public var traceId: String?
    public var causationId: String?
    public var correlationId: String?
    public var userId: String?
    public var piiReferenceKey: String?

    public init(
        traceId: String? = nil,
        causationId: String? = nil,
        correlationId: String? = nil,
        userId: String? = nil,
        piiReferenceKey: String? = nil
    ) {
        self.traceId = traceId
        self.causationId = causationId
        self.correlationId = correlationId
        self.userId = userId
        self.piiReferenceKey = piiReferenceKey
    }
}

public struct RecordedEvent: Sendable, Equatable {
    public let id: UUID
    public let streamName: StreamName
    public let position: Int64
    public let globalPosition: Int64
    public let eventType: String
    public let data: Data
    public let metadata: EventMetadata
    public let timestamp: Date

    public init(
        id: UUID,
        streamName: StreamName,
        position: Int64,
        globalPosition: Int64,
        eventType: String,
        data: Data,
        metadata: EventMetadata,
        timestamp: Date
    ) {
        self.id = id
        self.streamName = streamName
        self.position = position
        self.globalPosition = globalPosition
        self.eventType = eventType
        self.data = data
        self.metadata = metadata
        self.timestamp = timestamp
    }

    public func decode<E: Event>(_ type: E.Type) throws -> EventEnvelope<E> {
        let event = try JSONDecoder().decode(E.self, from: data)
        return EventEnvelope(
            id: id,
            streamName: streamName,
            position: position,
            globalPosition: globalPosition,
            event: event,
            metadata: metadata,
            timestamp: timestamp
        )
    }
}

public struct EventEnvelope<E: Event>: Sendable {
    public let id: UUID
    public let streamName: StreamName
    public let position: Int64
    public let globalPosition: Int64
    public let event: E
    public let metadata: EventMetadata
    public let timestamp: Date

    public init(
        id: UUID,
        streamName: StreamName,
        position: Int64,
        globalPosition: Int64,
        event: E,
        metadata: EventMetadata,
        timestamp: Date
    ) {
        self.id = id
        self.streamName = streamName
        self.position = position
        self.globalPosition = globalPosition
        self.event = event
        self.metadata = metadata
        self.timestamp = timestamp
    }
}
