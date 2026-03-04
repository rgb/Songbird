# Injector Pattern Design

**Date:** 2026-03-04
**Status:** Approved

## Problem

Songbird has the outbound Gateway (Notifier) pattern but no inbound equivalent. Hoffman's law requires all external interaction to go through gateways — injectors for inbound, notifiers for outbound. Long-lived inbound sources (polling external APIs, consuming message queues, scheduled events) need a structured way to translate external data into domain events and append them to the store.

## Solution

An `Injector` protocol that produces an `AsyncSequence<InboundEvent>` of translated domain events. An `InjectorRunner` actor consumes the sequence and appends each event to the store, calling a `didAppend` callback so the injector can track its cursor and handle errors. Integration with `SongbirdServices` via the existing `Runnable` pattern.

## Approach

AsyncSequence-based protocol for long-lived injectors. Request-driven inbound data (webhooks) stays Garofolo-style — direct `eventStore.append()` in the route handler, no protocol needed. The injector controls its own polling rhythm, error handling, and cursor persistence. The runner is a thin bridge between the injector's sequence and the event store.

## Components

### 1. InboundEvent

A struct wrapping the three things the store needs to append.

```swift
public struct InboundEvent: Sendable {
    public let event: any Event
    public let stream: StreamName
    public let metadata: EventMetadata
}
```

### 2. Injector Protocol

```swift
public protocol Injector: Sendable {
    var injectorId: String { get }
    func events() -> any AsyncSequence<InboundEvent, any Error>
    func didAppend(_ event: InboundEvent, result: Result<RecordedEvent, any Error>) async
}
```

- `events()` returns the async sequence the runner consumes
- `didAppend` is called after each append attempt — the injector advances its cursor on `.success`, handles `.failure` as it sees fit
- Sequential processing means callback order matches yield order

### 3. InjectorRunner

```swift
public actor InjectorRunner<I: Injector> {
    private let injector: I
    private let store: any EventStore

    public init(injector: I, store: any EventStore)

    public func run() async throws {
        for try await inbound in injector.events() {
            let result: Result<RecordedEvent, any Error>
            do {
                let recorded = try await store.append(
                    inbound.event,
                    to: inbound.stream,
                    metadata: inbound.metadata,
                    expectedVersion: nil
                )
                result = .success(recorded)
            } catch {
                result = .failure(error)
            }
            await injector.didAppend(inbound, result: result)
        }
    }
}
```

Key differences from `GatewayRunner`:
- No `PositionStore` — the injector tracks its own cursor via `didAppend`
- No `EventSubscription` — reads from the injector's sequence, not the event store
- No `batchSize`/`tickInterval` — the injector controls its own polling rhythm
- Always `expectedVersion: nil` — injectors append unconditionally
- Errors passed to `didAppend` instead of swallowed silently

### 4. SongbirdServices Integration

```swift
extension InjectorRunner: Runnable {}

// On SongbirdServices:
public mutating func registerInjector<I: Injector>(
    _ injector: I
)
```

Simpler than `registerGateway` — no batch/tick/position parameters.

### 5. TestInjectorHarness

```swift
public struct TestInjectorHarness<I: Injector> {
    public let injector: I

    public init(injector: I, store: InMemoryEventStore = InMemoryEventStore())

    public func run() async throws -> [RecordedEvent]
}
```

Runs the injector against an `InMemoryEventStore` and returns all appended events. Different from `TestGatewayHarness` because the injector produces events rather than receiving them.

## Non-Goals

- Request-driven inbound data (webhooks) — use direct `eventStore.append()` in route handlers
- Generic state/cursor persistence — injector's responsibility
- Retry/dead-letter logic — injector's responsibility
