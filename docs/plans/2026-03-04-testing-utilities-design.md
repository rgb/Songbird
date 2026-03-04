# Testing Utilities Design

**Date:** 2026-03-04
**Status:** Approved

## Problem

Test files across Songbird duplicate common patterns: constructing `RecordedEvent` with manual JSON encoding, defining ad-hoc projectors, and manually folding events through aggregates. This boilerplate obscures test intent and makes tests brittle to protocol changes.

## Solution

Add 7 components to the `SongbirdTesting` module — a convenience initializer, 3 reusable test projectors, and 3 type-safe harnesses — then refactor existing tests to use them.

## Components

### 1. RecordedEvent Convenience Initializer

A `RecordedEvent.init(event:...)` initializer that accepts any typed `Event`, JSON-encodes it automatically, and provides sensible defaults for all metadata fields.

```swift
extension RecordedEvent {
    public init<E: Event>(
        event: E,
        id: UUID = UUID(),
        streamName: StreamName = StreamName(category: "test", id: "1"),
        position: Int64 = 0,
        globalPosition: Int64 = 0,
        metadata: EventMetadata = EventMetadata(),
        timestamp: Date = Date()
    ) throws
}
```

Replaces the manual `Data("{}".utf8)` pattern and `makeRecordedEvent()` helpers scattered across test files.

### 2. RecordingProjector

Promoted from `ProjectionPipelineTests.swift` into `SongbirdTesting`. Records every event it receives.

```swift
public actor RecordingProjector: Projector {
    public let projectorId: String
    public private(set) var appliedEvents: [RecordedEvent]
    public init(id: String = "recording")
    public func apply(_ event: RecordedEvent) async throws
}
```

### 3. FilteringProjector

Promoted from `ProjectionPipelineTests.swift`. Records only events whose type is in the accepted set.

```swift
public actor FilteringProjector: Projector {
    public let projectorId: String
    public let acceptedTypes: Set<String>
    public private(set) var appliedEvents: [RecordedEvent]
    public init(acceptedTypes: Set<String>)
    public func apply(_ event: RecordedEvent) async throws
}
```

### 4. FailingProjector

Promoted from `ProjectionPipelineTests.swift`. Throws on a specific event type, records all others.

```swift
public actor FailingProjector: Projector {
    public let projectorId: String
    public let failOnType: String
    public private(set) var appliedEvents: [RecordedEvent]
    public init(failOnType: String)
    public func apply(_ event: RecordedEvent) async throws
}
```

### 5. TestAggregateHarness

A value-type harness for testing aggregates in isolation, without an event store or repository.

```swift
public struct TestAggregateHarness<A: Aggregate> {
    public private(set) var state: A.State
    public private(set) var version: Int64
    public private(set) var appliedEvents: [A.Event]

    public init(state: A.State = A.initialState)

    /// Feed events to fold into state.
    public mutating func given(_ events: A.Event...)
    public mutating func given(_ events: [A.Event])

    /// Execute a command handler and fold resulting events.
    public mutating func when<H: CommandHandler>(
        _ command: H.Cmd,
        using handler: H.Type
    ) throws -> [A.Event] where H.Agg == A

    /// Assert current state equals expected.
    public func then(state expected: A.State, sourceLocation: SourceLocation)
}
```

Key design decisions:
- Value type (`struct`) with `mutating` methods — no actor overhead, no async
- `appliedEvents` accumulates all events from both `given` and `when` calls
- `version` tracks the number of events applied (starts at -1, increments per event)
- `then` uses `SourceLocation` for correct failure location in test output

### 6. TestProjectorHarness

Wraps any `Projector` and feeds it typed events (auto-encoded via the RecordedEvent convenience init), with incrementing global positions.

```swift
public struct TestProjectorHarness<P: Projector> {
    public let projector: P
    public private(set) var globalPosition: Int64

    public init(projector: P)

    /// Feed a typed event to the projector.
    public mutating func given<E: Event>(
        _ event: E,
        streamName: StreamName = StreamName(category: "test", id: "1"),
        metadata: EventMetadata = EventMetadata()
    ) async throws
}
```

### 7. TestProcessManagerHarness

A value-type harness for testing process managers in isolation, without an event store or runner.

```swift
public struct TestProcessManagerHarness<PM: ProcessManager> {
    public private(set) var states: [String: PM.State]
    public private(set) var output: [any Event]

    public init()

    /// Feed a recorded event through the process manager's reactions.
    public mutating func given(_ event: RecordedEvent) throws

    /// Feed a typed event (auto-encoded) through the reactions.
    public mutating func given<E: Event>(
        _ event: E,
        streamName: StreamName,
        metadata: EventMetadata = EventMetadata()
    ) throws

    /// Get per-entity state.
    public func state(for instanceId: String) -> PM.State
}
```

Key design decisions:
- Value type — no actor overhead, no async (reactions are synchronous)
- `states` dictionary tracks per-entity state keyed by route
- `output` accumulates all emitted events across all `given` calls
- Routes events through `AnyReaction.tryRoute` then `AnyReaction.handle`, matching `ProcessManagerRunner` logic

## Refactoring Plan

After implementing the utilities:

1. **ProjectionPipelineTests.swift** — Remove `RecordingProjector`, `FilteringProjector`, `FailingProjector`, `ProjectorTestError`, and `makeRecordedEvent()`. Import from `SongbirdTesting`.
2. **Other test files** — Replace manual `RecordedEvent` construction with the convenience initializer where applicable.
3. **AggregateRepositoryTests.swift** — Consider using `TestAggregateHarness` for pure aggregate logic tests (but keep repository-level tests that exercise the store).

## Non-Goals

- No `TestEventStore` — `InMemoryEventStore` already serves this purpose
- No `TestProjectionStore` — not needed until Phase 4 (Smew/DuckDB read model)
- No async harnesses — keep harnesses synchronous and value-typed for simplicity
