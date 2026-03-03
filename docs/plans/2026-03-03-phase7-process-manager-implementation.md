# Phase 7: Process Manager Runtime -- Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the Phase 1 ProcessManager stub with a full runtime: typed `EventReaction` protocol for per-event-type handlers, two-phase `AnyReaction` type erasure, `ProcessManagerRunner` actor that subscribes to categories and appends reaction events, and `ProcessStateStream` for reactive per-entity state observation.

**Architecture:** Each `ProcessManager` declares a list of `AnyReaction<State>` registrations built from typed `EventReaction` conformances. The `ProcessManagerRunner` actor collects all categories from the reactions, subscribes via `EventSubscription`, and for each incoming event: (1) tries each reaction's `tryRoute` to find the routing key (entity instance ID), (2) looks up cached per-entity state (or uses `initialState`), (3) calls `handle` to fold state and produce output events, (4) appends output events to the store under `StreamName(category: PM.processId, id: instanceId)`. The `ProcessStateStream` provides a reactive `AsyncSequence` over a specific entity's state by subscribing to the PM's input categories and folding matching events.

**Tech Stack:** Swift 6.2+, macOS 14+, Swift Testing, AsyncSequence/AsyncIteratorProtocol, InMemoryEventStore/InMemoryPositionStore for tests

**Test command:** `swift package clean && swift test 2>&1`

**Build command:** `swift build 2>&1`

**Design doc:** `docs/plans/2026-03-03-phase7-process-manager-design.md`

---

### Task 1: EventReaction protocol + AnyReaction + ReactionResult (ATOMIC)

This introduces the core abstractions for typed event handling in process managers. `EventReaction` is a protocol with 5 static methods (3 required, 2 with defaults). `AnyReaction` is a two-phase type-erased wrapper that separates routing from handling to avoid the chicken-and-egg problem of needing a route to look up state before calling the handler. `ReactionResult` is a simple data holder for the routing/state/output tuple (used only internally by the single-phase design reference in the design doc, but we keep it as a public type for potential future use in diagnostics).

**Files:**
- Create: `Sources/Songbird/EventReaction.swift`
- Create: `Tests/SongbirdTests/EventReactionTests.swift`

**Step 1: Write the tests**

Create `Tests/SongbirdTests/EventReactionTests.swift`:

