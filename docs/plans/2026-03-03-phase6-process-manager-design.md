# Phase 6: Reactive Streams & Process Manager Runtime -- Design

## Summary

A three-part phase that builds bottom-up: (1) generalize the EventStore and subscription APIs, (2) add reactive state streams for aggregates, (3) implement per-entity process managers with reactive state observation.

## Part 1: Foundation Changes

### EventStore Protocol Change

Replace `readCategory` with a generalized `readCategories`:

```swift
// Protocol requirement (one method, always index-backed)
func readCategories(
    _ categories: [String],
    from globalPosition: Int64,
    maxCount: Int
) async throws -> [RecordedEvent]
```

Where:
- `[]` → no filter, reads all events
- `["order"]` → single category (`WHERE stream_category = ?`)
- `["order", "inventory"]` → multi-category (`WHERE stream_category IN (?, ?)`)

Convenience extensions (free, no implementation needed):

```swift
extension EventStore {
    func readCategory(_ category: String, from: Int64, maxCount: Int) async throws -> [RecordedEvent]
    func readAll(from globalPosition: Int64, maxCount: Int) async throws -> [RecordedEvent]
}
```

Implementors implement one method. Users get three readable call sites.

### Rename CategorySubscription → EventSubscription

Accept `categories: [String]` instead of `category: String`. Uses `readCategories` internally. Position-tracked via PositionStore.

### New StreamSubscription

`AsyncSequence<RecordedEvent>` for a specific `StreamName`. No position persistence. Uses `readStream` + polling. For reactive state streams.

```swift
public struct StreamSubscription: AsyncSequence, Sendable {
    public typealias Element = RecordedEvent

    public init(
        stream: StreamName,
        store: any EventStore,
        tickInterval: Duration = .milliseconds(100)
    )
}
```

## Part 2: Reactive State Streams

### AggregateStateStream

```swift
public struct AggregateStateStream<A: Aggregate>: AsyncSequence, Sendable {
    public typealias Element = A.State

    public init(
        id: String,
        store: any EventStore,
        registry: EventTypeRegistry,
        tickInterval: Duration = .milliseconds(100)
    )
}
```

Iterator behavior:
1. Read all events from entity stream, fold to initial state via `A.apply`
2. Yield initial state
3. Poll for new events via `readStream`
4. On each new event: decode, apply, yield updated state
5. Cooperative cancellation

## Part 3: Per-Entity Process Manager Runtime

### ProcessManager Protocol (adjusted)

```swift
public protocol ProcessManager {
    associatedtype State: Sendable
    associatedtype InputEvent: Event
    associatedtype OutputCommand: Command

    static var processId: String { get }
    static var initialState: State { get }
    static var categories: [String] { get }

    static func apply(_ state: State, _ event: InputEvent) -> State
    static func commands(_ state: State, _ event: InputEvent) -> [OutputCommand]
    static func route(_ event: RecordedEvent) -> String?
    static func decodeEvent(_ recorded: RecordedEvent) throws -> InputEvent
}
```

New requirements:
- `categories` -- which event categories this PM watches
- `route` -- extracts process instance ID from an event (nil = irrelevant)
- `decodeEvent` -- decodes RecordedEvent into PM's InputEvent

### ProcessManagerRunner

```swift
public actor ProcessManagerRunner<PM: ProcessManager> {
    public init(
        store: any EventStore,
        positionStore: any PositionStore,
        batchSize: Int = 100,
        tickInterval: Duration = .milliseconds(100)
    )

    public func run() async throws
    public func stop()
}
```

The `run()` loop:
1. Uses `EventSubscription(categories: PM.categories)` to poll for events
2. For each event: `PM.route(event)` → process instance ID (nil = skip)
3. Load PM state for that instance (fold from events matching that instance)
4. `PM.apply(state, decodedEvent)` → new state
5. `PM.commands(newState, decodedEvent)` → output commands
6. Append each command to the store
7. Cache updated state per instance

### ProcessStateStream

```swift
public struct ProcessStateStream<PM: ProcessManager>: AsyncSequence, Sendable {
    public typealias Element = PM.State

    public init(
        processInstanceId: String,
        store: any EventStore,
        registry: EventTypeRegistry,
        tickInterval: Duration = .milliseconds(100)
    )
}
```

Same pattern as `AggregateStateStream` but folds through `PM.apply`.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| readCategory → readCategories | Single method with [String] | One protocol requirement, always index-backed, convenience extensions for readability |
| Multi-category filtering | SQL-level (WHERE IN) | Uses existing index on stream_category, no read-all-then-filter |
| StreamSubscription | No position persistence | For reactive streams that fold from start + follow live |
| EventSubscription | Position-tracked (rename of CategorySubscription) | For background processing that survives restarts |
| PM state scope | Per-entity (Hoffman model) | Enables reactive state streams, natural for workflow tracking |
| PM event routing | `route(_:) -> String?` on protocol | PM knows how to correlate events to instances |
| PM state management | Fold from events + in-memory cache | Rebuild on restart, cache during run for performance |

## File Layout

```
Sources/Songbird/
├── EventStore.swift              (modify: readCategories + convenience extensions)
├── EventSubscription.swift       (rename from CategorySubscription, generalize)
├── StreamSubscription.swift      (new)
├── AggregateStateStream.swift    (new)
├── ProcessManager.swift          (modify: add categories, route, decodeEvent)
├── ProcessManagerRunner.swift    (new)
├── ProcessStateStream.swift      (new)
```

## Ripple Effects

- `CategorySubscription.swift` → renamed to `EventSubscription.swift`
- `CategorySubscriptionTests.swift` → renamed to `EventSubscriptionTests.swift`
- All tests using `readCategory` update to use convenience extension (no code change needed since we provide the extension)
- `InMemoryEventStore` and `SQLiteEventStore`: replace `readCategory` implementation with `readCategories`
- `ProcessManagerTests.swift`: update test PM to include new protocol requirements
