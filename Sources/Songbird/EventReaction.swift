// MARK: - EventReaction Protocol

/// A typed handler for a specific event type within a `ProcessManager`.
///
/// Each `EventReaction` handles one event type (or a set of related event types from the same
/// `Input` enum). It provides routing (which entity instance this event belongs to), state
/// folding, and optional output event generation.
///
/// Three methods are required:
/// - `eventTypes` -- the event type strings this reactor handles
/// - `route` -- extracts the entity instance ID from the decoded event (return nil to skip)
/// - `apply` -- folds the event into the process manager's per-entity state
///
/// Two methods have default implementations:
/// - `decode` -- decodes `RecordedEvent` into the typed `Input` (default: JSON decode)
/// - `react` -- produces output events after state is updated (default: empty array)
///
/// Usage:
/// ```swift
/// enum OnOrderPlaced: EventReaction {
///     typealias PMState = FulfillmentPM.State
///     typealias Input = OrderEvent
///
///     static let eventTypes = ["OrderPlaced"]
///
///     static func route(_ event: OrderEvent) -> String? {
///         switch event { case .placed(let id, _): id }
///     }
///
///     static func apply(_ state: PMState, _ event: OrderEvent) -> PMState {
///         switch event { case .placed(_, let total): .init(total: total, paid: false) }
///     }
///
///     static func react(_ state: PMState, _ event: OrderEvent) -> [any Event] {
///         switch event {
///         case .placed(let id, let total):
///             [FulfillmentEvent.paymentRequested(orderId: id, amount: total)]
///         }
///     }
/// }
/// ```
public protocol EventReaction {
    /// The process manager state type this reaction folds into.
    associatedtype PMState: Sendable, Equatable
    /// The concrete event type this reaction handles.
    associatedtype Input: Event

    /// The event type strings this reaction matches against `RecordedEvent.eventType`.
    static var eventTypes: [String] { get }

    /// Decodes a `RecordedEvent` into the typed `Input` event.
    /// Default implementation uses `RecordedEvent.decode(_:)` (JSON decoding).
    /// Override for event versioning or custom deserialization.
    static func decode(_ recorded: RecordedEvent) throws -> Input

    /// Extracts the routing key (entity instance ID) from the decoded event.
    /// Return `nil` to skip this event (the reaction will not be applied).
    static func route(_ event: Input) -> String?

    /// Folds the event into the per-entity state.
    static func apply(_ state: PMState, _ event: Input) -> PMState

    /// Produces output events after state has been updated.
    /// Default implementation returns an empty array.
    static func react(_ state: PMState, _ event: Input) -> [any Event]
}

extension EventReaction {
    public static func decode(_ recorded: RecordedEvent) throws -> Input {
        try recorded.decode(Input.self).event
    }

    public static func react(_ state: PMState, _ event: Input) -> [any Event] {
        []
    }
}

// MARK: - AnyReaction (Type Erasure)

/// A type-erased wrapper around an `EventReaction`, enabling heterogeneous collections of
/// reactions with different `Input` types but the same `State` type.
///
/// Uses a two-phase design to avoid the chicken-and-egg problem: the runner needs the route
/// (entity instance ID) to look up cached state, but the handler needs the state to fold.
///
/// Phase 1: `tryRoute(recorded)` -- decodes the event and extracts the route. Returns `nil`
///          if the event type doesn't match or the reactor returns nil from `route`.
/// Phase 2: `handle(state, recorded)` -- decodes the event again, folds state, produces output.
///
/// The event is decoded twice (once in each phase), which is acceptable for correctness.
/// A caching optimization could be added later if profiling shows this is a bottleneck.
///
/// `@unchecked Sendable` is justified because the stored closures only call pure static
/// methods on `EventReaction` conformances (which are stateless enum types). The closures
/// capture a generic metatype `R.Type` which Swift 6.2 does not yet consider `Sendable`,
/// but static method dispatch on value types is inherently thread-safe.
public struct AnyReaction<State: Sendable>: @unchecked Sendable {
    /// The event type strings this reaction matches.
    public let eventTypes: [String]
    /// The categories this reaction subscribes to.
    public let categories: [String]

    /// Phase 1: Attempts to route the event. Returns the entity instance ID, or nil if
    /// the event type doesn't match or the reactor declines to handle it.
    public let tryRoute: @Sendable (RecordedEvent) throws -> String?

    /// Phase 2: Given the current per-entity state and the recorded event, returns the
    /// new state and any output events to append.
    public let handle: @Sendable (State, RecordedEvent) throws -> (state: State, output: [any Event])

    public init(
        eventTypes: [String],
        categories: [String],
        tryRoute: @escaping @Sendable (RecordedEvent) throws -> String?,
        handle: @escaping @Sendable (State, RecordedEvent) throws -> (
            state: State, output: [any Event]
        )
    ) {
        self.eventTypes = eventTypes
        self.categories = categories
        self.tryRoute = tryRoute
        self.handle = handle
    }
}
