# Code Review Remediation (Round 2)

Fixes from the second comprehensive code review of the Songbird framework.

## Critical Fixes
- **Force unwrap removed**: `TransportClient.call` task group `group.next()!` replaced with guard let
- **Force casts removed**: `SQLiteEventStore.schemaVersion` and `verifyChain` use safe type coercion with `SQLiteEventStoreError.corruptedRow`
- **SQL escaping tests**: Comprehensive test suite for `escapeSQLString` and `escapeSQLIdentifier` (12 tests)

## Important Fixes
- **EventTypeRegistry**: Cleaner lock usage with `withLock`, documented registration-before-decode contract
- **ProjectionFlushMiddleware**: Documented error swallowing rationale
- **NIO Sendable warning**: Documented as known upstream issue with justification for @unchecked Sendable
- **Cold schema name**: Now configurable via `DuckLakeConfig.schemaName` (default: "lake")
- **rawExecute**: Guarded behind `#if DEBUG` in both Postgres and SQLite stores

## Suggestions
- **InjectorRunner**: Added metrics (append duration + success/failure counters) matching GatewayRunner
- **SongbirdServices**: Added lifecycle logging on service start

## Test Coverage
- WireProtocol serialization round-trip tests (including malformed input, empty data, large payloads)
- EventTypeRegistry error path tests (unregistered types with precise error assertion, corrupted data)
