# Code Review Remediation

Comprehensive fixes from a full code review of the Songbird framework.

## Critical Fixes
- **Force unwraps removed**: `CryptoShreddingStore` (`sealed.combined!`, `String(data:encoding:)!`) and `EventTypeRegistry` (`as!`) now use safe alternatives
- **Silent data loss fixed**: `ProcessStateStream.applyIfMatching` now propagates errors instead of swallowing them
- **TOCTOU race fixed**: `PostgresKeyStore.key(for:layer:)` uses `INSERT ... ON CONFLICT DO NOTHING`
- **Data races fixed**: `SongbirdActorSystem.server` and `TransportServer.serverChannel` wrapped in `LockedBox`
- **SQL injection prevented**: String interpolation in DuckDB DDL/SET escaped via `escapeSQLString`/`escapeSQLIdentifier`

## Important Fixes
- **Unbounded load fixed**: `AggregateRepository.load` reads in batches of 1000 instead of `Int.max`
- **Batch caching**: `AggregateStateStream` and `ProcessStateStream` cache batches like `StreamSubscription`
- **Structured logging**: Added `swift-log` for errors in ProjectionPipeline, GatewayRunner, ProcessManagerRunner, TieringService
- **Metrics completeness**: `MetricsEventStore` now records duration and error counters for all failure types
- **Cache eviction**: `ProcessManagerRunner.stateCache` capped at 10,000 entries
- **Shared defaults**: `SubscriptionDefaults` enum replaces scattered `batchSize: 100` / `tickInterval: .milliseconds(100)`
- **Non-atomic append documented**: Multi-event commands in `AggregateRepository.execute` are not atomic

## Suggestions
- Error types gain `Equatable` conformance for easier testing
- Force unwrap in `ReadModelStore.rebuild` replaced with `guard let`
- Distributed transport calls have configurable timeout (default 30s) using structured concurrency (`withThrowingTaskGroup`)

## Test Coverage
- `MetricsEventStore`: non-conflict error counter coverage, version conflict duration recording