```swift
import Foundation
import Testing

@testable import Songbird

// MARK: - Test Event Types

enum ReactionTestEvent: Event {
    case occurred(id: String, value: Int)

    var eventType: String {
        switch self {
        case .occurred: "Occurred"
        }
    }
}

enum ReactionOutputEvent: Event {
    case reacted(id: String, doubled: Int)

    var eventType: String {
        switch self {
        case .reacted: "Reacted"
        }
    }
}

// MARK: - Test State

struct ReactionTestState: Sendable, Equatable {
    var total: Int
}

// MARK: - Test Reactors

/// Minimal reactor: implements 3 required methods, relies on defaults for decode and react.
enum OnOccurred: EventReaction {
    typealias PMState = ReactionTestState
    typealias Input = ReactionTestEvent

    static let eventTypes = ["Occurred"]

    static func route(_ event: ReactionTestEvent) -> String? {
        switch event {
        case .occurred(let id, _): id
        }
    }

    static func apply(_ state: ReactionTestState, _ event: ReactionTestEvent) -> ReactionTestState {
        switch event {
        case .occurred(_, let value): ReactionTestState(total: state.total + value)
        }
    }
}

/// Reactor that overrides react to produce output events.
enum OnOccurredWithReaction: EventReaction {
    typealias PMState = ReactionTestState
    typealias Input = ReactionTestEvent

    static let eventTypes = ["Occurred"]

    static func route(_ event: ReactionTestEvent) -> String? {
        switch event {
        case .occurred(let id, _): id
        }
    }

    static func apply(_ state: ReactionTestState, _ event: ReactionTestEvent) -> ReactionTestState {
        switch event {
        case .occurred(_, let value): ReactionTestState(total: state.total + value)
        }
    }

    static func react(_ state: ReactionTestState, _ event: ReactionTestEvent) -> [any Event] {
        switch event {
        case .occurred(let id, let value):
            [ReactionOutputEvent.reacted(id: id, doubled: value * 2)]
        }
    }
}

/// Reactor that returns nil from route to signal "not interested".
enum OnOccurredSkipper: EventReaction {
    typealias PMState = ReactionTestState
    typealias Input = ReactionTestEvent

    static let eventTypes = ["Occurred"]

    static func route(_ event: ReactionTestEvent) -> String? {
        switch event {
        case .occurred(let id, _):
            id.hasPrefix("skip-") ? nil : id
        }
    }

    static func apply(_ state: ReactionTestState, _ event: ReactionTestEvent) -> ReactionTestState {
        switch event {
        case .occurred(_, let value): ReactionTestState(total: state.total + value)
        }
    }
}

// MARK: - Tests

@Suite("EventReaction")
struct EventReactionTests {

    // MARK: - Protocol Conformance

    @Test func eventTypesReturnsRegisteredTypes() {
        #expect(OnOccurred.eventTypes == ["Occurred"])
    }

    @Test func routeReturnsEntityId() {
        let event = ReactionTestEvent.occurred(id: "entity-1", value: 10)
        #expect(OnOccurred.route(event) == "entity-1")
    }

    @Test func applyFoldsState() {
        let initial = ReactionTestState(total: 0)
        let event = ReactionTestEvent.occurred(id: "e1", value: 5)
        let result = OnOccurred.apply(initial, event)
        #expect(result == ReactionTestState(total: 5))
    }

    // MARK: - Default Implementations

    @Test func defaultDecodeWorksForCodableEvent() throws {
        let event = ReactionTestEvent.occurred(id: "e1", value: 42)
        let data = try JSONEncoder().encode(event)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "test", id: "e1"),
            position: 0,
            globalPosition: 0,
            eventType: "Occurred",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )
        let decoded = try OnOccurred.decode(recorded)
        #expect(decoded == event)
    }

    @Test func defaultReactReturnsEmptyArray() {
        let state = ReactionTestState(total: 10)
        let event = ReactionTestEvent.occurred(id: "e1", value: 5)
        let output = OnOccurred.react(state, event)
        #expect(output.isEmpty)
    }

    // MARK: - Overridden react

    @Test func overriddenReactProducesOutputEvents() {
        let state = ReactionTestState(total: 10)
        let event = ReactionTestEvent.occurred(id: "e1", value: 7)
        let output = OnOccurredWithReaction.react(state, event)
        #expect(output.count == 1)
        let reacted = output[0] as? ReactionOutputEvent
        #expect(reacted == ReactionOutputEvent.reacted(id: "e1", doubled: 14))
    }

    // MARK: - Route returning nil

    @Test func routeReturnsNilForSkippedEvents() {
        let event = ReactionTestEvent.occurred(id: "skip-123", value: 1)
        #expect(OnOccurredSkipper.route(event) == nil)
    }

    @Test func routeReturnsIdForNonSkippedEvents() {
        let event = ReactionTestEvent.occurred(id: "entity-1", value: 1)
        #expect(OnOccurredSkipper.route(event) == "entity-1")
    }

    // MARK: - AnyReaction Type Erasure

    @Test func anyReactionTryRouteReturnsRouteForMatchingEventType() throws {
        let event = ReactionTestEvent.occurred(id: "e1", value: 10)
        let data = try JSONEncoder().encode(event)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "test", id: "e1"),
            position: 0,
            globalPosition: 0,
            eventType: "Occurred",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let anyReaction = AnyReaction<ReactionTestState>(
            eventTypes: OnOccurred.eventTypes,
            categories: ["test"],
            tryRoute: { recorded in
                guard OnOccurred.eventTypes.contains(recorded.eventType) else { return nil }
                let event = try OnOccurred.decode(recorded)
                return OnOccurred.route(event)
            },
            handle: { state, recorded in
                let event = try OnOccurred.decode(recorded)
                let newState = OnOccurred.apply(state, event)
                let output = OnOccurred.react(newState, event)
                return (newState, output)
            }
        )

        let route = try anyReaction.tryRoute(recorded)
        #expect(route == "e1")
    }

    @Test func anyReactionTryRouteReturnsNilForNonMatchingEventType() throws {
        let event = ReactionTestEvent.occurred(id: "e1", value: 10)
        let data = try JSONEncoder().encode(event)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "test", id: "e1"),
            position: 0,
            globalPosition: 0,
            eventType: "SomeOtherType",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let anyReaction = AnyReaction<ReactionTestState>(
            eventTypes: OnOccurred.eventTypes,
            categories: ["test"],
            tryRoute: { recorded in
                guard OnOccurred.eventTypes.contains(recorded.eventType) else { return nil }
                let event = try OnOccurred.decode(recorded)
                return OnOccurred.route(event)
            },
            handle: { state, recorded in
                let event = try OnOccurred.decode(recorded)
                let newState = OnOccurred.apply(state, event)
                let output = OnOccurred.react(newState, event)
                return (newState, output)
            }
        )

        let route = try anyReaction.tryRoute(recorded)
        #expect(route == nil)
    }

    @Test func anyReactionHandleReturnsNewStateAndOutput() throws {
        let event = ReactionTestEvent.occurred(id: "e1", value: 10)
        let data = try JSONEncoder().encode(event)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "test", id: "e1"),
            position: 0,
            globalPosition: 0,
            eventType: "Occurred",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let anyReaction = AnyReaction<ReactionTestState>(
            eventTypes: OnOccurredWithReaction.eventTypes,
            categories: ["test"],
            tryRoute: { recorded in
                guard OnOccurredWithReaction.eventTypes.contains(recorded.eventType) else { return nil }
                let event = try OnOccurredWithReaction.decode(recorded)
                return OnOccurredWithReaction.route(event)
            },
            handle: { state, recorded in
                let event = try OnOccurredWithReaction.decode(recorded)
                let newState = OnOccurredWithReaction.apply(state, event)
                let output = OnOccurredWithReaction.react(newState, event)
                return (newState, output)
            }
        )

        let initialState = ReactionTestState(total: 5)
        let (newState, output) = try anyReaction.handle(initialState, recorded)
        #expect(newState == ReactionTestState(total: 15))
        #expect(output.count == 1)
        #expect((output[0] as? ReactionOutputEvent) == ReactionOutputEvent.reacted(id: "e1", doubled: 20))
    }
}
```

