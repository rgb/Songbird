import Foundation
import Testing

@testable import Songbird

actor EventCounterProjector: Projector {
    let projectorId = "event-counter"
    private(set) var count = 0

    func apply(_ event: RecordedEvent) async throws {
        count += 1
    }
}

@Suite("Projector")
struct ProjectorTests {
    @Test func projectorHasId() {
        let projector = EventCounterProjector()
        #expect(projector.projectorId == "event-counter")
    }

    @Test func projectorAppliesEvents() async throws {
        let projector = EventCounterProjector()
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "test", id: "1"),
            position: 0,
            globalPosition: 0,
            eventType: "TestEvent",
            data: Data("{}".utf8),
            metadata: EventMetadata(),
            timestamp: Date()
        )
        try await projector.apply(recorded)
        try await projector.apply(recorded)
        let count = await projector.count
        #expect(count == 2)
    }
}
