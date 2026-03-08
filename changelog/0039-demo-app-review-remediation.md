# Demo App Review Remediation

Comprehensive review and remediation of all seven demo applications (warbler, warbler-pg, warbler-distributed, warbler-distributed-pg, warbler-p2p, warbler-p2p-pg, warbler-p2p-proxy) plus the shared domain sources they depend on. Covers packaging, domain logic, test coverage, entry points, distributed/P2P architecture, and cross-cutting concerns.

## Package.swift

- Set platform minimum to `.macOS(.v15)` across all demo Package.swift files for consistency with the main Songbird framework
- Removed unused dependencies (e.g. `SongbirdTesting`) from targets that did not need them

## Domain Sources: WarblerCatalog + WarblerIdentity

- Renamed `VideoPublished` event type constant from `"video_published"` to `"catalog.video.published"` for namespace consistency; added `"video_published"` as a recognised v1 alias
- Added v1 event handling in `VideoCatalogProjector` so projections built from older event streams still work
- Extracted event type strings into constants on each event type (`VideoPublished.eventType`, etc.) to eliminate scattered string literals

## Domain Sources: WarblerAnalytics + WarblerSubscriptions

- Fixed `PlaybackAnalyticsGateway` to read `userId` from the event's `streamId` (where it is always present) rather than from metadata (where it may be absent)
- Made `PlaybackAnalyticsGateway` conform to `Sendable`
- Added state guards in `SubscriptionAggregate` command handlers so that, for example, cancelling an already-cancelled subscription is rejected
- Changed `PlaybackAnalyticsProjector` to call `registerTable` in its initialiser for consistent table setup

## Tests

- Added error-path tests for `VideoAggregate` (publish with empty title, publish with empty description)
- Added error-path test for `UserAggregate` (register with empty email)
- Added projector edge-case tests covering unknown event types and events without stream IDs
- Added injector/gateway failure-path test for `PlaybackAnalyticsGateway`

## Monolith Entry Points (warbler + warbler-pg)

- Removed `import SongbirdTesting` from production entry points
- Made HTTP port configurable via `PORT` environment variable
- Introduced a JSON-encoding helper to eliminate raw string interpolation in route handlers
- Added structured logging on startup (bound address, database paths)

## Distributed Demos (warbler-distributed + warbler-distributed-pg)

- Added `shutdown()` calls on graceful termination so connections and resources are released
- Consolidated duplicate `client.run()` calls into a single task group pattern
- Set process exit code to 1 on fatal errors
- Removed unused imports

## P2P + Proxy Demos (warbler-p2p, warbler-p2p-pg, warbler-p2p-proxy)

- Made file paths (`SQLITE_PATH`, `DUCKDB_PATH`) and ports (`PORT`, `BIND_HOST`) configurable via environment variables with sensible defaults
- Replaced `InMemoryPositionStore` with `SQLitePositionStore` in P2P SQLite services
- Consolidated double `client.run()` into a single task group in P2P Postgres services
- Removed dead code (`_viewCountRepo`, unused snapshot store creation) from analytics services
- Replaced manual JSON string interpolation in proxy `healthCheck()` with `JSONEncoder` and a `Codable` struct
- Fixed nginx config: removed trailing slashes from location blocks so sub-paths (e.g. `/users/alice`) match correctly

## Cross-Cutting: Launch Scripts

- Replaced arbitrary `sleep` delays with polling in all four launch scripts:
  - Distributed scripts poll for Unix socket existence (`[ ! -S ... ]`) with `sleep 0.1`
  - P2P proxy scripts poll TCP ports via `nc -z` with `sleep 0.2`
- Changed `swift build 2>/dev/null || true` to `swift build || exit 1` so build failures are visible and halt the script

## Cross-Cutting: Input Validation

- Added `invalidInput(String)` error case to `VideoAggregate.Failure` and `UserAggregate.Failure`
- `PublishVideoHandler` validates non-empty title and description
- `RegisterUserHandler` validates non-empty email

## Build Verification

All seven demos build successfully. Main framework: 508 tests passing. Warbler demo: 59 tests passing.

## Files Changed

Across all demo apps and shared domain sources — see individual commits for per-file details.
