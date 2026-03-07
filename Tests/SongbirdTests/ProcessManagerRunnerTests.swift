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

    static let processId = "runnerFulfillment"
    static let initialState = State(total: 0, paid: false)

    static let reactions: [AnyReaction<State>] = [
        reaction(for: RunnerOnOrderPlaced.self, categories: ["runnerOrder"]),
        reaction(for: RunnerOnPaymentCharged.self, categories: ["runnerPayment"]),
    ]
}

// MARK: - Failing Event Store

/// An event store that fails on append for a configurable stream category.
/// All other operations delegate to the inner `InMemoryEventStore`.
private actor FailingEventStore: EventStore {
    let inner = InMemoryEventStore()
    let failCategory: String

    init(failCategory: String) {
        self.failCategory = failCategory
    }

    func append(
        _ event: some Event,
        to stream: StreamName,
        metadata: EventMetadata,
        expectedVersion: Int64?
    ) async throws -> RecordedEvent {
        if stream.category == failCategory {
            throw FailingStoreError.simulatedFailure
        }
        return try await inner.append(event, to: stream, metadata: metadata, expectedVersion: expectedVersion)
    }

    func readStream(
        _ stream: StreamName,
        from position: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        try await inner.readStream(stream, from: position, maxCount: maxCount)
    }

    func readCategories(
        _ categories: [String],
        from globalPosition: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        try await inner.readCategories(categories, from: globalPosition, maxCount: maxCount)
    }

    func readLastEvent(in stream: StreamName) async throws -> RecordedEvent? {
        try await inner.readLastEvent(in: stream)
    }

    func streamVersion(_ stream: StreamName) async throws -> Int64 {
        try await inner.streamVersion(stream)
    }

    enum FailingStoreError: Error {
        case simulatedFailure
    }
}

// MARK: - Tests

@Suite("ProcessManagerRunner")
struct ProcessManagerRunnerTests {

    func makeStores() -> (InMemoryEventStore, InMemoryPositionStore) {
        (InMemoryEventStore(), InMemoryPositionStore())
    }

