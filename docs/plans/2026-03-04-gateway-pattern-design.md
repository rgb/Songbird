# Gateway Pattern (Notifier) Design

**Date:** 2026-03-04
**Status:** Approved

## Problem

Songbird has a stub `Gateway` protocol but no runtime to execute it. Gateways (notifiers) need subscription-based event delivery with position tracking for at-least-once delivery of outbound side effects (email, webhooks, API calls). The existing `ProcessManagerRunner` pattern proves this works, but gateways are simpler — no per-entity state, no output events.

## Solution

A `GatewayRunner` actor that subscribes to declared categories via `EventSubscription`, calling `gateway.handle(event)` for each event. Pull-based delivery with independent position tracking per gateway. Integration with `SongbirdServices` via the existing `Runnable` pattern.

## Approach

Following both reference books: Garofolo's polling-based subscriptions for reliability, Hoffman's strict gateway boundary for side effects. Notifier only — Injector (inbound) deferred as a fundamentally different pattern.

## Components

### 1. Gateway Protocol Update

Add `static var categories: [String]` to declare subscription scope. Empty array means all events.

```swift
public protocol Gateway: Sendable {
    var gatewayId: String { get }
    static var categories: [String] { get }
    func handle(_ event: RecordedEvent) async throws
}
```

### 2. GatewayRunner

Actor that mirrors `ProcessManagerRunner` but simpler. Subscription loop calling `handle()` per event.

```swift
public actor GatewayRunner<G: Gateway> {
    private let gateway: G
    private let store: any EventStore
    private let positionStore: any PositionStore
    private let batchSize: Int
    private let tickInterval: Duration

    public init(
        gateway: G,
        store: any EventStore,
        positionStore: any PositionStore,
        batchSize: Int = 100,
        tickInterval: Duration = .milliseconds(100)
    )

    public func run() async throws {
        // EventSubscription with subscriberId: gateway.gatewayId, categories: G.categories
        // For each event: try await gateway.handle(event)
        // Errors logged but don't stop the loop
    }
}
```

Key decisions:
- Takes a gateway instance (not type) — gateways have instance state for side effects
- Error swallowing — failing handle() doesn't stop the subscription (matches ProjectionPipeline)
- Cancellation — EventSubscription exits on task cancellation

### 3. SongbirdServices Integration

Reuses the existing `Runnable` protocol. No changes to `run()`.

```swift
extension GatewayRunner: Runnable {}

// On SongbirdServices:
public mutating func registerGateway<G: Gateway>(
    _ gateway: G,
    batchSize: Int = 100,
    tickInterval: Duration = .milliseconds(100)
)
```

### 4. TestGatewayHarness

Test utility for feeding events to a gateway in isolation.

```swift
public struct TestGatewayHarness<G: Gateway> {
    public let gateway: G
    public private(set) var processedEvents: [RecordedEvent]
    public private(set) var errors: [(RecordedEvent, any Error)]

    public mutating func given(_ event: RecordedEvent) async
}
```

- Does not throw from `given()` — captures errors for assertion
- No subscription machinery — tests handle logic only

## Non-Goals

- Injector protocol (inbound external events — deferred)
- Retry/dead-letter logic (gateway's internal responsibility)
- Push-based enqueue from write path