**Step 2: Create EventReaction.swift**

Create `Sources/Songbird/EventReaction.swift`:

```swift
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
    associatedtype PMState: Sendable
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
public struct AnyReaction<State: Sendable>: Sendable {
    /// The event type strings this reaction matches.
    public let eventTypes: [String]
    /// The categories this reaction subscribes to.
    public let categories: [String]

    /// Phase 1: Attempts to route the event. Returns the entity instance ID, or nil if
    /// the event type doesn't match or the reactor declines to handle it.
    let tryRoute: @Sendable (RecordedEvent) throws -> String?

    /// Phase 2: Given the current per-entity state and the recorded event, returns the
    /// new state and any output events to append.
    let handle: @Sendable (State, RecordedEvent) throws -> (state: State, output: [any Event])

    public init(
        eventTypes: [String],
        categories: [String],
        tryRoute: @escaping @Sendable (RecordedEvent) throws -> String?,
        handle: @escaping @Sendable (State, RecordedEvent) throws -> (state: State, output: [any Event])
    ) {
        self.eventTypes = eventTypes
        self.categories = categories
        self.tryRoute = tryRoute
        self.handle = handle
    }
}
```

**Step 3: Build and test**

```bash
swift build 2>&1
swift test 2>&1
```

**Commit message:**

```
Add EventReaction protocol and AnyReaction type erasure

Introduce the core event handling abstractions for process managers:
- EventReaction protocol with 3 required methods (eventTypes, route,
  apply) and 2 defaults (decode, react)
- AnyReaction two-phase type erasure separating routing from handling
  to resolve the state-lookup chicken-and-egg problem
```

---

### Task 2: ProcessManager protocol update + registration helper (ATOMIC)

This replaces the Phase 1 ProcessManager stub with the new protocol that uses `AnyReaction<State>` registrations. The `reaction(for:categories:)` helper bridges typed `EventReaction` conformances into the two-phase `AnyReaction` wrapper. The existing tests must be completely rewritten since the protocol shape changes (no more `InputEvent`, `OutputCommand`, `apply`, `commands`).

**Files:**
- Modify: `Sources/Songbird/ProcessManager.swift` (replace entire content)
- Rewrite: `Tests/SongbirdTests/ProcessManagerTests.swift` (replace entire content)

**Step 1: Rewrite the tests**

