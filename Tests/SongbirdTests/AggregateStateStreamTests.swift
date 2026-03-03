import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

// MARK: - Test Aggregate

enum BalanceAggregate: Aggregate {
    struct State: Sendable, Equatable {
        var balance: Int
    }

    enum Event: Songbird.Event {
        case credited(amount: Int)
        case debited(amount: Int)

        var eventType: String {
            switch self {
            case .credited: "BalanceCredited"
            case .debited: "BalanceDebited"
            }
        }
    }

    enum Failure: Error {
        case insufficientFunds
    }

    static let category = "balance"
    static let initialState = State(balance: 0)

    static func apply(_ state: State, _ event: Event) -> State {
        switch event {
        case .credited(let amount): State(balance: state.balance + amount)
        case .debited(let amount): State(balance: state.balance - amount)
        }
    }
}

/// Actor to safely collect states across task boundaries in tests.
private actor StateCollector<S: Sendable> {
    private(set) var states: [S] = []

    func append(_ state: S) {
        states.append(state)
    }

    var count: Int { states.count }
}

@Suite("AggregateStateStream")
struct AggregateStateStreamTests {

    func makeStore() -> (InMemoryEventStore, EventTypeRegistry) {
        let registry = EventTypeRegistry()
        registry.register(BalanceAggregate.Event.self, eventTypes: ["BalanceCredited", "BalanceDebited"])
        return (InMemoryEventStore(registry: registry), registry)
    }

    let stream = StreamName(category: "balance", id: "acct-1")

    // MARK: - Empty Stream Yields Initial State

    @Test func emptyStreamYieldsInitialState() async throws {
        let (store, registry) = makeStore()

        let stateStream = AggregateStateStream<BalanceAggregate>(
            id: "acct-1",
            store: store,
            registry: registry,
            tickInterval: .milliseconds(10)
        )

        let collector = StateCollector<BalanceAggregate.State>()
        let task = Task {
            for try await state in stateStream {
                await collector.append(state)
                if await collector.count == 1 { break }
            }
        }

        try await task.value
        let states = await collector.states
        #expect(states.count == 1)
        #expect(states[0] == BalanceAggregate.initialState)
    }

    // MARK: - Existing Events Yield Folded State

    @Test func existingEventsYieldFoldedState() async throws {
        let (store, registry) = makeStore()
        _ = try await store.append(BalanceAggregate.Event.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(BalanceAggregate.Event.debited(amount: 30), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let stateStream = AggregateStateStream<BalanceAggregate>(
            id: "acct-1",
            store: store,
            registry: registry,
            tickInterval: .milliseconds(10)
        )

        let collector = StateCollector<BalanceAggregate.State>()
        let task = Task {
            for try await state in stateStream {
                await collector.append(state)
                if await collector.count == 1 { break }
            }
        }

        try await task.value
        let states = await collector.states
        #expect(states.count == 1)
        #expect(states[0] == BalanceAggregate.State(balance: 70))
    }

    // MARK: - Live Updates Yield New State

    @Test func liveUpdatesYieldNewState() async throws {
        let (store, registry) = makeStore()
        _ = try await store.append(BalanceAggregate.Event.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let stateStream = AggregateStateStream<BalanceAggregate>(
            id: "acct-1",
            store: store,
            registry: registry,
            tickInterval: .milliseconds(10)
        )

        let collector = StateCollector<BalanceAggregate.State>()
        let task = Task {
            for try await state in stateStream {
                await collector.append(state)
                if await collector.count == 3 { break }
            }
        }

        // Wait for initial state to be yielded
        try await Task.sleep(for: .milliseconds(50))

        // Append more events -- should trigger new state yields
        _ = try await store.append(BalanceAggregate.Event.credited(amount: 50), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(BalanceAggregate.Event.debited(amount: 20), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        try await task.value
        let states = await collector.states
        #expect(states.count == 3)
        #expect(states[0] == BalanceAggregate.State(balance: 100))  // initial fold
        #expect(states[1] == BalanceAggregate.State(balance: 150))  // after +50
        #expect(states[2] == BalanceAggregate.State(balance: 130))  // after -20
    }

    // MARK: - Cancellation

    @Test func stopsOnTaskCancellation() async throws {
        let (store, registry) = makeStore()

        let stateStream = AggregateStateStream<BalanceAggregate>(
            id: "acct-1",
            store: store,
            registry: registry,
            tickInterval: .milliseconds(10)
        )

        let collector = StateCollector<BalanceAggregate.State>()
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

    // MARK: - Multiple Events in Single Poll

    @Test func multipleEventsInSinglePollYieldMultipleStates() async throws {
        let (store, registry) = makeStore()

        let stateStream = AggregateStateStream<BalanceAggregate>(
            id: "acct-1",
            store: store,
            registry: registry,
            tickInterval: .milliseconds(10)
        )

        let collector = StateCollector<BalanceAggregate.State>()
        let task = Task {
            for try await state in stateStream {
                await collector.append(state)
                // Initial state + 3 event-driven states
                if await collector.count == 4 { break }
            }
        }

        // Wait for initial empty state to be yielded
        try await Task.sleep(for: .milliseconds(50))

        // Append three events at once -- they should all be in one poll batch
        _ = try await store.append(BalanceAggregate.Event.credited(amount: 10), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(BalanceAggregate.Event.credited(amount: 20), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(BalanceAggregate.Event.credited(amount: 30), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        try await task.value
        let states = await collector.states
        #expect(states.count == 4)
        #expect(states[0] == BalanceAggregate.State(balance: 0))   // initial
        #expect(states[1] == BalanceAggregate.State(balance: 10))  // +10
        #expect(states[2] == BalanceAggregate.State(balance: 30))  // +20
        #expect(states[3] == BalanceAggregate.State(balance: 60))  // +30
    }
}
