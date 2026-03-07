# Code Review Remediation (Round 4)

Fixes from the fourth comprehensive code review of the Songbird framework, with focus on Swift 6.2 strict structured concurrency, lazy implementations, hard-coded values, and test coverage gaps.

## Critical Fixes
- **NotificationSignal dictionary mutation**: Fixed undefined behavior — `for-in` iteration over dictionary while mutating it. Drain to local copy first in both `notifyWaiters()` and `stop()`.
- **SQLiteEventStore index bypass**: `(global_position - 1) >= ?` prevents B-tree index usage. Changed to `global_position >= ? + 1` (shift the parameter, not the column).
- **TransportClient cancelPendingCall error type**: External cancellation now produces `CancellationError` (not timeout error). Added `error` parameter to `cancelPendingCall` so `onCancel` and timeout pass distinct error types.
- **ActorSystemMessageHandler response encode failure**: Silent `try?` on response encoding left client continuations hanging. Added do/catch with logged error and fallback error response.

## Important Fixes
- **ProcessManagerRunner error isolation**: Wrapped `processEvent` in do/catch matching GatewayRunner's pattern — rethrows `CancellationError`, logs and continues on other errors.
- **verifyChain brokenAtSequence 0-based**: Both SQLite and Postgres stores now return 0-based `globalPosition` consistently (was 1-based raw AUTOINCREMENT value).
- **PostgresEventStore.append timestamp**: Return the DB-normalized timestamp from the `RETURNING` clause instead of the local `Date()`.
- **ClientInboundHandler channelInactive/errorCaught**: Added handlers that resume all pending continuations on unexpected server disconnect, preventing hanging calls.
- **PostgresEventStore.verifyChain O(N²) pagination**: Replaced `OFFSET`-based pagination with cursor-based `WHERE global_position > lastSeen` for O(N) total work.
- **Retention Duration wiring**: `FieldProtection.retention(Duration)` now passes the Duration through to `KeyStore.key(for:layer:expiresAfter:)`, populating the `expires_at` column in both SQLite and Postgres key stores.
- **Duplicate WireProtocol tests removed**: Removed 3 redundant tests from `SongbirdActorIDTests.swift` that were fully superseded by `WireProtocolTests.swift`.
- **AggregateRepositoryTests weak assertion**: Replaced bare `do/catch` with `#expect(throws: BankAccountAggregate.Failure.self)` for type-checked error assertion.
- **rawExecute test guarded**: Wrapped `tamperedEventBreaksChain` test in `#if DEBUG` to match the `#if DEBUG` guard on `rawExecute` in the source.
- **Force-unwrap removed**: Replaced `group.next()!` with `guard let` in PostgresEventSubscriptionTests helper.
- **fatalError replaced**: PostgresTestHelper now throws `PostgresTestHelperError.containerNotStarted` instead of crashing the test process.
- **MetricsEventStore read error recording**: All read methods now record timer + error counter on failure (matching append's do/catch pattern). Added `streamVersion` metrics.
- **Upcast cycle detection**: Added visited set to EventTypeRegistry's upcast chain walk. Cycles now trigger `preconditionFailure` instead of infinite loop.

## Suggestions
- **JSONEncoder/JSONDecoder reuse**: SQLiteEventStore now stores encoder/decoder as actor properties instead of allocating fresh instances per call.
- **Empty existential test replaced**: `protocolIsUsableAsExistential` now creates an `InMemoryEventStore` through `any EventStore` and exercises `streamVersion`.

## Test Coverage
- ProcessManagerRunner error path test (store.append failure — runner continues processing)
- TransportClient external cancellation test (produces CancellationError, not timeout)
- TransportClient unexpected disconnect test (server crash resolves pending calls)
