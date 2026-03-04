# Event Versioning Design

**Date:** 2026-03-04
**Status:** Approved

## Problem

Event schemas are immutable (Hoffman's Law 8). Any change to an event schema must produce a new event type. The framework needs a way to define versioned events, register upcasting transforms between versions, and transparently serve the latest version when reading old events from the store.

## Solution

Add `static var version: Int` to the `Event` protocol (defaulting to 1). An `EventUpcast` protocol defines pure transforms between consecutive versions. The `EventTypeRegistry` gains a `registerUpcast` method that builds a chain of transforms. `decode()` automatically applies the chain, returning the latest version transparently.

## Approach

Registry-based upcasting on read. Old events stay as-is in the store. The registry decodes the stored JSON to the original version, walks the upcast chain, and returns the latest version. Aggregates, projectors, and process managers that use the registry get upcasting for free.

## Components

### 1. Event Protocol Update

```swift
public protocol Event: Message {
    var eventType: String { get }
    static var version: Int { get }
}

extension Event {
    public var messageType: String { eventType }
    public static var version: Int { 1 }
}
```

All existing events keep working — they're implicitly version 1. Versioned events override:

```swift
struct OrderPlaced_v1: Event {
    var eventType: String { "OrderPlaced_v1" }
    static let version = 1
    let itemId: String
}

struct OrderPlaced_v2: Event {
    var eventType: String { "OrderPlaced_v2" }
    static let version = 2
    let itemId: String
    let quantity: Int  // new field
}
```

### 2. EventUpcast Protocol

```swift
public protocol EventUpcast<OldEvent, NewEvent>: Sendable {
    associatedtype OldEvent: Event
    associatedtype NewEvent: Event
    func upcast(_ old: OldEvent) -> NewEvent
}
```

Each upcast handles one version step (v1 → v2). Pure function, no side effects, no async.

### 3. EventTypeRegistry Changes

New registration method:

```swift
registry.registerUpcast(
    from: OrderPlaced_v1.self,
    to: OrderPlaced_v2.self,
    upcast: OrderPlacedUpcast_v1_v2()
)
```

`registerUpcast` does three things:
1. Registers a decoder for the old event type string
2. Stores the upcast function in a chain keyed by the old event type
3. Validates that `NewEvent.version == OldEvent.version + 1`

`decode()` on read:
1. Decode JSON to the stored version
2. Walk the upcast chain until no more upcasts exist
3. Return the latest version as `any Event`

The existing `register()` method continues to work for events with no prior versions.

### 4. Impact on Existing Components

- **AggregateRepository** — no changes. Already calls `registry.decode()`.
- **Projectors** — no framework changes. Use registry for upcasting.
- **Process Managers** — existing `EventReaction.decode()` override hook covers this.
- **Event Store** — no changes. Stores raw JSON, upcasting is on read.
- **Test harnesses** — no changes needed.

## Non-Goals

- Downcasting (new → old) — projections are rebuilt from scratch
- Automatic schema diffing — upcasts are hand-written
- Event store migration — old events stay as-is, upcasting is on read
