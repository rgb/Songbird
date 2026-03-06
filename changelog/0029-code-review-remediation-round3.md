# Code Review Remediation (Round 3)

Fixes from the third comprehensive code review of the Songbird framework, with focus on Swift 6.2 strict structured concurrency, safety, and test coverage.

## Critical Fixes
- **ProjectionPipeline continuation leak**: Fixed race between `withTaskCancellationHandler` and `withCheckedThrowingContinuation` where cancellation could fire before the waiter was registered, leaking the continuation forever. Added post-registration `Task.isCancelled` check.
- **TransportClient continuation orphaning**: Same cancellation race fix in `sendAndAwaitResponse`. Also fixed `disconnect()` to resume all pending continuations before closing the channel.
- **SQLiteEventStore IUO removed**: Replaced `var result: RecordedEvent!` with proper optional + guard-let.

## Important Fixes
- **Timestamp fallback removed**: `iso8601Formatter.date(from:) ?? Date()` replaced with proper error throw (`corruptedRow`)
- **thresholdDays validation**: Added `precondition(thresholdDays > 0)` in `tierProjections()`
- **Max wire message size**: Added 16 MB limit in NIO frame decoder with logged rejection of oversized frames
- **Transport logging**: Added `Logger` to `ServerInboundHandler` and `ClientInboundHandler` for decode failure visibility
- **RequestIdMiddleware**: Documented force unwrap safety for `HTTPField.Name("X-Request-ID")!`
- **StreamName validation**: Added preconditions (no empty strings, no hyphens in category)
- **RecordedEvent: Equatable**: Added conformance (all fields already Equatable)
- **ProcessManagerRunner causation**: Output events now propagate `causationId` and `correlationId` from the triggering event
- **LockedBox\<T: Sendable\>**: Added Sendable constraint to enforce type safety
- **InjectorRunner metrics**: Added `injector_id` dimension to match GatewayRunner pattern

## Suggestions
- **DynamicCodingKey**: Changed from `internal` to `private` (only used within JSONValue.swift)
- **EncryptedPayload decode**: Documented `originalEventType = ""` limitation in Decodable init
- **ReadModelStore.connection**: Made `private` for actor safety
- **AggregateRepository.batchSize**: Now configurable via init (default 1000, was hard-coded)
- **Tiering comment**: Corrected misleading crash-recovery comment about duplicate cleanup

## Test Coverage
- TransportClient timeout test (server never responds, verifies timeout fires)
- TransportClient disconnect cleanup test (immediate disconnect without calls)
- SongbirdServices registerProcessManager test
- JSONValue array and nested object/array round-trip tests
- EventTypeRegistry duplicate registration test
- ProcessManagerRunner cache eviction test (maxCacheSize enforcement)
- ReadModelStore migration idempotency test (incremental apply, no-op re-run)
- TieringService resilience test (runs against non-tiered store without crashing)
