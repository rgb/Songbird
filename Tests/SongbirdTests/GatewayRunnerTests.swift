import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

// MARK: - Test Gateway

private struct GatewayRunnerTestEvent: Event {
    var eventType: String { "GatewayTestEvent" }
    let value: Int
}

private actor RecordingGateway: Gateway {
    let gatewayId = "recording-gateway"
    static let categories = ["gw-test"]
    private(set) var handledEvents: [RecordedEvent] = []

    func handle(_ event: RecordedEvent) async throws {
        handledEvents.append(event)
    }
}

private actor FailingGateway: Gateway {
    let gatewayId = "failing-gateway"
    static let categories = ["gw-test"]
    private(set) var attemptCount = 0
    private(set) var successCount = 0

    func handle(_ event: RecordedEvent) async throws {
        attemptCount += 1
        if event.eventType == "GatewayTestEvent" {
            throw GatewayTestError()
        }
        successCount += 1
    }
}

private struct GatewayTestError: Error {}

private struct OtherCategoryEvent: Event {
    var eventType: String { "OtherEvent" }
}

// MARK: - Tests

@Suite("GatewayRunner")
struct GatewayRunnerTests {

    func makeStores() -> (InMemoryEventStore, InMemoryPositionStore) {
        (InMemoryEventStore(), InMemoryPositionStore())
    }

    @Test func deliversEventsToGateway() async throws {
        let (store, positionStore) = makeStores()
        let gateway = RecordingGateway()

        let runner = GatewayRunner(
            gateway: gateway,
            store: store,
            positionStore: positionStore,
            tickInterval: .milliseconds(10)
        )

        let task = Task { try await runner.run() }

        // Append an event in the gateway's subscribed category
        _ = try await store.append(
            GatewayRunnerTestEvent(value: 42),
            to: StreamName(category: "gw-test", id: "1"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Wait for the runner to process
        try await Task.sleep(for: .milliseconds(100))

        let count = await gateway.handledEvents.count
        #expect(count == 1)

        task.cancel()
        _ = await task.result
    }

    @Test func errorInHandleDoesNotStopRunner() async throws {
        let (store, positionStore) = makeStores()
        let gateway = FailingGateway()

        let runner = GatewayRunner(
            gateway: gateway,
            store: store,
            positionStore: positionStore,
            tickInterval: .milliseconds(10)
        )

        let task = Task { try await runner.run() }

        // Append two events — first will fail, second should still be delivered
        _ = try await store.append(
            GatewayRunnerTestEvent(value: 1),
            to: StreamName(category: "gw-test", id: "1"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )
        _ = try await store.append(
            OtherCategoryEvent(),
            to: StreamName(category: "gw-test", id: "2"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        try await Task.sleep(for: .milliseconds(100))

        // Both events were attempted
        let attempts = await gateway.attemptCount
        #expect(attempts == 2)

        // Only the non-failing event succeeded
        let successes = await gateway.successCount
        #expect(successes == 1)

        task.cancel()
        _ = await task.result
    }

    @Test func ignoresEventsFromNonSubscribedCategories() async throws {
        let (store, positionStore) = makeStores()
        let gateway = RecordingGateway()

        let runner = GatewayRunner(
            gateway: gateway,
            store: store,
            positionStore: positionStore,
            tickInterval: .milliseconds(10)
        )

        let task = Task { try await runner.run() }

        // Append event in a category the gateway does NOT subscribe to
        _ = try await store.append(
            GatewayRunnerTestEvent(value: 99),
            to: StreamName(category: "other-category", id: "1"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Append event in the subscribed category
        _ = try await store.append(
            GatewayRunnerTestEvent(value: 42),
            to: StreamName(category: "gw-test", id: "1"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        try await Task.sleep(for: .milliseconds(100))

        // Only the subscribed category event was delivered
        let count = await gateway.handledEvents.count
        #expect(count == 1)

        task.cancel()
        _ = await task.result
    }

    @Test func cancellationStopsTheRunner() async throws {
        let (store, positionStore) = makeStores()
        let gateway = RecordingGateway()

        let runner = GatewayRunner(
            gateway: gateway,
            store: store,
            positionStore: positionStore,
            tickInterval: .milliseconds(10)
        )

        let task = Task { try await runner.run() }

        try await Task.sleep(for: .milliseconds(50))

        task.cancel()

        let result = await task.result
        switch result {
        case .success:
            break
        case .failure(let error):
            #expect(error is CancellationError)
        }
    }
}