Replace the entire contents of `Tests/SongbirdTests/ProcessManagerTests.swift` with:

```swift
import Foundation
import Testing

@testable import Songbird

// MARK: - Domain Events (from external aggregates)

enum PMOrderEvent: Event {
    case placed(orderId: String, total: Int)

    var eventType: String {
        switch self {
        case .placed: "OrderPlaced"
        }
    }
}

enum PMPaymentEvent: Event {
    case charged(orderId: String)
    case failed(orderId: String, reason: String)

    var eventType: String {
        switch self {
        case .charged: "PaymentCharged"
        case .failed: "PaymentFailed"
        }
    }
}

// MARK: - Reaction Events (emitted by the process manager)

enum PMFulfillmentEvent: Event {
    case paymentRequested(orderId: String, amount: Int)
    case shipmentRequested(orderId: String)

    var eventType: String {
        switch self {
        case .paymentRequested: "PaymentRequested"
        case .shipmentRequested: "ShipmentRequested"
        }
    }
}

// MARK: - Typed Reactors

enum PMOnOrderPlaced: EventReaction {
    typealias PMState = PMFulfillmentPM.State
    typealias Input = PMOrderEvent

    static let eventTypes = ["OrderPlaced"]

    static func route(_ event: PMOrderEvent) -> String? {
        switch event {
        case .placed(let orderId, _): orderId
        }
    }

    static func apply(_ state: PMState, _ event: PMOrderEvent) -> PMState {
        switch event {
        case .placed(_, let total):
            PMFulfillmentPM.State(total: total, paid: false)
        }
    }

    static func react(_ state: PMState, _ event: PMOrderEvent) -> [any Event] {
        switch event {
        case .placed(let orderId, let total):
            [PMFulfillmentEvent.paymentRequested(orderId: orderId, amount: total)]
        }
    }
}

enum PMOnPaymentResult: EventReaction {
    typealias PMState = PMFulfillmentPM.State
    typealias Input = PMPaymentEvent

    static let eventTypes = ["PaymentCharged", "PaymentFailed"]

    static func route(_ event: PMPaymentEvent) -> String? {
        switch event {
        case .charged(let orderId): orderId
        case .failed(let orderId, _): orderId
        }
    }

    static func apply(_ state: PMState, _ event: PMPaymentEvent) -> PMState {
        switch event {
        case .charged:
            PMFulfillmentPM.State(total: state.total, paid: true)
        case .failed:
            state
        }
    }

    static func react(_ state: PMState, _ event: PMPaymentEvent) -> [any Event] {
        switch event {
        case .charged(let orderId):
            [PMFulfillmentEvent.shipmentRequested(orderId: orderId)]
        case .failed:
            []
        }
    }
}

// MARK: - Process Manager

enum PMFulfillmentPM: ProcessManager {
    struct State: Sendable, Equatable {
        var total: Int
        var paid: Bool
    }

    static let processId = "fulfillment"
    static let initialState = State(total: 0, paid: false)

    static let reactions: [AnyReaction<State>] = [
        reaction(for: PMOnOrderPlaced.self, categories: ["order"]),
        reaction(for: PMOnPaymentResult.self, categories: ["payment"]),
    ]
}

// MARK: - Tests

@Suite("ProcessManager")
struct ProcessManagerTests {

    // MARK: - Protocol Properties

    @Test func processIdIsAccessible() {
        #expect(PMFulfillmentPM.processId == "fulfillment")
    }

    @Test func initialStateIsAccessible() {
        #expect(PMFulfillmentPM.initialState == PMFulfillmentPM.State(total: 0, paid: false))
    }

    @Test func reactionsContainsBothReactors() {
        #expect(PMFulfillmentPM.reactions.count == 2)
    }

    // MARK: - Reaction Registration

    @Test func firstReactionHasCorrectEventTypes() {
        #expect(PMFulfillmentPM.reactions[0].eventTypes == ["OrderPlaced"])
    }

    @Test func firstReactionHasCorrectCategories() {
        #expect(PMFulfillmentPM.reactions[0].categories == ["order"])
    }

    @Test func secondReactionHasCorrectEventTypes() {
        #expect(PMFulfillmentPM.reactions[1].eventTypes == ["PaymentCharged", "PaymentFailed"])
    }

    @Test func secondReactionHasCorrectCategories() {
        #expect(PMFulfillmentPM.reactions[1].categories == ["payment"])
    }

    // MARK: - AnyReaction Routing via Registration Helper

    @Test func reactionRoutesOrderPlacedEvent() throws {
        let event = PMOrderEvent.placed(orderId: "order-1", total: 100)
        let data = try JSONEncoder().encode(event)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "order", id: "order-1"),
            position: 0,
            globalPosition: 0,
            eventType: "OrderPlaced",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let route = try PMFulfillmentPM.reactions[0].tryRoute(recorded)
        #expect(route == "order-1")
    }

    @Test func reactionReturnsNilForNonMatchingEventType() throws {
        let event = PMOrderEvent.placed(orderId: "order-1", total: 100)
        let data = try JSONEncoder().encode(event)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "order", id: "order-1"),
            position: 0,
            globalPosition: 0,
            eventType: "SomethingElse",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let route = try PMFulfillmentPM.reactions[0].tryRoute(recorded)
        #expect(route == nil)
    }

    // MARK: - AnyReaction Handle via Registration Helper

    @Test func reactionAppliesOrderPlacedAndProducesOutput() throws {
        let event = PMOrderEvent.placed(orderId: "order-1", total: 250)
        let data = try JSONEncoder().encode(event)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "order", id: "order-1"),
            position: 0,
            globalPosition: 0,
            eventType: "OrderPlaced",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let initialState = PMFulfillmentPM.initialState
        let (newState, output) = try PMFulfillmentPM.reactions[0].handle(initialState, recorded)

        #expect(newState == PMFulfillmentPM.State(total: 250, paid: false))
        #expect(output.count == 1)
        #expect((output[0] as? PMFulfillmentEvent) == PMFulfillmentEvent.paymentRequested(orderId: "order-1", amount: 250))
    }

    @Test func reactionAppliesPaymentChargedAndProducesShipment() throws {
        let event = PMPaymentEvent.charged(orderId: "order-1")
        let data = try JSONEncoder().encode(event)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "payment", id: "order-1"),
            position: 0,
            globalPosition: 0,
            eventType: "PaymentCharged",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let currentState = PMFulfillmentPM.State(total: 250, paid: false)
        let (newState, output) = try PMFulfillmentPM.reactions[1].handle(currentState, recorded)

        #expect(newState == PMFulfillmentPM.State(total: 250, paid: true))
        #expect(output.count == 1)
        #expect((output[0] as? PMFulfillmentEvent) == PMFulfillmentEvent.shipmentRequested(orderId: "order-1"))
    }

    @Test func reactionAppliesPaymentFailedWithNoOutput() throws {
        let event = PMPaymentEvent.failed(orderId: "order-1", reason: "Insufficient funds")
        let data = try JSONEncoder().encode(event)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "payment", id: "order-1"),
            position: 0,
            globalPosition: 0,
            eventType: "PaymentFailed",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let currentState = PMFulfillmentPM.State(total: 250, paid: false)
        let (newState, output) = try PMFulfillmentPM.reactions[1].handle(currentState, recorded)

        #expect(newState == PMFulfillmentPM.State(total: 250, paid: false))
        #expect(output.isEmpty)
    }
}
```

