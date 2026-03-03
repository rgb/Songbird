import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

// MARK: - Test Event Types

enum RunnerOrderEvent: Event {
    case placed(orderId: String, total: Int)

    var eventType: String {
        switch self {
        case .placed: "RunnerOrderPlaced"
        }
    }
}

enum RunnerPaymentEvent: Event {
    case charged(orderId: String)

    var eventType: String {
        switch self {
        case .charged: "RunnerPaymentCharged"
        }
    }
}

enum RunnerFulfillmentEvent: Event {
    case paymentRequested(orderId: String, amount: Int)
    case shipmentRequested(orderId: String)

    var eventType: String {
        switch self {
        case .paymentRequested: "RunnerPaymentRequested"
        case .shipmentRequested: "RunnerShipmentRequested"
        }
    }
}

// MARK: - Test Reactors

enum RunnerOnOrderPlaced: EventReaction {
    typealias PMState = RunnerFulfillmentPM.State
    typealias Input = RunnerOrderEvent

    static let eventTypes = ["RunnerOrderPlaced"]

    static func route(_ event: RunnerOrderEvent) -> String? {
        switch event {
        case .placed(let orderId, _): orderId
        }
    }

    static func apply(_ state: PMState, _ event: RunnerOrderEvent) -> PMState {
        switch event {
        case .placed(_, let total):
            RunnerFulfillmentPM.State(total: total, paid: false)
        }
    }

    static func react(_ state: PMState, _ event: RunnerOrderEvent) -> [any Event] {
        switch event {
        case .placed(let orderId, let total):
            [RunnerFulfillmentEvent.paymentRequested(orderId: orderId, amount: total)]
        }
    }
}

enum RunnerOnPaymentCharged: EventReaction {
    typealias PMState = RunnerFulfillmentPM.State
    typealias Input = RunnerPaymentEvent

    static let eventTypes = ["RunnerPaymentCharged"]

    static func route(_ event: RunnerPaymentEvent) -> String? {
        switch event {
        case .charged(let orderId): orderId
        }
    }

    static func apply(_ state: PMState, _ event: RunnerPaymentEvent) -> PMState {
        switch event {
        case .charged:
            RunnerFulfillmentPM.State(total: state.total, paid: true)
        }
    }

    static func react(_ state: PMState, _ event: RunnerPaymentEvent) -> [any Event] {
        switch event {
        case .charged(let orderId):
            [RunnerFulfillmentEvent.shipmentRequested(orderId: orderId)]
        }
    }
}

// MARK: - Test Process Manager

enum RunnerFulfillmentPM: ProcessManager {
    struct State: Sendable, Equatable {
        var total: Int
        var paid: Bool
    }

    static let processId = "runner-fulfillment"
    static let initialState = State(total: 0, paid: false)

    static let reactions: [AnyReaction<State>] = [
        reaction(for: RunnerOnOrderPlaced.self, categories: ["runner-order"]),
        reaction(for: RunnerOnPaymentCharged.self, categories: ["runner-payment"]),
    ]
}

// MARK: - Tests

@Suite("ProcessManagerRunner")
struct ProcessManagerRunnerTests {

    func makeStores() -> (InMemoryEventStore, InMemoryPositionStore) {
        (InMemoryEventStore(), InMemoryPositionStore())
    }

    // MARK: - Event Processing

    @Test func processesEventAndEmitsReactionEvent() async throws {
        let (store, positionStore) = makeStores()

        let runner = ProcessManagerRunner<RunnerFulfillmentPM>(
            store: store,
            positionStore: positionStore,
            tickInterval: .milliseconds(10)
        )

        let task = Task { try await runner.run() }

        // Append an order placed event
        let orderStream = StreamName(category: "runner-order", id: "order-1")
        _ = try await store.append(
            RunnerOrderEvent.placed(orderId: "order-1", total: 100),
            to: orderStream,
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Wait for the runner to process the event
        try await Task.sleep(for: .milliseconds(100))

        // Check that a reaction event was appended
        let outputStream = StreamName(category: "runner-fulfillment", id: "order-1")
        let outputEvents = try await store.readStream(outputStream, from: 0, maxCount: 100)

        #expect(outputEvents.count == 1)
        #expect(outputEvents[0].eventType == "RunnerPaymentRequested")

        let decoded = try outputEvents[0].decode(RunnerFulfillmentEvent.self).event
        #expect(
            decoded == RunnerFulfillmentEvent.paymentRequested(orderId: "order-1", amount: 100))

        task.cancel()
        _ = await task.result
    }

    // MARK: - Per-Entity State Isolation

