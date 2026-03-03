# Phase 1: Core Domain Types -- Design

## Summary

Define the fundamental protocols and types for the Songbird event sourcing framework. These types live in the `Songbird` module with zero external dependencies beyond Foundation. Everything else in the framework builds on these.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Event definition style | Protocol-based (each event is a struct) | Open for extension, plays well with generics and type registry. Users can group into enums per aggregate. |
| Foundation dependency | Yes | UUID and Date are ubiquitous. No reason to reinvent them. |
| Phase 1 scope | All core protocols including ProcessManager and Gateway stubs | Gives complete picture of framework shape upfront. |
| Stream identity | Structured `StreamName` type (category + optional ID) | Clean API, single concept for all operations. Follows Garofolo's convention. |
| Type erasure boundary | `RecordedEvent` with raw data | Store returns raw envelope; decoding to typed events happens outside the store. Clean separation. |
| CloudEvents | Export/projection only, not internal model | CloudEvents is for inter-system transport. Our model is optimized for event sourcing internals. Offer `CloudEventEncoder` at the gateway boundary later. |

## Types

### StreamName

```swift
public struct StreamName: Sendable, Hashable, Codable, CustomStringConvertible {
    public let category: String   // e.g. "order", "user"
    public let id: String?        // e.g. "abc-123" (nil = category stream)

    public init(category: String, id: String? = nil)

    // "order-abc123" for entity streams, "order" for category streams
    public var description: String
    public var isCategory: Bool
}
```

The separator between category and ID is `-` (first occurrence).

### Event

```swift
public protocol Event: Sendable, Codable, Equatable {
    static var eventType: String { get }
}
```

Events are immutable facts, named in past tense. Each event is its own type (struct or enum case). `eventType` is the discriminator string used for serialization/deserialization in the store.

### EventMetadata

```swift
public struct EventMetadata: Sendable, Codable, Equatable {
    public var traceId: String?        // correlates all events from one user action
    public var causationId: String?    // the specific event/command that caused this
    public var correlationId: String?  // links related event chains
    public var userId: String?

    public init(
        traceId: String? = nil,
        causationId: String? = nil,
        correlationId: String? = nil,
        userId: String? = nil
    )
}
```

Generic tracing fields only. Domain-specific context belongs in event payloads.

### RecordedEvent

```swift
public struct RecordedEvent: Sendable {
    public let id: UUID
    public let streamName: StreamName
    public let position: Int64         // position within this stream (0-based)
    public let globalPosition: Int64   // position across entire store
    public let eventType: String       // discriminator for decoding
    public let data: Data              // JSON-encoded event payload
    public let metadata: EventMetadata
    public let timestamp: Date

    public func decode<E: Event>(_ type: E.Type) throws -> EventEnvelope<E>
}
```

What the event store returns. Raw, not yet decoded. The `decode` method bridges to `EventEnvelope<E>`.

### EventEnvelope

```swift
public struct EventEnvelope<E: Event>: Sendable {
    public let id: UUID
    public let streamName: StreamName
    public let position: Int64
    public let globalPosition: Int64
    public let event: E
    public let metadata: EventMetadata
    public let timestamp: Date
}
```

Typed wrapper after decoding. What user code works with in aggregate loading and typed projectors.

### Command

```swift
public protocol Command: Sendable {
    static var commandType: String { get }
}
```

Imperative requests. Not `Codable` or `Equatable` by default -- typically created in route handlers and consumed immediately. Users add those conformances if they need to persist commands.

### Aggregate

```swift
public protocol Aggregate {
    associatedtype State: Sendable, Equatable
    associatedtype Event: Songbird.Event
    associatedtype Failure: Error

    static var category: String { get }       // stream category name
    static var initialState: State { get }
    static func apply(_ state: State, _ event: Event) -> State
}
```

- `apply` is static -- enforces purity. `(State, Event) -> State`, no side effects.
- `category` provides the stream category (e.g. `"order"`). Combined with entity ID, forms a `StreamName`.
- Command handling is **not** part of the protocol. Handlers are closures passed to `AggregateRepository.execute()`.

### Projector

```swift
public protocol Projector: Sendable {
    var projectorId: String { get }
    func apply(_ event: RecordedEvent) async throws
}
```

Takes `RecordedEvent` (not typed) because projectors subscribe to category streams with mixed event types. The implementation decodes events it cares about and ignores the rest.

### EventStore

```swift
public protocol EventStore: Sendable {
    func append(
        _ event: some Event,
        to stream: StreamName,
        metadata: EventMetadata,
        expectedVersion: Int64?
    ) async throws -> RecordedEvent

    func readStream(
        _ stream: StreamName,
        from position: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent]

    func readCategory(
        _ category: String,
        from globalPosition: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent]

    func readLastEvent(
        in stream: StreamName
    ) async throws -> RecordedEvent?

    func streamVersion(
        _ stream: StreamName
    ) async throws -> Int64
}
```

The store serializes events via `Codable` and returns `RecordedEvent`. `expectedVersion: nil` means no concurrency check. `append` returns the `RecordedEvent` with store-assigned fields.

### ProcessManager (stub for Phase 6)

```swift
public protocol ProcessManager {
    associatedtype State: Sendable
    associatedtype InputEvent: Event
    associatedtype OutputCommand: Command

    static var processId: String { get }
    static var initialState: State { get }
    static func apply(_ state: State, _ event: InputEvent) -> State
    static func commands(_ state: State, _ event: InputEvent) -> [OutputCommand]
}
```

Event-consuming, command-emitting state machine. One flow per manager.

### Gateway (stub for Phase 8)

```swift
public protocol Gateway: Sendable {
    var gatewayId: String { get }
    func handle(_ event: RecordedEvent) async throws
}
```

Boundary component for external side effects. Must be idempotent.

## Error Types

```swift
public struct VersionConflictError: Error {
    public let streamName: StreamName
    public let expectedVersion: Int64
    public let actualVersion: Int64
}
```

## File Layout

```
Sources/Songbird/
├── StreamName.swift
├── Event.swift           // Event protocol + EventMetadata + RecordedEvent + EventEnvelope
├── Command.swift
├── Aggregate.swift
├── Projector.swift
├── EventStore.swift      // EventStore protocol + VersionConflictError
├── ProcessManager.swift
└── Gateway.swift
```

## What This Does NOT Include

- No implementations (those come in Phase 2+)
- No event type registry (comes with EventStore implementations in Phase 2)
- No AggregateRepository (Phase 3)
- No ProjectionPipeline (Phase 4)
- No CloudEvents mapping (future gateway concern)
- No snapshot types (Phase 10)