**Step 2: Replace ProcessManager.swift**

Replace the entire contents of `Sources/Songbird/ProcessManager.swift` with:

```swift
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
```

**Step 3: Build and test**

```bash
swift build 2>&1
swift test 2>&1
```

**Commit message:**

```
Replace ProcessManager protocol with reaction-based design

Replace the Phase 1 ProcessManager stub (InputEvent, OutputCommand,
apply, commands) with the new protocol shape (processId, initialState,
reactions). Add reaction(for:categories:) registration helper that
bridges typed EventReaction conformances into two-phase AnyReaction
type erasure. Rewrite all ProcessManager tests with a realistic order
fulfillment example.
```

---

### Task 3: ProcessManagerRunner (ATOMIC)

The runner is an actor that subscribes to all categories from the PM's reactions, dispatches each event through the two-phase AnyReaction flow, manages per-entity state, and appends output events to the store.

**Files:**
- Create: `Sources/Songbird/ProcessManagerRunner.swift`
- Create: `Tests/SongbirdTests/ProcessManagerRunnerTests.swift`

**Step 1: Write the tests**

Create `Tests/SongbirdTests/ProcessManagerRunnerTests.swift`:

```swift
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

/// Actor to safely collect events across task boundaries in tests.
private actor RunnerEventCollector {
    private(set) var events: [RecordedEvent] = []

    func append(_ event: RecordedEvent) {
        events.append(event)
    }

    var count: Int { events.count }
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
        #expect(decoded == RunnerFulfillmentEvent.paymentRequested(orderId: "order-1", amount: 100))

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
        #expect(decodedA == RunnerFulfillmentEvent.paymentRequested(orderId: "order-A", amount: 100))

        let decodedB = try outputB[0].decode(RunnerFulfillmentEvent.self).event
        #expect(decodedB == RunnerFulfillmentEvent.paymentRequested(orderId: "order-B", amount: 200))

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
        // Since InMemoryEventStore allows any event, we use a generic test event
        // in the "runner-order" category.
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
```

