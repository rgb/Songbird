# 0004 — Aggregate Execution

Implemented Phase 3 of Songbird:

**Breaking change:**
- `Event.eventType` changed from `static var` to instance `var` — enables enum-based events with per-case event type strings
- `EventTypeRegistry.register` now takes an explicit `eventTypes: [String]` array for multi-case enum events

**New types:**
- **CommandHandler** — Protocol for typed command validation: command + state -> events, with typed throws
- **AggregateRepository\<A\>** — Loads aggregate state by folding events, executes commands with optimistic concurrency
- **AggregateError** — Error type for unexpected event types during loading

**Event pattern change:**
Events are now defined as enums with per-case associated values and computed `eventType`:
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

85 tests across 16 suites, all passing, zero warnings.
