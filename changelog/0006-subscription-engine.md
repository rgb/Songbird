# 0006 — Subscription Engine

Implemented Phase 5 of Songbird:

- **PositionStore** — Protocol for persisting subscriber positions (simple load/save key-value)
- **CategorySubscription** — Polling-based subscription exposed as a flat `AsyncSequence<RecordedEvent>`. Transparent batching and position persistence behind the `AsyncIteratorProtocol`. Consumers iterate with `for try await event in subscription`.
  - Loads position from PositionStore on first iteration
  - Fetches events in configurable batches via `EventStore.readCategory`
  - Yields events one by one; saves position after each batch is fully consumed
  - Sleeps for configurable tick interval when caught up
  - Cooperative cancellation via Task.isCancelled / Task.checkCancellation
- **InMemoryPositionStore** — Actor-based position store for testing
- **SQLitePositionStore** — SQLite-backed position store with custom DispatchSerialQueue executor, UPSERT semantics, WAL mode

16 new tests (4 InMemoryPositionStore + 7 CategorySubscription + 5 SQLitePositionStore).
116 tests total across 20 suites, all passing, zero warnings.
