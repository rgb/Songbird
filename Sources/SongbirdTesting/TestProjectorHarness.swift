import Foundation
import Songbird

/// A harness that feeds typed events to a `Projector`, auto-encoding them
/// and auto-incrementing global positions.
///
/// ```swift
/// let projector = RecordingProjector()
/// var harness = TestProjectorHarness(projector: projector)
/// try await harness.given(OrderEvent.placed(id: "1"))
/// let events = await projector.appliedEvents
/// ```
public struct TestProjectorHarness<P: Projector> {
    /// The wrapped projector instance.
    public let projector: P

    /// The next global position to assign. Starts at 0, increments after each event.
    public private(set) var globalPosition: Int64

    public init(projector: P) {
        self.projector = projector
        self.globalPosition = 0
    }

    /// Feed a typed event to the projector.
    /// The event is JSON-encoded into a `RecordedEvent` with auto-incrementing global position.
    public mutating func given<E: Event>(
        _ event: E,
        streamName: StreamName = StreamName(category: "test", id: "1"),
        metadata: EventMetadata = EventMetadata()
    ) async throws {
        let recorded = try RecordedEvent(
            event: event,
            streamName: streamName,
            position: globalPosition,
            globalPosition: globalPosition,
            metadata: metadata
        )
        try await projector.apply(recorded)
        globalPosition += 1
    }
}