**Step 2: Create ProcessManagerRunner.swift**

Create `Sources/Songbird/ProcessManagerRunner.swift`:

```swift
/// An actor that runs a `ProcessManager` by subscribing to its declared categories,
/// dispatching events through the two-phase `AnyReaction` flow, managing per-entity state,
/// and appending output events to the event store.
///
/// The runner:
/// 1. Collects all categories from `PM.reactions` (deduplicating)
/// 2. Creates an `EventSubscription` for those categories
/// 3. For each incoming event, tries each reaction's `tryRoute` until one matches
/// 4. Looks up per-entity state from cache (or uses `PM.initialState`)
/// 5. Calls the matching reaction's `handle` to fold state and produce output events
/// 6. Appends output events to the store under `StreamName(category: PM.processId, id: route)`
/// 7. Updates the per-entity state cache
///
/// Only one reaction is applied per event (first match wins). Events that no reaction handles
/// are silently skipped. Decoding errors from `tryRoute` are silently skipped (the event type
/// matched by string but failed to decode, which may indicate a version mismatch or an event
/// from a different aggregate using the same category).
///
/// Usage:
/// ```swift
/// let runner = ProcessManagerRunner<FulfillmentPM>(
///     store: eventStore,
///     positionStore: positionStore
/// )
///
/// let task = Task { try await runner.run() }
///
/// // Later: cancel stops the subscription loop
/// task.cancel()
/// ```
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
    ) {
        self.store = store
        self.positionStore = positionStore
        self.batchSize = batchSize
        self.tickInterval = tickInterval
    }

    // MARK: - Lifecycle

    /// Starts the runner. This method blocks until the enclosing `Task` is cancelled.
    public func run() async throws {
        let allCategories = Array(Set(PM.reactions.flatMap(\.categories)))

        let subscription = EventSubscription(
            subscriberId: PM.processId,
            categories: allCategories,
            store: store,
            positionStore: positionStore,
            batchSize: batchSize,
            tickInterval: tickInterval
        )

        for try await event in subscription {
            try await processEvent(event)
        }
    }

    // MARK: - State Access

    /// Returns the current per-entity state for the given instance ID.
    /// Returns `PM.initialState` if no events have been processed for this entity.
    public func state(for instanceId: String) -> PM.State {
        stateCache[instanceId] ?? PM.initialState
    }

    // MARK: - Private

    private func processEvent(_ recorded: RecordedEvent) async throws {
        for reaction in PM.reactions {
            // Phase 1: Try to route the event
            let route: String?
            do {
                route = try reaction.tryRoute(recorded)
            } catch {
                // Decoding failed -- skip this reaction (event type matched by string
                // but the payload didn't match the expected type)
                continue
            }

            guard let route else { continue }

            // Phase 2: Look up state, apply, produce output
            let currentState = stateCache[route] ?? PM.initialState
            let (newState, output) = try reaction.handle(currentState, recorded)

            // Update state cache
            stateCache[route] = newState

            // Append output events
            let outputStream = StreamName(category: PM.processId, id: route)
            for event in output {
                _ = try await store.append(
                    event,
                    to: outputStream,
                    metadata: EventMetadata(),
                    expectedVersion: nil
                )
            }

            // First match wins -- stop trying other reactions
            break
        }
    }
}
```

**Step 3: Build and test**

```bash
swift build 2>&1
swift test 2>&1
```

**Commit message:**

```
Add ProcessManagerRunner actor for event-driven process execution

