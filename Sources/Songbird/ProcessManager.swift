/// A process manager that coordinates multi-step workflows by consuming events from multiple
/// categories and producing reaction events.
///
/// Each process manager declares its per-entity state type, a process identifier, an initial
/// state, and a list of `AnyReaction` registrations. Event handling is delegated entirely to
/// typed `EventReaction` conformances, registered via the `reaction(for:categories:)` helper.
///
/// Process managers track per-entity state (keyed by the route returned from each reaction).
/// They produce output events (not commands) for pure event choreography.
///
/// Usage:
/// ```swift
/// enum FulfillmentPM: ProcessManager {
///     struct State: Sendable { var total: Int; var paid: Bool }
///
///     static let processId = "fulfillment"
///     static let initialState = State(total: 0, paid: false)
///
///     static let reactions: [AnyReaction<State>] = [
///         reaction(for: OnOrderPlaced.self, categories: ["order"]),
///         reaction(for: OnPaymentResult.self, categories: ["payment"]),
///     ]
/// }
/// ```
public protocol ProcessManager {
    associatedtype State: Sendable

    /// Unique identifier for this process manager. Used as the subscriber ID for the
    /// event subscription and as the category for output event streams.
    static var processId: String { get }

    /// The initial per-entity state before any events have been processed.
    static var initialState: State { get }

    /// The list of type-erased reactions this process manager handles.
    static var reactions: [AnyReaction<State>] { get }
}

extension ProcessManager {
    /// Creates an `AnyReaction` from a typed `EventReaction` conformance.
    ///
    /// This helper bridges the generic `EventReaction` protocol into the two-phase
    /// `AnyReaction` type erasure. The `categories` parameter declares which event store
    /// categories this reaction subscribes to.
    ///
    /// - Parameters:
    ///   - reaction: The `EventReaction` type to register.
    ///   - categories: The event store categories to subscribe to for this reaction.
    /// - Returns: A type-erased `AnyReaction` suitable for inclusion in `reactions`.
    public static func reaction<R: EventReaction>(
        for _: R.Type,
        categories: [String]
    ) -> AnyReaction<State> where R.PMState == State {
        AnyReaction(
            eventTypes: R.eventTypes,
            categories: categories,
            tryRoute: { recorded in
                guard R.eventTypes.contains(recorded.eventType) else { return nil }
                let event = try R.decode(recorded)
                return R.route(event)
            },
            handle: { state, recorded in
                let event = try R.decode(recorded)
                let newState = R.apply(state, event)
                let output = R.react(newState, event)
                return (newState, output)
            }
        )
    }
}
