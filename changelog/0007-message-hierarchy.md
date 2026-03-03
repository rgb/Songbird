# 0007 — Message Hierarchy, Store Generalization & Reactive Streams

Implemented Phase 6 of Songbird:

**Message protocol hierarchy:**
- **Message** — Base protocol (`Sendable`, `Codable`, `Equatable`, `messageType`)
- **Event: Message** — `messageType` delegates to `eventType`
- **Command: Message** — `commandType` changed from static to instance, gains `Codable` + `Equatable`
- Events are stored in the EventStore; commands remain ephemeral (sync path only)

**EventStore generalization:**
- `readCategory` replaced with `readCategories(_ categories: [String], ...)` — single protocol requirement
- Convenience extensions: `readCategory` (single), `readAll` (empty = all events)
- InMemoryEventStore: Set-based category filter
- SQLiteEventStore: dynamic SQL with WHERE IN, index-backed

**Subscription generalization:**
- `CategorySubscription` renamed to **EventSubscription** — accepts `categories: [String]`
- New **StreamSubscription** — entity-level `AsyncSequence<RecordedEvent>` for a specific `StreamName`, no position persistence, for reactive use

**Reactive state streams:**
- **AggregateStateStream\<A\>** — `AsyncSequence<A.State>` for real-time observation of an aggregate
  - Folds existing events, yields initial state, polls for new events, yields updated state
  - Enables WebSocket/gRPC push for live state updates

30 new tests. 146 tests total across 23 suites, all passing, zero warnings.
