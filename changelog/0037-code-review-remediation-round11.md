# Code Review Remediation Round 11

Final polish round from a 5-agent parallel code review — concurrency cleanup, precondition parity, resilient shutdown, type safety, and test parity.

## Concurrency & Safety

- **`ReadModelStore.connection` — remove unnecessary `nonisolated(unsafe)`** — Smew's `Connection` is `Sendable`, making the annotation redundant on a `private let` within an actor.
- **`LockedBox`-based resilient `shutdown()`** — Rewrote `SongbirdActorSystem.shutdown()` to extract and nil the server atomically, catch errors from `server.stop()` and each `client.disconnect()` independently, and only rethrow the first error after all cleanup completes. Previously, a failure in `server.stop()` would skip all client disconnects.
- **`TransportClient.connect()` double-connect guard** — Added `precondition(channel == nil)` to prevent silently overwriting an existing NIO channel, which would leak a file descriptor.
- **`AnyReaction` stored closure `@Sendable`** — Added `@Sendable` annotations to the `tryRoute` and `handle` stored closure properties, matching the `@Sendable` constraint already on the init parameters.

## Precondition Parity

- **`PostgresEventSubscription.init` batchSize guard** — Added `precondition(batchSize > 0)`, the last subscription type missing this validation (all others were fixed in Round 10).

## Type Safety & Consistency

- **`VersionConflictError` Equatable** — Added `Equatable` conformance, matching every other public error type in the framework. Enables precise `#expect(error == ...)` assertions.
- **`SQLiteKeyStore.hasKey` — use `db.scalar`** — Replaced `db.prepare` + row iteration with `db.scalar` for the `SELECT COUNT(*)` query, matching the established pattern in `schemaVersion`, `currentStreamVersion`, and `SQLitePositionStore.load`.

## Cleanup

- **Removed unused `@testable import SongbirdTesting`** from `SQLiteEventStoreTests.swift`.
- **Replaced legacy `ISO8601DateFormatter`** with `Date.formatted(.iso8601)` in `SQLiteKeyStoreTests.swift`, completing the migration started in Round 7.

## Test Improvements

- **`readStreamDataIsDecodable` (Postgres)** — Parity with SQLite: appends events with full metadata, reads via `readStream`, decodes, and verifies data + metadata round-trip.
- **`deleteKeyForNonExistentReferenceSucceeds` (Postgres)** — Parity with SQLite: confirms `deleteKey` on a never-created reference completes without error.

## Files Changed

- `Sources/SongbirdSmew/ReadModelStore.swift`
- `Sources/SongbirdPostgres/PostgresEventSubscription.swift`
- `Sources/SongbirdDistributed/SongbirdActorSystem.swift`
- `Sources/SongbirdDistributed/Transport.swift`
- `Sources/Songbird/EventStore.swift`
- `Sources/Songbird/EventReaction.swift`
- `Sources/SongbirdSQLite/SQLiteKeyStore.swift`
- `Tests/SongbirdSQLiteTests/SQLiteEventStoreTests.swift`
- `Tests/SongbirdSQLiteTests/SQLiteKeyStoreTests.swift`
- `Tests/SongbirdPostgresTests/PostgresEventStoreTests.swift`
- `Tests/SongbirdPostgresTests/PostgresKeyStoreTests.swift`
