# Code Review Remediation (Round 5)

Fixes from the fifth comprehensive code review of the Songbird framework, with focus on Swift 6.2 strict structured concurrency, iterator resource cleanup, cancellation correctness, and test coverage.

## Critical Fixes
- **PostgresEventSubscription `[weak self]` on actor**: Removed meaningless `[weak self]` captures in `NotificationSignal` — actors are reference types, `weak self` creates silent no-ops that can leak continuations.
- **PostgresEventSubscription iterator error cleanup**: When `next()` throws (e.g., store read failure), the LISTEN connection is now properly stopped. Previously only the cancellation path cleaned up.

## Important Fixes
- **Task.checkCancellation in fold loops**: Added cancellation checks to initial fold loops in `AggregateStateStream`, `AggregateRepository`, and `ProcessStateStream` — prevents wasteful full-history replay on cancelled tasks.
- **GatewayRunner CancellationError rethrow**: Added `catch is CancellationError` clause matching `ProcessManagerRunner`'s pattern — previously swallowed cancellation errors.
- **MetricsEventStore test label fix**: `streamVersionEmitsNoMetrics` was checking wrong metric name; replaced with `streamVersionEmitsDurationTimer` checking correct `songbird_event_store_stream_version_duration_seconds`.
- **SQLiteEventStore verifyChain O(N^2)**: Replaced OFFSET-based pagination with cursor-based `WHERE global_position > lastSeen`, matching the PostgresEventStore fix from round 4.
- **SQLiteKeyStore expires_at enforcement**: `existingKey` and `hasKey` now filter out expired keys. Added `INSERT OR IGNORE` for concurrent insert safety.
- **PostgresKeyStore Duration precision**: `Duration.components.seconds` truncated sub-second durations. Now converts via attoseconds for full precision.
- **LockedBox NSLock -> Mutex**: Replaced `NSLock` + `@unchecked Sendable` with Swift 6.2 `Mutex<T>` from `Synchronization` module.
- **TestMetricsFactory NSLock -> Mutex**: Same migration for `TestMetricsFactory`, `TestCounter`, `TestTimer`, `TestRecorder`.
- **PostgresEventStore JSON reuse**: Stored `JSONEncoder`, `JSONDecoder`, and `ISO8601DateFormatter` as properties instead of allocating per call.
- **ContainerState re-entrancy**: Set `started = true` before first suspension point to prevent concurrent test starts from launching duplicate Docker containers.
- **MessageFrameEncoder outbound size**: Added max message size check on outbound, matching inbound enforcement in `MessageFrameDecoder`.
- **macOS deployment target**: Bumped from macOS 14 to macOS 15 to enable `Mutex<T>` from `Synchronization` module.

## Suggestions
- **NOTIFY channel configurable**: `"songbird_events"` channel name is now a constructor parameter (default preserved).
- **InvocationEncoder/Decoder JSON reuse**: Stored `JSONEncoder`/`JSONDecoder` as properties instead of per-call allocation.
- **SQLiteSnapshotStore error handling**: `loadData` now throws on corrupted blob/version instead of silently returning nil.
- **PostgresKeyStore unreachable fallback**: Replaced silent `return newKey` fallback with `preconditionFailure` since it indicates a bug.
- **InMemoryEventStore unused registry**: Stopped storing the `EventTypeRegistry` parameter (kept in API for compatibility).
- **Force unwraps removed**: Replaced `timer!.values[0]` patterns in `MetricsEventStoreTests` with safe access.

## Test Coverage
- MetricsEventStore read error paths (readStream, readCategories, readLastEvent, streamVersion)
- SQLiteKeyStore expired key behavior
- PostgresKeyStore expiry storage
- verifyChain batch boundary (batchSize=1 and batchSize=2)
- ProjectionPipeline.stop() resumes waiting callers
- EventSubscription cancellation cleanup
- InvocationDecoder invalid base64 handling
- PostgresEventStore concurrent version conflict
