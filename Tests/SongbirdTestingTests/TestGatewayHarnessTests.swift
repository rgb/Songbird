import Foundation
import Songbird
import Testing

@testable import SongbirdTesting

private struct HarnessTestEvent: Event {
    var eventType: String { "HarnessTestEvent" }
    let value: Int
}

private actor SuccessGateway: Gateway {
    let gatewayId = "success-gateway"
    static let categories = ["test"]
    private(set) var received: [RecordedEvent] = []

    func handle(_ event: RecordedEvent) async throws {
        received.append(event)
    }
}

private actor SelectiveGateway: Gateway {
    let gatewayId = "selective-gateway"
    static let categories = ["test"]

    func handle(_ event: RecordedEvent) async throws {
        if event.eventType == "bad" {
            throw SelectiveError()
        }
    }
}

private struct SelectiveError: Error {}

private struct BadEvent: Event {
    var eventType: String { "bad" }
}

@Suite("TestGatewayHarness")
struct TestGatewayHarnessTests {
    @Test func tracksProcessedEvents() async throws {
        let gateway = SuccessGateway()
        var harness = TestGatewayHarness(gateway: gateway)

        let event = try RecordedEvent(event: HarnessTestEvent(value: 1))
        await harness.given(event)

        #expect(harness.processedEvents.count == 1)
        #expect(harness.errors.isEmpty)
    }

    @Test func capturesErrorsWithoutThrowing() async throws {
        let gateway = SelectiveGateway()
        var harness = TestGatewayHarness(gateway: gateway)

        let badEvent = try RecordedEvent(event: BadEvent())
        await harness.given(badEvent)

        #expect(harness.processedEvents.isEmpty)
        #expect(harness.errors.count == 1)
        #expect(harness.errors[0].1 is SelectiveError)
    }

    @Test func tracksMultipleEventsAndErrors() async throws {
        let gateway = SelectiveGateway()
        var harness = TestGatewayHarness(gateway: gateway)

        let goodEvent = try RecordedEvent(event: HarnessTestEvent(value: 1))
        let badEvent = try RecordedEvent(event: BadEvent())

        await harness.given(goodEvent)
        await harness.given(badEvent)
        await harness.given(goodEvent)

        #expect(harness.processedEvents.count == 2)
        #expect(harness.errors.count == 1)
    }
}
