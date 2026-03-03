# Phase 7: Process Manager Runtime -- Design

## Summary

Per-entity process managers that consume events from multiple categories and produce reaction events. Uses typed `EventReaction` protocol for per-event-type handlers with default implementations for `decode` and `react`. The ProcessManagerRunner manages subscriptions, per-entity state, and output event appending.

## ProcessManager Protocol (updated)

```swift
public protocol ProcessManager {
    associatedtype State: Sendable

    static var processId: String { get }
    static var initialState: State { get }
    static var reactions: [AnyReaction<State>] { get }
}
```

Simplified from the Phase 1 stub. No more `InputEvent`, `OutputCommand`, `apply`, or `commands` on the protocol itself. All event handling is delegated to `EventReaction` types registered via `reactions`.

## EventReaction Protocol

```swift
public protocol EventReaction {
    associatedtype PMState: Sendable
    associatedtype Input: Event

    static var eventTypes: [String] { get }
    static func decode(_ recorded: RecordedEvent) throws -> Input
    static func route(_ event: Input) -> String?
    static func apply(_ state: PMState, _ event: Input) -> PMState
    static func react(_ state: PMState, _ event: Input) -> [any Event]
}

// Default implementations
extension EventReaction {
    public static func decode(_ recorded: RecordedEvent) throws -> Input {
        try recorded.decode(Input.self).event
    }

    public static func react(_ state: PMState, _ event: Input) -> [any Event] {
        []
    }
}
```

User must implement: `eventTypes`, `route`, `apply` (3 methods).
Defaults provided: `decode` (generic RecordedEvent → Input), `react` (empty output).

## AnyReaction (type erasure)

```swift
public struct AnyReaction<State: Sendable>: Sendable {
    public let eventTypes: [String]
    public let categories: [String]

    // Type-erased handler: (state, recorded) -> (route, newState, output)?
    // Returns nil if event type doesn't match
    let handle: @Sendable (State, RecordedEvent) throws -> ReactionResult<State>?
}

public struct ReactionResult<State: Sendable>: Sendable {
    public let route: String
    public let state: State
    public let output: [any Event]
}
```

## Registration Helper

```swift
extension ProcessManager {
    public static func reaction<R: EventReaction>(
        for _: R.Type,
        categories: [String]
    ) -> AnyReaction<State> where R.PMState == State {
        AnyReaction(
            eventTypes: R.eventTypes,
            categories: categories
        ) { state, recorded in
            guard R.eventTypes.contains(recorded.eventType) else { return nil }
            let event = try R.decode(recorded)
            guard let route = R.route(event) else { return nil }
            let newState = R.apply(state, event)
            let output = R.react(newState, event)
            return ReactionResult(route: route, state: newState, output: output)
        }
    }
}
```

## ProcessManagerRunner

```swift
public actor ProcessManagerRunner<PM: ProcessManager> {
    private let store: any EventStore
    private let positionStore: any PositionStore
    private let batchSize: Int
    private let tickInterval: Duration
    private var stateCache: [String: PM.State] = [:]

    public init(
        store: any EventStore,
        positionStore: any PositionStore,
        batchSize: Int = 100,
        tickInterval: Duration = .milliseconds(100)
    )

    public func run() async throws
    public func stop()
    public func state(for instanceId: String) -> PM.State
}
```

`run()`:
1. Collect all categories from `PM.reactions` (union of all reactor categories)
2. Create `EventSubscription(categories: allCategories, ...)`
3. For each event from the subscription:
   a. Try each reaction in `PM.reactions` until one matches
   b. If matched: get route (instance ID), load/create state, apply, react
   c. Append output events to store (stream: `PM.processId-{instanceId}`)
   d. Update state cache

## ProcessStateStream

```swift
public struct ProcessStateStream<PM: ProcessManager>: AsyncSequence, Sendable {
    public typealias Element = PM.State

    public init(
        instanceId: String,
        store: any EventStore,
        tickInterval: Duration = .milliseconds(100)
    )
}
```

