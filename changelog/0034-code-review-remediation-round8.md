# Code Review Remediation Round 8

Fixes from a 5-agent parallel code review covering all 7 modules, with focus on structured concurrency, hardcoded values, and consistency gaps.

## Important Fixes

- **`SQLiteEventStore` ISO8601DateFormatter** — Replace `ISO8601DateFormatter` (NSObject, not Sendable) with `Date.ISO8601FormatStyle` (value type, Sendable), matching the consistency fix applied to the other 3 SQLite stores in round 7.
- **`PostgresEventSubscription` position flush on cancellation** — Save the last delivered event's position before returning nil when the subscription task is cancelled, matching the fix applied to core `EventSubscription` in round 7. Reduces re-processing on restart.
- **`PostgresEventStore` unused registry removal** — Remove the `registry` field and `registry:` init parameter that were stored but never used. Update all 13 callers across source and test files.
- **`CryptoShreddingStore` unknown enc: prefix** — Replace silent `return .string(encryptedString)` with thrown `CryptoShreddingError.unknownEncryptionScheme`, preventing garbage data from being returned to callers when an unrecognized encryption scheme is encountered.
- **`EncryptedPayload` Decodable init** — Replace `self.originalEventType = ""` with `preconditionFailure`, making it explicit that this code path should never be reached (the type is always constructed via `init(originalEventType:fields:)`).
- **Server-side `writeAndFlush` error logging** — Add `EventLoopPromise`-based write error logging for both server-side response writes in `SongbirdActorSystem`, matching the pattern already used client-side.
- **`ReadModelStore.rebuild` cancellation** — Add `Task.checkCancellation()` at the top of the rebuild loop for responsive cancellation during long-running read model rebuilds.

## Hardcoded Constants Extracted

- **`HashChain.genesisSeed`** — Replaces 4 literal `"genesis"` strings across `SQLiteEventStore` and `PostgresEventStore`.
- **`PostgresDefaults.notifyChannel`** — Replaces 4 literal `"songbird_events"` default parameters across `PostgresEventStore` and `PostgresEventSubscription`.
- **`DuckLakeDefaults.schemaName`** — Replaces 2 literal `"lake"` values across `DuckLakeConfig` and `ReadModelStore`.

## Test Improvements

- **`decryptThrowsOnUnknownEncPrefix`** — New test verifying CryptoShreddingStore throws on unrecognized `enc:` prefix.
- **`cancellationFlushesLastDeliveredPosition`** — New test verifying EventSubscription persists position to PositionStore when cancelled after consuming events.

## Files Changed

- `Sources/Songbird/EventStore.swift`
- `Sources/Songbird/CryptoShreddingStore.swift`
- `Sources/Songbird/JSONValue.swift`
- `Sources/SongbirdSQLite/SQLiteEventStore.swift`
- `Sources/SongbirdPostgres/PostgresEventStore.swift`
- `Sources/SongbirdPostgres/PostgresEventSubscription.swift`
- `Sources/SongbirdDistributed/SongbirdActorSystem.swift`
- `Sources/SongbirdSmew/ReadModelStore.swift`
- `Sources/SongbirdSmew/DuckLakeConfig.swift`
- `Tests/SongbirdTests/CryptoShreddingStoreTests.swift`
- `Tests/SongbirdTests/EventSubscriptionTests.swift`
- `Tests/SongbirdPostgresTests/PostgresTestHelper.swift`
- `Tests/SongbirdPostgresTests/PostgresEventStoreTests.swift`
- `Tests/SongbirdPostgresTests/PostgresChainVerificationTests.swift`
- `Tests/SongbirdPostgresTests/PostgresEventSubscriptionTests.swift`
