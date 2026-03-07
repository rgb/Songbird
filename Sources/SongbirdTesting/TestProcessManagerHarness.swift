import Foundation
import Songbird

/// A value-type harness for testing process managers in isolation, without an event store or runner.
///
/// Routes events through the process manager's `AnyReaction` registrations and tracks
/// per-entity state and accumulated output events.
///
/// ```swift
/// var harness = TestProcessManagerHarness<FulfillmentPM>()
/// try harness.given(OrderEvent.placed(orderId: "1", total: 100),
///                   streamName: StreamName(category: "order", id: "1"))
/// #expect(harness.state(for: "1") == FulfillmentPM.State(total: 100, paid: false))
/// #expect(harness.output.count == 1)
/// ```
public struct TestProcessManagerHarness<PM: ProcessManager> {
    /// Per-entity state, keyed by the route (entity instance ID) from reactions.
    public private(set) var states: [String: PM.State]

    /// All output events accumulated across all `given` calls.
    public private(set) var output: [any Event]

    public init() {
        self.states = [:]
        self.output = []
    }

    /// Feed a raw `RecordedEvent` through the process manager's reactions.
    /// Matches the first reaction whose `tryRoute` returns a non-nil route,
    /// then calls `handle` with the current per-entity state.
    public mutating func given(_ event: RecordedEvent) throws {
        for reaction in PM.reactions {
            let route: String?
            do {
                route = try reaction.tryRoute(event)
            } catch {
                // tryRoute throws when decoding fails for a non-matching event type.
                // Skip to next reaction (matches ProcessManagerRunner behavior).
                continue
            }

            guard let route else { continue }

            let currentState = states[route] ?? PM.initialState
            let (newState, newOutput) = try reaction.handle(currentState, event)
            states[route] = newState
            output.append(contentsOf: newOutput)
            return
        }
        // No matching reaction — silently skip (matches ProcessManagerRunner behavior)
    }

    /// Feed a typed event through the process manager's reactions.
    /// The event is auto-encoded to a `RecordedEvent` via the convenience initializer.
    public mutating func given<E: Event>(
        _ event: E,
        streamName: StreamName,
        metadata: EventMetadata = EventMetadata()
    ) throws {
        let recorded = try RecordedEvent(
            event: event,
            streamName: streamName,
            metadata: metadata
        )
        try given(recorded)
    }

    /// Get the per-entity state for a given instance ID.
    /// Returns `PM.initialState` if no events have been routed to this entity.
    public func state(for instanceId: String) -> PM.State {
        states[instanceId] ?? PM.initialState
    }
}
