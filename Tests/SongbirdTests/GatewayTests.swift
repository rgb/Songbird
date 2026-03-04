import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

actor TestNotifier: Gateway {
    let gatewayId = "test-notifier"
    static let categories = ["test"]
    private(set) var handledEvents: [RecordedEvent] = []

    func handle(_ event: RecordedEvent) async throws {
        handledEvents.append(event)
    }
}

private struct GatewayTestEvent: Event {
    var eventType: String { "TestEvent" }
}

@Suite("Gateway")
struct GatewayTests {
    @Test func gatewayHasId() {
        let gateway = TestNotifier()
        #expect(gateway.gatewayId == "test-notifier")
    }

    @Test func gatewayHandlesEvents() async throws {
        let gateway = TestNotifier()
        let recorded = try RecordedEvent(event: GatewayTestEvent())
        try await gateway.handle(recorded)
        let count = await gateway.handledEvents.count
        #expect(count == 1)
    }
}