    @Test func maintainsPerEntityStateIsolation() async throws {
        let (store, positionStore) = makeStores()

        let runner = ProcessManagerRunner<RunnerFulfillmentPM>(
            store: store,
            positionStore: positionStore,
            tickInterval: .milliseconds(10)
        )

        let task = Task { try await runner.run() }

        // Place two separate orders
        _ = try await store.append(
            RunnerOrderEvent.placed(orderId: "order-A", total: 100),
            to: StreamName(category: "runner-order", id: "order-A"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )
        _ = try await store.append(
            RunnerOrderEvent.placed(orderId: "order-B", total: 200),
            to: StreamName(category: "runner-order", id: "order-B"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Wait for processing
        try await Task.sleep(for: .milliseconds(100))

        // Check per-entity state
        let stateA = await runner.state(for: "order-A")
        #expect(stateA == RunnerFulfillmentPM.State(total: 100, paid: false))

        let stateB = await runner.state(for: "order-B")
        #expect(stateB == RunnerFulfillmentPM.State(total: 200, paid: false))

        // Each entity should have its own output stream
        let outputA = try await store.readStream(
            StreamName(category: "runner-fulfillment", id: "order-A"),
            from: 0,
            maxCount: 100
        )
        let outputB = try await store.readStream(
            StreamName(category: "runner-fulfillment", id: "order-B"),
            from: 0,
            maxCount: 100
        )

        #expect(outputA.count == 1)
        #expect(outputB.count == 1)

        let decodedA = try outputA[0].decode(RunnerFulfillmentEvent.self).event
        #expect(
            decodedA == RunnerFulfillmentEvent.paymentRequested(orderId: "order-A", amount: 100))

        let decodedB = try outputB[0].decode(RunnerFulfillmentEvent.self).event
        #expect(
            decodedB == RunnerFulfillmentEvent.paymentRequested(orderId: "order-B", amount: 200))

        task.cancel()
        _ = await task.result
    }

    // MARK: - Multi-Step Workflow

    @Test func handlesMultiStepWorkflow() async throws {
        let (store, positionStore) = makeStores()

        let runner = ProcessManagerRunner<RunnerFulfillmentPM>(
            store: store,
            positionStore: positionStore,
            tickInterval: .milliseconds(10)
        )

        let task = Task { try await runner.run() }

        // Step 1: Place order
        _ = try await store.append(
            RunnerOrderEvent.placed(orderId: "order-1", total: 150),
            to: StreamName(category: "runner-order", id: "order-1"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        try await Task.sleep(for: .milliseconds(100))

        // Step 2: Charge payment
        _ = try await store.append(
            RunnerPaymentEvent.charged(orderId: "order-1"),
            to: StreamName(category: "runner-payment", id: "order-1"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        try await Task.sleep(for: .milliseconds(100))

        // State should reflect both steps
        let state = await runner.state(for: "order-1")
        #expect(state == RunnerFulfillmentPM.State(total: 150, paid: true))

        // Output stream should have both reaction events
        let outputStream = StreamName(category: "runner-fulfillment", id: "order-1")
        let outputEvents = try await store.readStream(outputStream, from: 0, maxCount: 100)

        #expect(outputEvents.count == 2)
        #expect(outputEvents[0].eventType == "RunnerPaymentRequested")
        #expect(outputEvents[1].eventType == "RunnerShipmentRequested")

        task.cancel()
        _ = await task.result
    }

    // MARK: - Skips Irrelevant Events

    @Test func skipsEventsWithNoMatchingReaction() async throws {
        let (store, positionStore) = makeStores()

        let runner = ProcessManagerRunner<RunnerFulfillmentPM>(
            store: store,
            positionStore: positionStore,
            tickInterval: .milliseconds(10)
        )

        let task = Task { try await runner.run() }

        // Append an event in a subscribed category but with an unknown event type.
        let unknownEvent = SubscriptionTestEvent.occurred(value: 999)
        _ = try await store.append(
            unknownEvent,
            to: StreamName(category: "runner-order", id: "x"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        try await Task.sleep(for: .milliseconds(100))

        // No state should be cached for "x" (no reaction matched)
        let state = await runner.state(for: "x")
        #expect(state == RunnerFulfillmentPM.initialState)

        // No output events should exist
        let outputEvents = try await store.readStream(
            StreamName(category: "runner-fulfillment", id: "x"),
            from: 0,
            maxCount: 100
        )
        #expect(outputEvents.isEmpty)

        task.cancel()
        _ = await task.result
    }

    // MARK: - State Access

    @Test func stateReturnsInitialStateForUnknownEntity() async throws {
        let (store, positionStore) = makeStores()

        let runner = ProcessManagerRunner<RunnerFulfillmentPM>(
            store: store,
            positionStore: positionStore,
            tickInterval: .milliseconds(10)
        )

        let state = await runner.state(for: "nonexistent")
        #expect(state == RunnerFulfillmentPM.initialState)
    }

    // MARK: - Cancellation

    @Test func cancellationStopsTheRunner() async throws {
        let (store, positionStore) = makeStores()

        let runner = ProcessManagerRunner<RunnerFulfillmentPM>(
            store: store,
            positionStore: positionStore,
            tickInterval: .milliseconds(10)
        )

        let task = Task { try await runner.run() }

        // Let the runner start polling
        try await Task.sleep(for: .milliseconds(50))

        // Cancel
        task.cancel()

        // The task should finish without hanging
        let result = await task.result
        switch result {
        case .success:
            break
        case .failure(let error):
            #expect(error is CancellationError)
        }
    }
}
