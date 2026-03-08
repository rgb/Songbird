# Demo App Review Remediation Round 3

Third round of review and remediation across all seven demo applications. Addresses process manager idempotency, proxy lifecycle robustness, P2P shutdown patterns, structured logging, and miscellaneous code quality improvements.

## Process Manager Idempotency (C1, I6)

- **Equatable constraint on process manager state** — Added `Equatable` conformance to `ProcessManager.State` and `EventReaction.PMState`, enabling state change detection.
- **Skip reactions when state unchanged** — `AnyReaction` handle closure now compares state before and after `apply()` and skips `react()` when the event produces no state change, preventing duplicate side effects from redelivered events.
- **Idempotency test coverage** — Added tests for duplicate `PaymentConfirmed` and duplicate `PaymentFailed` events to verify reactions are not re-emitted.

## Proxy Lifecycle & Configuration (C3, I8, I9)

- **Graceful shutdown on error** — Wrapped `app.runService()` in do/catch so `HTTPClient.shutdown()` is always called, even when the application exits abnormally.
- **Correct health check probes** — Changed health check probes from `/` (which returns 404) to backend prefix routes (`/users`, `/videos`, etc.) so liveness checks reflect actual backend availability.
- **`BIND_HOST` and `PORT` environment variables** — Proxy now reads `BIND_HOST` and `PORT` from the environment, matching the configurability of the other demos.
- **Structured logging** — Replaced `print()` with `Logger` in `ProxyMiddleware` for consistent log output.

## P2P Service Shutdown Patterns (I1, I7)

- **Correct cancellation semantics** — Changed four SQLite P2P services from `waitForAll()` to `next()+cancelAll()`, so a single service failure triggers graceful shutdown of the remaining services instead of waiting indefinitely.
- **Structured logging across all P2P services** — Replaced `print()` with `Logger` in all eight P2P service entry points (four SQLite, four PostgreSQL) for consistent, filterable log output.

## Code Quality (I3, I11, S3)

- **Descriptive `fatalError()` messages** — Added meaningful messages to all 32 `fatalError()` stubs in distributed gateway proxy files, so crashes during development point to the unimplemented handler.
- **Safe Optional encoding** — Fixed `CountRow` encoding in four analytics routes by guarding against `nil` and returning a zero-value default, preventing unexpected `null` in JSON responses.
- **HTTP 204 for empty-body routes** — Changed 12 empty-body routes from `.ok` (200) to `.noContent` (204) across the monolith demos, following REST conventions.

## Investigated and Deferred

- **C2** (PG shutdown ordering) — P2P PG already uses the correct nested task group pattern.
- **C4** (`withExtendedLifetime` async) — Not supported in Swift 6.2; current `_ = handler` pattern is correct.
- **I2** (trace correlation) — Would require breaking wire-protocol change; deferred.
- **I4** (manual v1 projector) — Framework limitation in `RecordedEvent.decode()`; not fixable at demo level.
- **I5** (subscriptionId redundancy) — Event schema immutability prevents field removal.
- **I10** (per-case event versioning) — Would require separate event types; deferred as a larger refactor.
- **S1** (`PlaybackInjector.finish()` visibility) — Acceptable for demo scope.
- **S2** (JSONEncoder per call) — Thread-safe and not worth optimizing for demo scope.

## Build Verification

All seven demos build successfully with no warnings from project code. Main framework: 508 tests passing across 72 suites. Warbler demo: 63 tests passing across 10 suites.

## Files Changed

Across all demo apps, shared domain sources, and framework process manager infrastructure — see individual commits for per-file details.