ProcessManagerRunner subscribes to all categories declared by a
ProcessManager's reactions, dispatches events through the two-phase
AnyReaction flow (tryRoute then handle), maintains per-entity state
in an in-memory cache, and appends output events to the store.
```

---

### Task 4: ProcessStateStream (ATOMIC)

A reactive `AsyncSequence` that yields the current state of a process manager entity, updating live as new events arrive. Follows the same pattern as `AggregateStateStream` but subscribes to multiple categories and filters by route matching the instance ID.

**Files:**
- Create: `Sources/Songbird/ProcessStateStream.swift`
- Create: `Tests/SongbirdTests/ProcessStateStreamTests.swift`

**Step 1: Write the tests**

Create `Tests/SongbirdTests/ProcessStateStreamTests.swift`:

```swift
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
            to: StreamName(category: "runner-order", id: "order-1"),
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
            to: StreamName(category: "runner-order", id: "order-1"),
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
            to: StreamName(category: "runner-payment", id: "order-1"),
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
            to: StreamName(category: "runner-order", id: "order-1"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Then append a real order event for this entity
        _ = try await store.append(
            RunnerOrderEvent.placed(orderId: "order-1", total: 500),
            to: StreamName(category: "runner-order", id: "order-1"),
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
```

**Step 2: Create ProcessStateStream.swift**

Create `Sources/Songbird/ProcessStateStream.swift`:

```swift
import Foundation

/// A reactive `AsyncSequence` that yields the current state of a process manager entity,
/// updating live as new events arrive across the PM's subscribed categories.
///
/// On the first iteration call, the stream reads all existing events from the PM's categories
/// (via `readCategories`), filters them by trying each reaction's `tryRoute` for the target
/// instance ID, folds matching events through the reaction's `apply`, and yields the resulting
/// state. If no matching events exist, `PM.initialState` is yielded. After the initial fold,
/// the stream polls for new events, applies matching ones, and yields the updated state for
/// each matching event.
///
/// The stream does not persist position -- it always folds from the beginning on creation.
/// This makes it suitable for live UI updates, in-memory caches, and reactive projections.
///
/// Usage:
/// ```swift
/// let stateStream = ProcessStateStream<FulfillmentPM>(
///     instanceId: "order-123",
///     store: eventStore
/// )
///
/// let task = Task {
///     for try await state in stateStream {
///         print("State: \(state)")
///     }
/// }
///
/// // Later: cancel stops the polling loop
/// task.cancel()
/// ```
public struct ProcessStateStream<PM: ProcessManager>: AsyncSequence, Sendable {
    public typealias Element = PM.State

    public let instanceId: String
    public let store: any EventStore
    public let batchSize: Int
    public let tickInterval: Duration

    public init(
        instanceId: String,
        store: any EventStore,
        batchSize: Int = 100,
        tickInterval: Duration = .milliseconds(100)
    ) {
        self.instanceId = instanceId
        self.store = store
        self.batchSize = batchSize
        self.tickInterval = tickInterval
    }

    public func makeAsyncIterator() -> Iterator {
        let allCategories = Array(Set(PM.reactions.flatMap(\.categories)))
        return Iterator(
            instanceId: instanceId,
            categories: allCategories,
            store: store,
            batchSize: batchSize,
            tickInterval: tickInterval
        )
    }

    public struct Iterator: AsyncIteratorProtocol {
        let instanceId: String
        let categories: [String]
        let store: any EventStore
        let batchSize: Int
        let tickInterval: Duration
        private var state: PM.State = PM.initialState
        private var globalPosition: Int64 = 0
        private var initialFoldDone: Bool = false

        init(
            instanceId: String,
            categories: [String],
            store: any EventStore,
            batchSize: Int,
            tickInterval: Duration
        ) {
            self.instanceId = instanceId
            self.categories = categories
            self.store = store
            self.batchSize = batchSize
            self.tickInterval = tickInterval
        }

        public mutating func next() async throws -> PM.State? {
            // Phase 1: Initial fold -- read all existing events and yield folded state
            if !initialFoldDone {
                initialFoldDone = true

                while true {
                    let batch = try await store.readCategories(
                        categories,
                        from: globalPosition,
                        maxCount: batchSize
                    )

                    for record in batch {
                        applyIfMatching(record)
                        globalPosition = record.globalPosition + 1
                    }

                    if batch.count < batchSize { break }
                }

                return state
            }

            // Phase 2: Poll for new events, yield state after each matching one
            while !Task.isCancelled {
                try Task.checkCancellation()

                let batch = try await store.readCategories(
                    categories,
                    from: globalPosition,
                    maxCount: batchSize
                )

                if !batch.isEmpty {
                    // Process all events in the batch, tracking whether any matched
                    for record in batch {
                        let matched = applyIfMatching(record)
                        globalPosition = record.globalPosition + 1
                        if matched {
                            return state
                        }
                    }
                    // No events in this batch matched our instance -- continue polling
                    continue
                }

                // Caught up -- sleep before polling again
                try await Task.sleep(for: tickInterval)
            }

            return nil  // cancelled
        }

        /// Tries each reaction's `tryRoute` for this event. If one matches the instance ID,
        /// applies the reaction's `handle` to fold state. Returns true if a match was found.
        @discardableResult
        private mutating func applyIfMatching(_ record: RecordedEvent) -> Bool {
            for reaction in PM.reactions {
                let route: String?
                do {
                    route = try reaction.tryRoute(record)
                } catch {
                    continue
                }

                guard route == instanceId else { continue }

                // This event is for our instance -- apply it
                do {
                    let (newState, _) = try reaction.handle(state, record)
                    state = newState
                } catch {
                    // Handle error silently -- event matched route but failed to process.
                    // This could happen if the event payload is corrupted.
                }

                return true
            }
            return false
        }
    }
}
```

**Step 3: Build and test**

```bash
swift build 2>&1
swift test 2>&1
```

**Commit message:**

```
Add ProcessStateStream for reactive process manager state observation

ProcessStateStream is an AsyncSequence that yields the per-entity
state of a process manager, updating live as new events arrive. It
subscribes to all PM categories, filters by route matching the
instance ID, and folds through matching reactions.
```

---

### Task 5: Final review, changelog, push

1. Run full clean build and test suite:

```bash
swift package clean && swift build 2>&1
swift test 2>&1
```

2. Verify zero warnings and all tests pass.

3. Create changelog entry `changelog/0008-process-manager-runtime.md`:

```markdown
# 0008 -- Process Manager Runtime

Implemented Phase 7 of Songbird:

**EventReaction protocol:**
- Typed per-event-type handlers with 3 required methods (`eventTypes`, `route`, `apply`)
- Default implementations for `decode` (JSON via `RecordedEvent.decode`) and `react` (empty)
- Override `react` to produce output events, override `decode` for event versioning

**AnyReaction type erasure:**
- Two-phase design separating routing (`tryRoute`) from handling (`handle`)
- Solves the chicken-and-egg problem: route is needed to look up per-entity state before handle
- Event is decoded twice (once per phase) -- acceptable tradeoff for clean separation

**ProcessManager protocol (redesigned):**
- Replaces Phase 1 stub (`InputEvent`, `OutputCommand`, `apply`, `commands`)
- New shape: `processId`, `initialState`, `reactions: [AnyReaction<State>]`
- `reaction(for:categories:)` helper bridges `EventReaction` into `AnyReaction`
- Output is events (not commands) for pure event choreography

**ProcessManagerRunner actor:**
- Subscribes to all categories from PM reactions via `EventSubscription`
- Two-phase dispatch: `tryRoute` for routing, `handle` for state + output
- Per-entity state cache with `state(for:)` accessor
- Appends output events to `StreamName(category: PM.processId, id: instanceId)`
- First-match-wins for reaction dispatch, silent skip on decode errors

**ProcessStateStream:**
- Reactive `AsyncSequence<PM.State>` for a specific entity instance
- Subscribes to PM categories, filters by route matching instance ID
- Folds through matching reactions, yields state on each change
- Same pattern as `AggregateStateStream` but multi-category + reaction-based
```

4. Commit and push:

```bash
git add -A
git commit -m "Add process manager runtime (Phase 7)"
git push
```

**Commit message:**

```
Add process manager runtime (Phase 7)

Implement EventReaction protocol, AnyReaction two-phase type erasure,
ProcessManagerRunner actor, and ProcessStateStream. Replaces the
Phase 1 ProcessManager stub with a full runtime supporting typed
per-event-type handlers, per-entity state management, and reactive
state observation.
```
