# Code Review Remediation Round 7

Comprehensive fixes from a 5-agent parallel code review covering all 7 modules.

## Critical Issues

- **`MessageFrameDecoder` throws on oversized message** — Replace `.needMoreData` return after channel close with thrown `SongbirdDistributedError.connectionFailed`, correctly propagating the error instead of leaving the decoder in an inconsistent state.
- **`TransportClient` write error detection** — Replace `writeAndFlush(promise: nil)` with an `EventLoopPromise` that detects write failures and cancels the pending call, preventing orphaned continuations.
- **`PostgresKeyStore` recoverable error** — Replace `preconditionFailure` with thrown `PostgresStoreError.keyNotFoundAfterInsert`, preventing process crashes on data consistency issues.
- **`PostgresTestHelper` error propagation** — Change `AsyncStream` to yield `Result` so container startup errors propagate to tests instead of causing silent hangs. Fix `started`/`migrated` flags to only be set after operations succeed.
- **`PostgresEventStore` hash corruption guard** — Add `guard !normalizedData.isEmpty` after `INSERT RETURNING` to throw `PostgresStoreError.corruptedData` instead of silently computing hash on empty strings.

## Important Fixes

- **`EventTypeRegistry` upcast mismatch** — Replace silent `return event` on type-mismatch with `preconditionFailure`, surfacing registry misconfiguration during development.
- **`ProcessManagerRunner` state ordering** — Document that state-before-output-append is intentional: the subscription position advances regardless of output success, so the PM must track processed events in its cache.
- **`EventSubscription` position flush on cancellation** — Save the last delivered event's position before returning nil when the subscription task is cancelled, reducing re-processing on restart.
- **`TestProcessManagerHarness` error handling** — Replace `try?` with explicit `do/catch` for `tryRoute`, making the skip-on-decode-failure behavior explicit instead of hidden.
- **`TieringService` cancellation** — Add `!Task.isCancelled` to the `while` loop condition for more responsive cancellation detection.
- **SQLite stores `iso8601Formatter` cleanup** — Replace write-only `ISO8601DateFormatter` (NSObject, not Sendable) with `Date.ISO8601FormatStyle` (value type, Sendable) in `SQLiteSnapshotStore`, `SQLitePositionStore`, and `SQLiteKeyStore`.

## Test Improvements

- **Distributed tests: explicit cleanup** — Replace all `defer { Task { try await stop() } }` fire-and-forget patterns with explicit sequential cleanup in `TransportTests` and `SongbirdActorSystemTests`, ensuring cleanup errors are observable.
- **`callBeforeConnectThrowsNotConnected`** — New test verifying the `notConnected` error path.
- **`concurrentCallsResolveIndependently`** — New test verifying 5 concurrent calls on the same client all resolve correctly.
- **`ProjectionFlushMiddleware` error resilience** — New test verifying middleware returns HTTP response even when pipeline is not running.
- **`registerProcessManager` assertion** — Added observable assertion verifying event persistence instead of just "didn't crash".

## Files Changed

- `Sources/SongbirdDistributed/Transport.swift`
- `Sources/SongbirdPostgres/PostgresEventStore.swift`
- `Sources/SongbirdPostgres/PostgresKeyStore.swift`
- `Sources/Songbird/EventTypeRegistry.swift`
- `Sources/Songbird/ProcessManagerRunner.swift`
- `Sources/Songbird/EventSubscription.swift`
- `Sources/SongbirdTesting/TestProcessManagerHarness.swift`
- `Sources/SongbirdSmew/TieringService.swift`
- `Sources/SongbirdSQLite/SQLiteSnapshotStore.swift`
- `Sources/SongbirdSQLite/SQLitePositionStore.swift`
- `Sources/SongbirdSQLite/SQLiteKeyStore.swift`
- `Tests/SongbirdPostgresTests/PostgresTestHelper.swift`
- `Tests/SongbirdDistributedTests/TransportTests.swift`
- `Tests/SongbirdDistributedTests/SongbirdActorSystemTests.swift`
- `Tests/SongbirdHummingbirdTests/ProjectionFlushMiddlewareTests.swift`
- `Tests/SongbirdHummingbirdTests/SongbirdServicesTests.swift`
