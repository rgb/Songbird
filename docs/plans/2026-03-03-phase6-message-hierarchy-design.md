# Phase 6: Message Hierarchy, Store Generalization & Reactive Streams -- Design

## Summary

Introduce the `Message` base protocol, generalize EventStore reads to multi-category, expand subscriptions (EventSubscription + StreamSubscription), and add reactive aggregate state streams. Commands gain Codable + Equatable from the Message base but remain ephemeral (not stored). The EventStore stores only events.

## Part 1: Message Protocol Hierarchy

```swift
public protocol Message: Sendable, Codable, Equatable {
    var messageType: String { get }
}

public protocol Event: Message {
    var eventType: String { get }
}

extension Event {
    public var messageType: String { eventType }
}

public protocol Command: Message {
    var commandType: String { get }  // was: static var commandType: String
}

extension Command {
    public var messageType: String { commandType }
}
```

Changes to existing code:
- New file: `Sources/Songbird/Message.swift` with the `Message` protocol
- `Event.swift`: `Event` extends `Message`, remove `Sendable, Codable, Equatable` (inherited from Message)
- `Command.swift`: `Command` extends `Message`, add `Codable, Equatable` (from Message), change `static var commandType` to `var commandType` (instance)
- All existing Command conformances update from `static let commandType` to `var commandType { "..." }`
- Existing Event conformances unchanged (they already have instance `var eventType`)

## Part 2: EventStore Generalization

Replace `readCategory` with `readCategories`:

```swift
// Protocol requirement
func readCategories(
    _ categories: [String],
    from globalPosition: Int64,
    maxCount: Int
) async throws -> [RecordedEvent]

// Convenience extensions (no implementation needed)
extension EventStore {
    func readCategory(_ category: String, from globalPosition: Int64, maxCount: Int) async throws -> [RecordedEvent] {
        try await readCategories([category], from: globalPosition, maxCount: maxCount)
    }

    func readAll(from globalPosition: Int64, maxCount: Int) async throws -> [RecordedEvent] {
        try await readCategories([], from: globalPosition, maxCount: maxCount)
    }
}
```

InMemoryEventStore: Set-based filter, empty set = no filter.
SQLiteEventStore: Dynamic SQL -- no WHERE for empty, single WHERE for one, WHERE IN for multiple. All index-backed via `idx_events_category`.

## Part 3: Subscription Generalization

### Rename CategorySubscription → EventSubscription

- `category: String` → `categories: [String]`
- Uses `readCategories` internally
- Empty = all events, single = one category, multiple = multi-category
- Position-tracked via PositionStore (unchanged)

### New StreamSubscription

```swift
public struct StreamSubscription: AsyncSequence, Sendable {
    public typealias Element = RecordedEvent

    public init(
        stream: StreamName,
        store: any EventStore,
        startPosition: Int64 = 0,
        batchSize: Int = 100,
        tickInterval: Duration = .milliseconds(100)
    )
}
```

Polls `readStream` for a specific entity stream. No position persistence (for reactive use). Starts from a given position (default 0). Cooperative cancellation.

## Part 4: Reactive Aggregate State Stream

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
1. Read all events from entity stream, decode via registry, fold through `A.apply`
2. Yield initial state (even if no events -- yields `A.initialState`)
3. Poll for new events from `lastPosition + 1`
4. On each new event: decode, apply, yield updated state
5. Sleep when caught up, cooperative cancellation

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Message base protocol | Yes | Unifies Event + Command type hierarchy, shared Sendable/Codable/Equatable |
| Store stores only events | Yes | Commands are ephemeral (sync path). PM produces events, not commands. Clean event log. |
| Command.commandType | Instance (was static) | Mirrors Event.eventType. Consistent with Message.messageType. |
| readCategories | Single method with [String] | One protocol requirement, index-backed, convenience extensions |
| StreamSubscription | No position persistence | For reactive streams that fold from start. Different from EventSubscription. |
| AggregateStateStream yields initial state | Yes | Consumer always gets at least one value, even for empty streams |

## File Changes

**New files:**
- `Sources/Songbird/Message.swift`
- `Sources/Songbird/StreamSubscription.swift`
- `Sources/Songbird/AggregateStateStream.swift`
- `Tests/SongbirdTests/StreamSubscriptionTests.swift`
- `Tests/SongbirdTests/AggregateStateStreamTests.swift`

**Renamed files:**
- `Sources/Songbird/CategorySubscription.swift` → `Sources/Songbird/EventSubscription.swift`
- `Tests/SongbirdTests/CategorySubscriptionTests.swift` → `Tests/SongbirdTests/EventSubscriptionTests.swift`

**Modified files:**
- `Sources/Songbird/Event.swift` -- Event extends Message
- `Sources/Songbird/Command.swift` -- Command extends Message, instance commandType
- `Sources/Songbird/EventStore.swift` -- readCategory → readCategories + convenience extensions
- `Sources/SongbirdTesting/InMemoryEventStore.swift` -- implement readCategories
- `Sources/SongbirdSQLite/SQLiteEventStore.swift` -- implement readCategories with dynamic SQL
- `Tests/SongbirdTests/CommandTests.swift` -- update command conformance
- `Tests/SongbirdTests/ProcessManagerTests.swift` -- update command conformance
- `Tests/SongbirdTests/AggregateRepositoryTests.swift` -- update command conformance
- `Tests/SongbirdTestingTests/InMemoryEventStoreTests.swift` -- add readCategories/readAll tests
- `Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift` -- add readCategories/readAll tests
