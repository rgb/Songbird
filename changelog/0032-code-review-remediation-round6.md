# Code Review Remediation Round 6

Comprehensive fixes from a 5-agent parallel code review covering all 7 modules.

## Critical Issues

- **`@Sendable` closures on `AnyReaction`** — Mark `tryRoute` and `handle` closure parameters as `@Sendable` to prevent callers from capturing mutable state in the `@unchecked Sendable` struct.
- **Thread-safe timestamp parsing in `PostgresEventStore`** — Replace `nonisolated(unsafe) ISO8601DateFormatter` with `Date.ISO8601FormatStyle` (`Date(_, strategy: .iso8601)`). Add `corruptedTimestamp` error case instead of silent `?? now` fallback.
- **Expired key filtering in `PostgresKeyStore`** — Add `AND (expires_at IS NULL OR expires_at > NOW())` to `existingKey` and `hasKey` queries, matching the SQLite store fix from round 5.

## Concurrency Fixes

- **`EventTypeRegistry`: NSLock → Mutex** — Replace `NSLock` + `@unchecked Sendable` with `Mutex<State>`. Single lock acquisition in `decode()` copies both `decoders` and `upcasts` dictionaries.
- **`Task.checkCancellation()` in `verifyChain`** — Both SQLite and Postgres `verifyChain` methods now check for cancellation at the top of their `while true` loops.
- **Timeout task leak in `NotificationSignal`** — Track timeout `Task`s in a dictionary; cancel them when notifications arrive or the signal stops.

## Consistency Fixes

- **SQLiteKeyStore Duration precision** — Use `Double(seconds) + Double(attoseconds) / 1e18` instead of truncating to whole seconds.
- **SQLiteKeyStore silent fallback → `preconditionFailure`** — Replace `return newKey` unreachable fallback with `preconditionFailure`.
- **SQLiteKeyStore corrupted data** — Add `SQLiteKeyStoreError` and throw on corrupted blob/count instead of silently returning nil/false.
- **SQLiteKeyStore `rawExecute` helper** — Add `#if DEBUG` helper for test-only raw SQL execution, fixing actor isolation bypass in tests.
- **SQLiteKeyStore expired key replacement** — Delete expired rows before `INSERT OR IGNORE` to handle the expiry-then-recreate case.
- **Remove unused `registry` from `SQLiteEventStore`** — The stored property was never read.
- **Rename `PostgresEventStoreError` → `PostgresStoreError`** — Shared by both event store and snapshot store.
- **Remove unused `InMemoryEventStore` registry parameter** — Parameter was accepted but never stored or used. All call sites updated.

## Logging & Documentation

- **Transport layer logging** — Log dropped non-call messages, oversized inbound frames (with size metadata), and decode errors in `ServerInboundHandler`.
- **`SongbirdActorSystem` safety doc** — Add doc comment explaining `@unchecked Sendable` justification (all state in `LockedBox`/`Mutex`).

## Test Coverage

- **Distributed module** — `assignIDAutoIncrements`, `resignIDRemovesActor` tests.
- **SQLite event store** — `readCategoriesRespectsMaxCount`, `verifyChainWithNullHashesTreatsAsValid` tests.
- **Hummingbird services** — `registerMultipleProjectors` test verifying both projectors receive events.
- **Smew read model** — `registerTableDeduplicates` test.

## Files Changed

- `Sources/Songbird/EventReaction.swift`
- `Sources/Songbird/EventTypeRegistry.swift`
- `Sources/SongbirdPostgres/PostgresEventStore.swift`
- `Sources/SongbirdPostgres/PostgresKeyStore.swift`
- `Sources/SongbirdPostgres/PostgresEventSubscription.swift`
- `Sources/SongbirdPostgres/PostgresSnapshotStore.swift`
- `Sources/SongbirdSQLite/SQLiteEventStore.swift`
- `Sources/SongbirdSQLite/SQLiteKeyStore.swift`
- `Sources/SongbirdDistributed/SongbirdActorSystem.swift`
- `Sources/SongbirdDistributed/Transport.swift`
- `Sources/SongbirdTesting/InMemoryEventStore.swift`
- `Tests/` — multiple test files updated
