import Foundation
import Testing

@testable import Songbird

final class TestNotifier: Gateway, @unchecked Sendable {
    let gatewayId = "test-notifier"
    private(set) var handledEvents: [RecordedEvent] = []

    func handle(_ event: RecordedEvent) async throws {
        handledEvents.append(event)
    }
}

@Suite("Gateway")
struct GatewayTests {
    @Test func gatewayHasId() {
        let gateway = TestNotifier()
        #expect(gateway.gatewayId == "test-notifier")
    }

    @Test func gatewayHandlesEvents() async throws {
        let gateway = TestNotifier()
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
        try await gateway.handle(recorded)
        #expect(gateway.handledEvents.count == 1)
    }
}
