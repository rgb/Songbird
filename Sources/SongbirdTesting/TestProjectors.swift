import Songbird

/// A projector that records every event it receives.
/// Useful for verifying that events flow through a pipeline.
public actor RecordingProjector: Projector {
    public let projectorId: String
    public private(set) var appliedEvents: [RecordedEvent] = []

    public init(id: String = "recording") {
        self.projectorId = id
    }

    public func apply(_ event: RecordedEvent) async throws {
        appliedEvents.append(event)
    }
}

/// A projector that records only events whose type is in the accepted set.
/// Useful for testing selective event handling.
public actor FilteringProjector: Projector {
    public let projectorId: String = "filtering"
    public let acceptedTypes: Set<String>
    public private(set) var appliedEvents: [RecordedEvent] = []

    public init(acceptedTypes: Set<String>) {
        self.acceptedTypes = acceptedTypes
    }

    public func apply(_ event: RecordedEvent) async throws {
        if acceptedTypes.contains(event.eventType) {
            appliedEvents.append(event)
        }
    }
}

/// Error thrown by `FailingProjector` when it encounters its target event type.
public struct FailingProjectorError: Error {
    public let eventType: String

    public init(eventType: String) {
        self.eventType = eventType
    }
}

/// A projector that throws on a specific event type, records all others.
/// Useful for testing error handling in projection pipelines.
public actor FailingProjector: Projector {
    public let projectorId: String = "failing"
    public let failOnType: String
    public private(set) var appliedEvents: [RecordedEvent] = []

    public init(failOnType: String) {
        self.failOnType = failOnType
    }

    public func apply(_ event: RecordedEvent) async throws {
        if event.eventType == failOnType {
            throw FailingProjectorError(eventType: event.eventType)
        }
        appliedEvents.append(event)
    }
}
