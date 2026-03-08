# Demo App Review Remediation Round 2

Second round of review and remediation across all seven demo applications and the main framework's integration tests. Addresses critical lifecycle bugs, domain model correctness, entry point consistency, dead code removal, and test reliability.

## PostgresClient Lifecycle (C1, I5)

- **Single `client.run()` per application** — Consolidated duplicate `client.run()` calls in warbler-pg, warbler-distributed-pg, warbler-p2p-pg into a single managed task, preventing resource leaks from multiple concurrent connection pools.
- **Proper shutdown cancellation** — Shutdown now cancels the `client.run()` task cleanly rather than relying on process exit, ensuring connections are released.

## Distributed Shutdown & Gateway (C2, C3, I6, I7)

- **Non-swallowed errors on shutdown** — Distributed demo entry points now propagate shutdown errors instead of silently discarding them, so resource cleanup failures are visible.
- **Actor lifetime management** — Gateway and worker actors are kept alive for the duration of the task group, preventing premature deallocation.
- **Gateway middleware pattern** — Gateways in distributed demos now use the correct middleware registration pattern for event delivery.

## Domain Sources (I1–I4, S2–S5)

- **`PlaybackInjector.inject` nonisolated** — Removed unnecessary `await` on the synchronous `inject` method across all five demo entry points that called it, eliminating compiler warnings.
- **Equatable conformance** — Added `Equatable` to domain event types that were missing it, enabling precise test assertions.
- **Public reactions** — Made reaction types public so they can be referenced from entry points outside their defining module.
- **`commandType` as `let`** — Changed mutable `var commandType` properties to `let` where the value is fixed at declaration.
- **Status `rawValue` consistency** — Aligned status enum raw values across domain model types for consistent serialization.

## Entry Point Consistency (S6–S8, I8)

- **Logger replacing `print()`** — Replaced bare `print()` calls with structured `Logger` output in all demo entry points, so startup and runtime messages follow the same logging pipeline.
- **`BIND_HOST` environment variable** — All HTTP-serving demos now read `BIND_HOST` (defaulting to `127.0.0.1`) for the listen address, matching the `PORT` configurability added in round 1.
- **HTTPClient lifecycle** — Demos that create an `HTTPClient` now shut it down on exit, preventing leaked connections.

## Dead Code Removal (S1)

- **Removed `ViewCountAggregate`, `ViewCountEvent`, `ViewCountEventTypes`** — These types were unused remnants from an earlier iteration and had no references in any entry point, test, or projection.

## Test Quality (C4, C5, I9–I14, S9, S10)

- **Reliable timestamp assertions** — Replaced exact-match timestamp comparisons with tolerance-based checks that account for execution time variation.
- **Missing coverage** — Added tests for previously untested code paths in domain aggregates, projectors, and gateways.
- **Test harness usage** — Migrated gateway and injector tests to use the standard `TestGatewayHarness` / `TestInjectorHarness` where applicable, reducing boilerplate.
- **Intermediate assertions** — Added assertions at intermediate steps in multi-step test scenarios so failures pinpoint the exact step that broke.
- **Polling-based waits in `SongbirdServicesTests`** — Replaced fixed `Task.sleep` delays in `registerGatewayAndRun`, `registerProcessManager`, and `registerInjectorAndRun` with a `waitUntil` polling helper, fixing flaky test failures under load.

## Build Verification

All seven demos build successfully with no warnings from project code. Main framework: 508 tests passing across 72 suites. Warbler demo: 61 tests passing across 10 suites.

## Files Changed

Across all demo apps, shared domain sources, and framework integration tests — see individual commits for per-file details.
