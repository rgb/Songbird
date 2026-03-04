import Foundation
import Songbird
import Testing

@testable import SongbirdTesting

private struct HarnessEvent: Event {
    var eventType: String { "HarnessEvent" }
    let value: Int
}

private actor FiniteInjector: Injector {
    let injectorId = "finite-injector"
    private let inboundEvents: [InboundEvent]
    private(set) var appendResults: [Result<RecordedEvent, any Error>] = []

    init(events: [InboundEvent]) {
        self.inboundEvents = events
    }

    nonisolated func events() -> AsyncThrowingStream<InboundEvent, Error> {
        // inboundEvents is a let constant — safe to access nonisolated
        let items = inboundEvents
        return AsyncThrowingStream<InboundEvent, Error> { continuation in
            for item in items {
                continuation.yield(item)
            }
            continuation.finish()
        }
    }

    func didAppend(_ event: InboundEvent, result: Result<RecordedEvent, any Error>) {
        appendResults.append(result)
    }
}

@Suite("TestInjectorHarness")
struct TestInjectorHarnessTests {
    @Test func runsInjectorAndReturnsAppendedEvents() async throws {
        let injector = FiniteInjector(events: [
            InboundEvent(
                event: HarnessEvent(value: 1),
                stream: StreamName(category: "test", id: "1"),
                metadata: EventMetadata()
            ),
            InboundEvent(
                event: HarnessEvent(value: 2),
                stream: StreamName(category: "test", id: "2"),
                metadata: EventMetadata()
            ),
        ])

        let harness = TestInjectorHarness(injector: injector)
        let events = try await harness.run()

        #expect(events.count == 2)
        #expect(events[0].eventType == "HarnessEvent")
        #expect(events[1].eventType == "HarnessEvent")
    }

    @Test func didAppendCalledForEachEvent() async throws {
        let injector = FiniteInjector(events: [
            InboundEvent(
                event: HarnessEvent(value: 1),
                stream: StreamName(category: "test", id: "1"),
                metadata: EventMetadata()
            ),
        ])

        let harness = TestInjectorHarness(injector: injector)
        _ = try await harness.run()

        let results = await injector.appendResults
        #expect(results.count == 1)
        if case .success = results[0] {} else {
            Issue.record("Expected .success")
        }
    }

    @Test func emptyInjectorReturnsNoEvents() async throws {
        let injector = FiniteInjector(events: [])

        let harness = TestInjectorHarness(injector: injector)
        let events = try await harness.run()

        #expect(events.isEmpty)
    }
}
