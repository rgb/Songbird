import Songbird

/// A value-type harness for testing aggregates in isolation, without an event store.
///
/// Provides a `given`/`when` API:
/// - `given` feeds events to fold into the aggregate state
/// - `when` executes a command handler against the current state, folds resulting events
///
/// ```swift
/// var harness = TestAggregateHarness<MyAggregate>()
/// harness.given(.accountOpened(name: "Alice"))
/// let events = try harness.when(Deposit(amount: 100), using: DepositHandler.self)
/// #expect(harness.state == MyAggregate.State(balance: 100))
/// ```
public struct TestAggregateHarness<A: Aggregate> {
    /// The current aggregate state after all applied events.
    public private(set) var state: A.State

    /// The current version (number of events applied minus one, starting at -1).
    public private(set) var version: Int64

    /// All events that have been applied, from both `given` and `when` calls.
    public private(set) var appliedEvents: [A.Event]

    public init(state: A.State = A.initialState) {
        self.state = state
        self.version = -1
        self.appliedEvents = []
    }

    /// Feed events to fold into the aggregate state.
    public mutating func given(_ events: A.Event...) {
        given(events)
    }

    /// Feed an array of events to fold into the aggregate state.
    public mutating func given(_ events: [A.Event]) {
        for event in events {
            state = A.apply(state, event)
            version += 1
            appliedEvents.append(event)
        }
    }

    /// Execute a command handler against the current state.
    /// Returns the events produced by the handler. Those events are also folded into state.
    @discardableResult
    public mutating func when<H: CommandHandler>(
        _ command: H.Cmd,
        using handler: H.Type
    ) throws -> [A.Event] where H.Agg == A {
        let events = try handler.handle(command, given: state)
        for event in events {
            state = A.apply(state, event)
            version += 1
            appliedEvents.append(event)
        }
        return events
    }
}
