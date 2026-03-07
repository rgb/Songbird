# Code Review Remediation Round 9

Fixes from a 5-agent parallel code review covering all 7 modules — cleanup of dead code, missing guards, visibility fixes, consistency gaps, and high-value test coverage.

## Dead Code & Consistency Cleanup

- **`SQLiteEventStore` unused `registry` parameter** — Removed the `registry: EventTypeRegistry` init parameter that was accepted but never stored or used, matching the same cleanup done for `PostgresEventStore` in round 8. Updated all callers across tests and demo apps.
- **`InvocationEncoder.targetName` removal** — Removed the `targetName: String = ""` property that was declared and initialized but never written to or read from.
- **`PostgresEventSubscription` hardcoded batchSize** — Replaced `batchSize: Int = 100` with `batchSize: Int = SubscriptionDefaults.batchSize`, matching every other subscription type in the codebase.

## Safety Improvements

- **`SQLiteEventStore` infinite loop prevention** — Added `precondition(batchSize > 0)` to `verifyChain` (where `batchSize: 0` causes an infinite loop) and `precondition(maxCount > 0)` to `readStream`/`readCategories` (where negative values pass `LIMIT -1` to SQLite, meaning "no limit"). Same `batchSize` guard added to `PostgresEventStore.verifyChain`.
- **SQLite `db` property visibility** — Changed `nonisolated(unsafe) let db: Connection` from default `internal` to `private` in all 4 SQLite stores (`SQLiteEventStore`, `SQLitePositionStore`, `SQLiteSnapshotStore`, `SQLiteKeyStore`), enforcing actor isolation at compile time.
- **`TransportClient` wrapping addition** — Changed `nextRequestId += 1` to `nextRequestId &+= 1`, preventing a debug-mode trap at `UInt64.max`.
- **`ReadModelStore.tierProjections` graceful handling** — Replaced `precondition(thresholdDays > 0)` with `guard thresholdDays > 0 else { return 0 }`, preventing a production crash from misconfiguration in the background `TieringService`.

## Code Quality

- **Hash computation deduplication** — Extracted `private static func computeEventHash(previousHash:eventType:streamName:data:timestamp:)` in both `SQLiteEventStore` and `PostgresEventStore`, replacing duplicated inline SHA256 computations in `append` and `verifyChain`.
- **`SongbirdServices` doc comment** — Replaced misleading usage example that referenced `Application(router:services:)` and `app.runService()` (which would not compile) with the actual `Task { try await services.run() }` pattern.
- **`SongbirdDistributedError` Equatable** — Added `Equatable` conformance and updated all distributed test assertions to check specific error cases (`.notConnected`, `.remoteCallFailed`) instead of just the error type.

## Test Improvements

- **corruptedRow error path tests** — Added 8 new tests across `SQLiteEventStoreTests` (5 tests: NULL event_type, NULL data, NULL timestamp, invalid timestamp, invalid UUID), `SQLiteSnapshotStoreTests` (2 tests: NULL state, NULL version), and `SQLiteKeyStoreTests` (1 test: NULL key_data), exercising previously untested data corruption guard paths.
- **AggregateRepository load batching** — New test appends 5 events and loads with `batchSize: 2`, verifying all batches are correctly folded into the final state.

## Files Changed

- `Sources/SongbirdSQLite/SQLiteEventStore.swift`
- `Sources/SongbirdSQLite/SQLitePositionStore.swift`
- `Sources/SongbirdSQLite/SQLiteSnapshotStore.swift`
- `Sources/SongbirdSQLite/SQLiteKeyStore.swift`
- `Sources/SongbirdPostgres/PostgresEventStore.swift`
- `Sources/SongbirdPostgres/PostgresEventSubscription.swift`
- `Sources/SongbirdDistributed/InvocationEncoder.swift`
- `Sources/SongbirdDistributed/Transport.swift`
- `Sources/SongbirdDistributed/WireProtocol.swift`
- `Sources/SongbirdHummingbird/SongbirdServices.swift`
- `Sources/SongbirdSmew/ReadModelStore.swift`
- `Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift`
- `Tests/SongbirdSQLiteTests/SQLiteSnapshotStoreTests.swift`
- `Tests/SongbirdSQLiteTests/SQLiteKeyStoreTests.swift`
- `Tests/SongbirdDistributedTests/TransportTests.swift`
- `Tests/SongbirdDistributedTests/SongbirdActorSystemTests.swift`
- `Tests/SongbirdTests/AggregateRepositoryTests.swift`
