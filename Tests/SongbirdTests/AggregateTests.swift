import Testing

@testable import Songbird

enum CounterAggregate: Aggregate {
    struct State: Sendable, Equatable {
        var count: Int
    }

    enum Event: Songbird.Event {
        case incremented
        case decremented

        var eventType: String {
            switch self {
            case .incremented: "CounterIncremented"
            case .decremented: "CounterDecremented"
            }
        }
    }

    enum Failure: Error {
        case cannotDecrementBelowZero
    }

    static let category = "counter"
    static let initialState = State(count: 0)

    static func apply(_ state: State, _ event: Event) -> State {
        switch event {
        case .incremented: State(count: state.count + 1)
        case .decremented: State(count: state.count - 1)
        }
    }
}

@Suite("Aggregate")
struct AggregateTests {
    @Test func initialState() {
        #expect(CounterAggregate.initialState == CounterAggregate.State(count: 0))
    }

    @Test func applyIsPure() {
        let state = CounterAggregate.State(count: 5)
        let newState = CounterAggregate.apply(state, .incremented)
        #expect(newState == CounterAggregate.State(count: 6))
        #expect(state == CounterAggregate.State(count: 5))
    }

    @Test func foldEventsFromInitial() {
        let events: [CounterAggregate.Event] = [
            .incremented, .incremented, .incremented, .decremented,
        ]
        let state = events.reduce(CounterAggregate.initialState, CounterAggregate.apply)
        #expect(state == CounterAggregate.State(count: 2))
    }

    @Test func categoryProvidesStreamPrefix() {
        #expect(CounterAggregate.category == "counter")
    }
}