Subscribes to the categories from `PM.reactions`, filters by route matching the instance ID, folds through the matching reactions' `apply`, yields state on each change.

## Example

```swift
// Events from different aggregates
enum OrderEvent: Event {
    case placed(orderId: String, total: Int)
    var eventType: String { switch self { case .placed: "OrderPlaced" } }
}

enum PaymentEvent: Event {
    case charged(orderId: String)
    case failed(orderId: String, reason: String)
    var eventType: String {
        switch self {
        case .charged: "PaymentCharged"
        case .failed: "PaymentFailed"
        }
    }
}

// Reaction events
enum FulfillmentEvent: Event {
    case paymentRequested(orderId: String, amount: Int)
    case shipmentRequested(orderId: String)
    var eventType: String { ... }
}

// Typed reactors (3 required methods each)
enum OnOrderPlaced: EventReaction {
    typealias PMState = FulfillmentPM.State
    typealias Input = OrderEvent

    static let eventTypes = ["OrderPlaced"]

    static func route(_ event: OrderEvent) -> String? {
        switch event { case .placed(let id, _): id }
    }

    static func apply(_ state: PMState, _ event: OrderEvent) -> PMState {
        switch event { case .placed(_, let total): .init(total: total, paid: false) }
    }

    static func react(_ state: PMState, _ event: OrderEvent) -> [any Event] {
        switch event {
        case .placed(let id, let total): [FulfillmentEvent.paymentRequested(orderId: id, amount: total)]
        }
    }
}

enum OnPaymentResult: EventReaction {
    typealias PMState = FulfillmentPM.State
    typealias Input = PaymentEvent

    static let eventTypes = ["PaymentCharged", "PaymentFailed"]

    static func route(_ event: PaymentEvent) -> String? {
        switch event {
        case .charged(let id): id
        case .failed(let id, _): id
        }
    }

    static func apply(_ state: PMState, _ event: PaymentEvent) -> PMState {
        switch event {
        case .charged: .init(total: state.total, paid: true)
        case .failed: state
        }
    }

    static func react(_ state: PMState, _ event: PaymentEvent) -> [any Event] {
        switch event {
        case .charged(let id): [FulfillmentEvent.shipmentRequested(orderId: id)]
        case .failed: []
        }
    }
}

// Process Manager
enum FulfillmentPM: ProcessManager {
    struct State: Sendable { var total: Int; var paid: Bool }

    static let processId = "fulfillment"
    static let initialState = State(total: 0, paid: false)

    static let reactions: [AnyReaction<State>] = [
        reaction(for: OnOrderPlaced.self, categories: ["order"]),
        reaction(for: OnPaymentResult.self, categories: ["payment"]),
    ]
}
```

## File Layout

```
Sources/Songbird/
├── ProcessManager.swift          (modify: simplified protocol)
├── EventReaction.swift           (new: protocol + defaults + AnyReaction + ReactionResult)
├── ProcessManagerRunner.swift    (new: actor)
├── ProcessStateStream.swift      (new: AsyncSequence)
```

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| PM output | Events (not commands) | Pure event choreography, no command storage |
| Event handling | Typed `EventReaction` per event type | Type-safe, independently testable, version-upgrade hook via `decode` |
| PM state scope | Per-entity (Hoffman model) | Enables reactive state streams, natural for workflow tracking |
| Type erasure | `AnyReaction<State>` | Collects heterogeneous reactors with different Input types |
| Default `decode` | `recorded.decode(Input.self).event` | Generic, works for any Codable event. Override for versioning. |
| Default `react` | `[]` | Most reactors only update state. Override when output needed. |
| Output stream | `PM.processId-{instanceId}` | Reaction events go to the PM's own stream, discoverable by category |
| Categories per reaction | Explicit on registration | Each reactor knows which categories to subscribe to |
