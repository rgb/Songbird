# 0026 — Metrics & Observability

Framework-level metrics for Songbird using swift-metrics. Components emit metrics via the standard facade; calls are zero-cost no-ops unless the app bootstraps a backend (Prometheus, StatsD, etc.).

## What Changed

### Package.swift

- Added `swift-metrics` (from 2.0.0) dependency
- Added `Metrics` product to `Songbird` core target

### Core Types (Songbird module)

- **`MetricsEventStore<Inner: EventStore>`** — Decorator wrapping any EventStore. Emits append counter, append timer, read timer, read event count, and version conflict counter. All with `songbird_event_store_` prefix. Follows same pattern as `CryptoShreddingStore`.

- **`ProjectionPipeline`** — Now emits projection lag gauge, per-projector processing timer, and queue depth gauge. All with `songbird_projection_` prefix.

- **`EventSubscription`** — Now emits subscription position gauge, batch size gauge, and tick duration timer. All with `songbird_subscription_` prefix. Dimensions include `subscriber_id`.

- **`GatewayRunner`** — Now emits delivery duration timer, delivery total counter (with success/failure status), and subscription error counter. All with `songbird_gateway_` prefix. Dimensions include `gateway_id`.

- **`Duration.nanoseconds`** — Internal extension for converting `Duration` to nanoseconds for swift-metrics Timer recording.

### Testing (SongbirdTesting module)

- **`TestMetricsFactory`** — swift-metrics backend that captures metrics in memory. Singleton with `bootstrap()` and `reset()`. Query via `counter(_:dimensions:)`, `timer(_:dimensions:)`, `gauge(_:dimensions:)`.

- **`TestCounter`**, **`TestTimer`**, **`TestRecorder`** — In-memory metric handlers for test assertions.

## Metrics Reference

| Metric | Type | Dimensions |
|--------|------|------------|
| `songbird_event_store_append_total` | Counter | `stream_category` |
| `songbird_event_store_append_duration_seconds` | Timer | `stream_category` |
| `songbird_event_store_read_duration_seconds` | Timer | `stream_category`, `read_type` |
| `songbird_event_store_read_events_total` | Counter | |
| `songbird_event_store_version_conflict_total` | Counter | `stream_category` |
| `songbird_projection_lag` | Gauge | |
| `songbird_projection_process_duration_seconds` | Timer | `projector_id` |
| `songbird_projection_queue_depth` | Gauge | |
| `songbird_subscription_position` | Gauge | `subscriber_id` |
| `songbird_subscription_batch_size` | Gauge | `subscriber_id` |
| `songbird_subscription_tick_duration_seconds` | Timer | `subscriber_id` |
| `songbird_subscription_errors_total` | Counter | `subscriber_id` |
| `songbird_gateway_delivery_duration_seconds` | Timer | `gateway_id` |
| `songbird_gateway_delivery_total` | Counter | `gateway_id`, `status` |

## Files Added

- `Sources/Songbird/MetricsEventStore.swift`
- `Sources/SongbirdTesting/TestMetricsFactory.swift`
- `Tests/SongbirdTests/MetricsTestSuite.swift`
- `Tests/SongbirdTests/TestMetricsFactoryTests.swift`
- `Tests/SongbirdTests/MetricsEventStoreTests.swift`
- `Tests/SongbirdTests/ProjectionPipelineMetricsTests.swift`
- `Tests/SongbirdTests/GatewayRunnerMetricsTests.swift`

## Files Modified

- `Package.swift` — Added swift-metrics dependency
- `Sources/Songbird/ProjectionPipeline.swift` — Added metrics emission
- `Sources/Songbird/EventSubscription.swift` — Added metrics emission
- `Sources/Songbird/GatewayRunner.swift` — Added metrics emission

## Test Coverage

- 5 tests for TestMetricsFactory (counter, timer, gauge, dimensions, reset)
- 7 tests for MetricsEventStore (append, reads, version conflict, streamVersion)
- 3 tests for ProjectionPipeline metrics (processing timer, lag gauge, queue depth)
- 2 tests for GatewayRunner metrics (success delivery, failure delivery with errors)
