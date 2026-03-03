# Phase 3: Aggregate Execution -- Design

## Summary

Implement AggregateRepository and CommandHandler protocol for loading aggregate state and executing commands. Also includes a breaking change to the Event protocol (static -> instance eventType) to support enum-based events.

## Breaking Change: Event Protocol

The `Event` protocol's `eventType` changes from a static property to an instance property. This enables enum events with per-case event type strings.

```swift
// Before
public protocol Event: Sendable, Codable, Equatable {
    static var eventType: String { get }
}

// After
public protocol Event: Sendable, Codable, Equatable {
    var eventType: String { get }
}
```

All existing code that uses `type(of: event).eventType` or `E.eventType` must change to `event.eventType`.

## Event Definition Pattern

Events are now enums with per-case associated values:

```swift
enum OrderEvent: Event {
    case placed(itemId: String)
    case cancelled(reason: String)

    var eventType: String {
        switch self {
        case .placed: "OrderPlaced"
        case .cancelled: "OrderCancelled"
        }
    }
}
```

## Registry API Change

The `EventTypeRegistry.register` method changes to accept multiple eventType strings per type (since all cases of an enum decode with the same Codable decoder):

```swift
public func register<E: Event>(_ type: E.Type, eventTypes: [String])
```

The old single-type `register` is removed.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Event representation | Enums with per-case eventType | Natural fit for Swift aggregates, exhaustive switch, single type for associated type |
| eventType | Instance property (not static) | Per-case discrimination for enum events |
| Command handling | CommandHandler protocol | Formal, discoverable, type-safe. One handler per command-aggregate pair. |
| CommandHandler return type | `[Agg.Event]` | Fully typed. All events from a handler belong to the same aggregate. |
| Aggregate.Event constraint | Keeps `Songbird.Event` | No relaxation needed since enum events conform to Event directly. |
| decodeEvent | Not needed | The registry handles decoding. The aggregate's Event IS a Songbird.Event. |

## Types

### CommandHandler Protocol

```swift
public protocol CommandHandler {
    associatedtype Agg: Aggregate
    associatedtype Cmd: Command

    static func handle(
        _ command: Cmd,
        given state: Agg.State
    ) throws(Agg.Failure) -> [Agg.Event]
}
```

### AggregateRepository

```swift
public struct AggregateRepository<A: Aggregate>: Sendable {
    public let store: any EventStore
    public let registry: EventTypeRegistry

    public init(store: any EventStore, registry: EventTypeRegistry)

    public func load(id: String) async throws -> (state: A.State, version: Int64)

    public func execute<H: CommandHandler>(
        _ command: H.Cmd,
        on id: String,
        metadata: EventMetadata,
        using handler: H.Type
    ) async throws -> [RecordedEvent] where H.Agg == A
}
```

`load`:
1. Constructs `StreamName(category: A.category, id: id)`
2. Reads all events from the stream
3. Decodes each via registry, casts to `A.Event`
4. Folds through `A.apply` from `A.initialState`
5. Returns `(state, version)` where version is the last event's position or -1

`execute`:
1. Calls `load(id:)` to get current state + version
2. Calls `H.handle(command, given: state)` to get new events
3. Appends each event to the stream with `expectedVersion: version` (first event) then `nil` (subsequent)
4. Returns the recorded events

### AggregateError

```swift
public enum AggregateError: Error {
    case unexpectedEventType(String)
}
```

Thrown when the registry returns an event that can't be cast to the aggregate's Event type.

## Ripple Effects (Phase 1 & 2 updates)

### Files to modify:

- `Sources/Songbird/Event.swift` -- `static var eventType` -> `var eventType`
- `Sources/Songbird/EventTypeRegistry.swift` -- new register API with eventTypes array
- `Sources/SongbirdTesting/InMemoryEventStore.swift` -- `type(of: event).eventType` -> `event.eventType`
- `Sources/SongbirdSQLite/SQLiteEventStore.swift` -- same
- All test files -- update test event types from structs to enums (or add `var eventType`)

### Files to create:

- `Sources/Songbird/CommandHandler.swift`
- `Sources/Songbird/AggregateRepository.swift`
- `Tests/SongbirdTests/CommandHandlerTests.swift`
- `Tests/SongbirdTests/AggregateRepositoryTests.swift`

### Package.swift change:

- `SongbirdTests` needs to depend on `SongbirdTesting` (for InMemoryEventStore in tests)
