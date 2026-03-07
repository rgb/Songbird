# Code Review Remediation Round 10

Fixes from a 5-agent parallel code review covering all 7 modules — cancellation safety, precondition guards, concurrency correctness, resource leak prevention, visibility fixes, and test coverage.

## Cancellation & Safety

- **`InjectorRunner` CancellationError guard** — Added `catch is CancellationError` before the generic catch, matching the existing pattern in `GatewayRunner` and `ProcessManagerRunner`. Previously, task cancellation during `store.append` was silently treated as an append error instead of propagating.
- **`SnapshotPolicy.everyNEvents` guard** — Added `precondition(n > 0)` to prevent a division-by-zero trap when `.everyNEvents(0)` is passed.
- **`NotificationSignal.wait` cancellation-aware** — Wrapped `withCheckedContinuation` in `withTaskCancellationHandler` so subscription task cancellation takes effect immediately, rather than blocking for up to `fallbackPollInterval` (5s).

## Precondition Guards

- **`batchSize > 0` in all consumers** — Added preconditions to `EventSubscription`, `StreamSubscription`, `AggregateStateStream`, `ProcessStateStream`, and `AggregateRepository`. A `batchSize` of 0 causes infinite loops because `batch.count < batchSize` is never true.
- **`maxCount > 0` in PostgresEventStore** — Added preconditions to `readStream` and `readCategories`, matching the SQLite store (added in round 9).

## Concurrency & Safety

- **`SongbirdActorSystem.connect()` client leak** — Calling `connect()` twice for the same `processName` now disconnects the old `TransportClient` before replacing it, preventing NIO event loop thread leaks.
- **`LockedBox` Sendable constraints** — Changed `withLock` signature to `func withLock<R: Sendable>(_ body: @Sendable (inout T) -> R) -> R`, preventing non-sendable values from escaping the lock's protection.
- **`InvocationEncoder.arguments` visibility** — Changed from default `internal` to `private`, preventing module-internal code from bypassing the `recordArgument` API.

## Correctness & Consistency

- **`CryptoShreddingStore` prefer `piiReferenceKey`** — `decryptRecord` now prefers `record.metadata.piiReferenceKey` for key lookup, falling back to `streamName` derivation. The metadata field was set on append precisely for this purpose.
- **`corruptedRow` 0-based positions** — All `corruptedRow` error reports in `SQLiteEventStore.recordedEvent(from:)` now use 0-based `globalPosition` (matching the public API) instead of 1-based raw DB values.
- **SELECT column list extracted** — Replaced 5 duplicated 9-column SELECT lists with a `private static let eventColumns` constant.

## Performance & Configuration

- **`ProjectionFlushMiddleware` configurable timeout** — Added a `timeout: Duration` init parameter (default `.seconds(5)`) passed through to `pipeline.waitForIdle`. The `returnsResponseEvenWhenPipelineIsNotRunning` test now uses `.milliseconds(100)`, reducing test time from 5+ seconds to ~100ms.
- **`ReadModelStore.database` visibility** — Changed from `public` to `private`, preventing consumers from creating connections that bypass the actor's serial executor isolation.
- **`PostgresDefaults.fallbackPollInterval`** — Extracted the hardcoded `.seconds(5)` default into a named constant.

## Test Improvements

- **`voidReturningRemoteCallWorks`** — New test exercising `remoteCallVoid` end-to-end over a Unix socket with a `distributed func ping()`.
- **`throwingRemoteCallReturnsError`** — New test exercising the `WireMessage.error` wire path with a `distributed func` that throws a domain error.
- **`readStreamDataIsDecodable`** — New test verifying full event data and metadata round-trip through SQLite (append → readStream → decode).
- **`batchSizeOneDeliversAllEvents`** — New test exercising `StreamSubscription` with `batchSize: 1`, verifying all events are delivered correctly when every poll returns exactly one event.
- **`deleteKeyForNonExistentReferenceSucceeds`** — New test confirming `deleteKey` on a reference that never existed completes without error.

## Files Changed

- `Sources/Songbird/InjectorRunner.swift`
- `Sources/Songbird/AggregateRepository.swift`
- `Sources/Songbird/EventSubscription.swift`
- `Sources/Songbird/StreamSubscription.swift`
- `Sources/Songbird/AggregateStateStream.swift`
- `Sources/Songbird/ProcessStateStream.swift`
- `Sources/Songbird/CryptoShreddingStore.swift`
- `Sources/SongbirdSQLite/SQLiteEventStore.swift`
- `Sources/SongbirdPostgres/PostgresEventStore.swift`
- `Sources/SongbirdPostgres/PostgresEventSubscription.swift`
- `Sources/SongbirdDistributed/SongbirdActorSystem.swift`
- `Sources/SongbirdDistributed/InvocationEncoder.swift`
- `Sources/SongbirdHummingbird/ProjectionFlushMiddleware.swift`
- `Sources/SongbirdSmew/ReadModelStore.swift`
- `Tests/SongbirdTests/StreamSubscriptionTests.swift`
- `Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift`
- `Tests/SongbirdSQLiteTests/SQLiteKeyStoreTests.swift`
- `Tests/SongbirdHummingbirdTests/ProjectionFlushMiddlewareTests.swift`
- `Tests/SongbirdDistributedTests/SongbirdActorSystemTests.swift`