    /// Polls a condition until it returns true, with a timeout safety net.
    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
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
        let orderStream = StreamName(category: "runnerOrder", id: "order-1")
        _ = try await store.append(
            RunnerOrderEvent.placed(orderId: "order-1", total: 100),
            to: orderStream,
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Wait for the runner to process the event and emit a reaction
        let outputStream = StreamName(category: "runnerFulfillment", id: "order-1")
        try await waitUntil {
            let events = try? await store.readStream(outputStream, from: 0, maxCount: 100)
            return (events?.count ?? 0) >= 1
        }

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
            to: StreamName(category: "runnerOrder", id: "order-A"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )
        _ = try await store.append(
            RunnerOrderEvent.placed(orderId: "order-B", total: 200),
            to: StreamName(category: "runnerOrder", id: "order-B"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Wait for both entities to be processed
        try await waitUntil {
            let a = await runner.state(for: "order-A")
            let b = await runner.state(for: "order-B")
            return a != RunnerFulfillmentPM.initialState && b != RunnerFulfillmentPM.initialState
        }

        // Check per-entity state
        let stateA = await runner.state(for: "order-A")
        #expect(stateA == RunnerFulfillmentPM.State(total: 100, paid: false))

        let stateB = await runner.state(for: "order-B")
        #expect(stateB == RunnerFulfillmentPM.State(total: 200, paid: false))

        // Each entity should have its own output stream
        let outputA = try await store.readStream(
            StreamName(category: "runnerFulfillment", id: "order-A"),
            from: 0,
            maxCount: 100
        )
        let outputB = try await store.readStream(
            StreamName(category: "runnerFulfillment", id: "order-B"),
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
            to: StreamName(category: "runnerOrder", id: "order-1"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Wait for step 1 to be processed
        try await waitUntil {
            let s = await runner.state(for: "order-1")
            return s.total == 150
        }

        // Step 2: Charge payment
        _ = try await store.append(
            RunnerPaymentEvent.charged(orderId: "order-1"),
            to: StreamName(category: "runnerPayment", id: "order-1"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Wait for step 2 to be processed
        try await waitUntil {
            let s = await runner.state(for: "order-1")
            return s.paid
        }

        // State should reflect both steps
        let state = await runner.state(for: "order-1")
        #expect(state == RunnerFulfillmentPM.State(total: 150, paid: true))

        // Output stream should have both reaction events
        let outputStream = StreamName(category: "runnerFulfillment", id: "order-1")
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
            to: StreamName(category: "runnerOrder", id: "x"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Append a canary event that WILL be processed — once it's done,
        // the unknown event above was definitely already encountered and skipped.
        _ = try await store.append(
            RunnerOrderEvent.placed(orderId: "canary", total: 1),
            to: StreamName(category: "runnerOrder", id: "canary"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        try await waitUntil {
            let s = await runner.state(for: "canary")
            return s != RunnerFulfillmentPM.initialState
        }

        // No state should be cached for "x" (no reaction matched)
        let state = await runner.state(for: "x")
        #expect(state == RunnerFulfillmentPM.initialState)

        // No output events should exist
        let outputEvents = try await store.readStream(
            StreamName(category: "runnerFulfillment", id: "x"),
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

    // MARK: - Cache Eviction

    @Test func cacheEvictsEntriesWhenExceedingMaxSize() async throws {
        let (store, positionStore) = makeStores()

        let runner = ProcessManagerRunner<RunnerFulfillmentPM>(
            store: store,
            positionStore: positionStore,
            tickInterval: .milliseconds(10),
            maxCacheSize: 2
        )

        let task = Task { try await runner.run() }

        // Append events for 3 different entities
        for i in 1...3 {
            let orderId = "order-\(i)"
            _ = try await store.append(
                RunnerOrderEvent.placed(orderId: orderId, total: i * 100),
                to: StreamName(category: "runnerOrder", id: orderId),
                metadata: EventMetadata(),
                expectedVersion: nil
            )
        }

        // Wait for the runner to process all 3 events
        try await waitUntil {
            let s = await runner.state(for: "order-3")
            return s != RunnerFulfillmentPM.initialState
        }

        // With maxCacheSize: 2, at least one of the first two entities should have
        // been evicted (returning initialState). The third entity is always cached
        // because it was inserted last and eviction happens after insertion.
        let state1 = await runner.state(for: "order-1")
        let state2 = await runner.state(for: "order-2")
        let state3 = await runner.state(for: "order-3")

        let evictedCount = [state1, state2, state3].filter { $0 == RunnerFulfillmentPM.initialState }.count
        #expect(evictedCount >= 1, "At least one entity should have been evicted from the cache")

        // The most recently processed entity should still be cached
        #expect(state3 == RunnerFulfillmentPM.State(total: 300, paid: false))

        task.cancel()
        _ = await task.result
    }

    // MARK: - Error Recovery

    @Test func continuesProcessingAfterAppendFailure() async throws {
        // The PM outputs to "runnerFulfillment" category — make that fail
        let store = FailingEventStore(failCategory: "runnerFulfillment")
        let positionStore = InMemoryPositionStore()

        let runner = ProcessManagerRunner<RunnerFulfillmentPM>(
            store: store,
            positionStore: positionStore,
            tickInterval: .milliseconds(10)
        )

        let task = Task { try await runner.run() }

        // Append two order events directly to the inner store so the subscription
        // can read them. The PM will try to emit output for each, but the output
        // append will fail (simulated). The runner should NOT crash.
        _ = try await store.inner.append(
            RunnerOrderEvent.placed(orderId: "order-1", total: 100),
            to: StreamName(category: "runnerOrder", id: "order-1"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )
        _ = try await store.inner.append(
            RunnerOrderEvent.placed(orderId: "order-2", total: 200),
            to: StreamName(category: "runnerOrder", id: "order-2"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Wait for runner to process both events (state updates even on append failure)
        try await waitUntil {
            let s1 = await runner.state(for: "order-1")
            let s2 = await runner.state(for: "order-2")
            return s1 != RunnerFulfillmentPM.initialState && s2 != RunnerFulfillmentPM.initialState
        }

        // The runner should still be alive (not crashed).
        // State is updated BEFORE the append call in processEvent, so even though
        // the output append fails, the state cache reflects that events were handled.
        let state1 = await runner.state(for: "order-1")
        let state2 = await runner.state(for: "order-2")
        #expect(state1 == RunnerFulfillmentPM.State(total: 100, paid: false))
        #expect(state2 == RunnerFulfillmentPM.State(total: 200, paid: false))

        // No output events should exist (appends failed)
        let output1 = try await store.readStream(
            StreamName(category: "runnerFulfillment", id: "order-1"), from: 0, maxCount: 100
        )
        let output2 = try await store.readStream(
            StreamName(category: "runnerFulfillment", id: "order-2"), from: 0, maxCount: 100
        )
        #expect(output1.isEmpty)
        #expect(output2.isEmpty)

        task.cancel()
        _ = await task.result
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
