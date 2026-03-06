import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

// Reuse the RunnerFulfillmentPM and its events/reactors from ProcessManagerRunnerTests.
// They are defined at file scope so they are visible here.

/// Actor to safely collect states across task boundaries in tests.
private actor ProcessStateCollector<S: Sendable> {
    private(set) var states: [S] = []

    func append(_ state: S) {
        states.append(state)
    }

    var count: Int { states.count }
}

@Suite("ProcessStateStream")
struct ProcessStateStreamTests {

    func makeStore() -> InMemoryEventStore {
        InMemoryEventStore()
    }

    // MARK: - Empty Stream Yields Initial State

    @Test func emptyStreamYieldsInitialState() async throws {
        let store = makeStore()

        let stateStream = ProcessStateStream<RunnerFulfillmentPM>(
            instanceId: "order-1",
            store: store,
            tickInterval: .milliseconds(10)
        )

        let collector = ProcessStateCollector<RunnerFulfillmentPM.State>()
        let task = Task {
            for try await state in stateStream {
                await collector.append(state)
                if await collector.count == 1 { break }
            }
        }

        try await task.value
        let states = await collector.states
        #expect(states.count == 1)
        #expect(states[0] == RunnerFulfillmentPM.initialState)
    }

    // MARK: - Existing Events Yield Folded State

    @Test func existingEventsYieldFoldedState() async throws {
        let store = makeStore()

        // Pre-populate with an order placed event
        _ = try await store.append(
            RunnerOrderEvent.placed(orderId: "order-1", total: 300),
            to: StreamName(category: "runnerOrder", id: "order-1"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        let stateStream = ProcessStateStream<RunnerFulfillmentPM>(
            instanceId: "order-1",
            store: store,
            tickInterval: .milliseconds(10)
        )

        let collector = ProcessStateCollector<RunnerFulfillmentPM.State>()
        let task = Task {
            for try await state in stateStream {
                await collector.append(state)
                if await collector.count == 1 { break }
            }
        }

        try await task.value
        let states = await collector.states
        #expect(states.count == 1)
        #expect(states[0] == RunnerFulfillmentPM.State(total: 300, paid: false))
    }

    // MARK: - Live Updates Yield New State

    @Test func liveUpdatesYieldNewState() async throws {
        let store = makeStore()

        // Pre-populate with an order placed event
        _ = try await store.append(
            RunnerOrderEvent.placed(orderId: "order-1", total: 400),
            to: StreamName(category: "runnerOrder", id: "order-1"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        let stateStream = ProcessStateStream<RunnerFulfillmentPM>(
            instanceId: "order-1",
            store: store,
            tickInterval: .milliseconds(10)
        )

        let collector = ProcessStateCollector<RunnerFulfillmentPM.State>()
        let task = Task {
            for try await state in stateStream {
                await collector.append(state)
                if await collector.count == 2 { break }
            }
        }

        // Wait for initial fold to yield
        try await Task.sleep(for: .milliseconds(50))

        // Append a payment charged event
        _ = try await store.append(
            RunnerPaymentEvent.charged(orderId: "order-1"),
            to: StreamName(category: "runnerPayment", id: "order-1"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        try await task.value
        let states = await collector.states
        #expect(states.count == 2)
        #expect(states[0] == RunnerFulfillmentPM.State(total: 400, paid: false))
        #expect(states[1] == RunnerFulfillmentPM.State(total: 400, paid: true))
    }

    // MARK: - Filters to Specific Instance

    @Test func filtersToSpecificInstanceOnly() async throws {
        let store = makeStore()

        // Append events for two different orders
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

        // Subscribe to order-A only
        let stateStream = ProcessStateStream<RunnerFulfillmentPM>(
            instanceId: "order-A",
            store: store,
            tickInterval: .milliseconds(10)
        )

        let collector = ProcessStateCollector<RunnerFulfillmentPM.State>()
        let task = Task {
            for try await state in stateStream {
                await collector.append(state)
                if await collector.count == 1 { break }
            }
        }

        try await task.value
        let states = await collector.states
        #expect(states.count == 1)
        // Should have order-A's state, not order-B's
        #expect(states[0] == RunnerFulfillmentPM.State(total: 100, paid: false))
    }

    // MARK: - Cancellation

    @Test func stopsOnTaskCancellation() async throws {
        let store = makeStore()

        let stateStream = ProcessStateStream<RunnerFulfillmentPM>(
            instanceId: "order-1",
            store: store,
            tickInterval: .milliseconds(10)
        )

        let collector = ProcessStateCollector<RunnerFulfillmentPM.State>()
        let task = Task {
            for try await state in stateStream {
                await collector.append(state)
                // Don't break -- let it poll forever
            }
        }

        // Let the stream yield initial state
        try await Task.sleep(for: .milliseconds(50))

        // Cancel the task
        task.cancel()

        // The task should finish without hanging
        let result = await task.result
        switch result {
        case .success:
            break
        case .failure(let error):
            #expect(error is CancellationError)
        }
        let count = await collector.count
        #expect(count == 1)  // only initial state
    }

    // MARK: - Skips Non-Matching Events in Subscribed Categories

    @Test func skipsNonMatchingEventsInSubscribedCategories() async throws {
        let store = makeStore()

        // Append an event in a subscribed category with an unrecognized event type
        let unknownEvent = SubscriptionTestEvent.occurred(value: 999)
        _ = try await store.append(
            unknownEvent,
            to: StreamName(category: "runnerOrder", id: "order-1"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Then append a real order event for this entity
        _ = try await store.append(
            RunnerOrderEvent.placed(orderId: "order-1", total: 500),
            to: StreamName(category: "runnerOrder", id: "order-1"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        let stateStream = ProcessStateStream<RunnerFulfillmentPM>(
            instanceId: "order-1",
            store: store,
            tickInterval: .milliseconds(10)
        )

        let collector = ProcessStateCollector<RunnerFulfillmentPM.State>()
        let task = Task {
            for try await state in stateStream {
                await collector.append(state)
                if await collector.count == 1 { break }
            }
        }

        try await task.value
        let states = await collector.states
        #expect(states.count == 1)
        // Should only reflect the real order event, skipping the unknown one
        #expect(states[0] == RunnerFulfillmentPM.State(total: 500, paid: false))
    }
}
