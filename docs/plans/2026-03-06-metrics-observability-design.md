# Metrics & Observability Design

## Overview

Framework-level metrics for Songbird using [swift-metrics](https://github.com/apple/swift-metrics). Components always emit metrics via the swift-metrics facade; calls are no-ops unless the app bootstraps a backend (Prometheus, StatsD, etc.). Same pattern as swift-log — the framework says "this happened," the app decides if anyone's listening.

## API

**swift-metrics** — Apple's standard metrics abstraction. Components use `Counter`, `Timer`, `Gauge` directly. No wrapper types, no Songbird-specific metrics protocol.

Apps opt in by bootstrapping a backend at startup:
```swift
MetricsSystem.bootstrap(PrometheusMetricsFactory())
```

Without this call, all metric emissions are zero-cost no-ops.

## Integration Approach

**Built into components.** Each component emits metrics directly via swift-metrics calls. No injection, no optional handlers.

**EventStore exception:** Since EventStore is a protocol with three implementations (SQLite, Postgres, InMemory), metrics live in a single `MetricsEventStore<Inner: EventStore>` decorator rather than being duplicated in each implementation. This follows the same pattern as `CryptoShreddingStore`.

Composition order:
```swift
MetricsEventStore(CryptoShreddingStore(SQLiteEventStore(...)))
```

Metrics on the outside measure total time including encryption overhead.

## Metrics

All metrics prefixed with `songbird_` to avoid collisions. Dimensions use swift-metrics label tuples.

### EventStore (via MetricsEventStore decorator)

| Metric | Type | Dimensions | Description |
|--------|------|------------|-------------|
| `songbird_event_store_append_duration_seconds` | Timer | `stream_category` | Time to append an event |
| `songbird_event_store_append_total` | Counter | `stream_category` | Events appended |
| `songbird_event_store_read_duration_seconds` | Timer | `stream_category`, `read_type` | Time to read events |
| `songbird_event_store_read_events_total` | Counter | | Events returned per read |
| `songbird_event_store_version_conflict_total` | Counter | `stream_category` | Optimistic concurrency conflicts |

### ProjectionPipeline

| Metric | Type | Dimensions | Description |
|--------|------|------------|-------------|
| `songbird_projection_lag` | Gauge | | `global_position_head - last_projected_position` |
| `songbird_projection_process_duration_seconds` | Timer | `projector_id` | Time to process one event in a projector |
| `songbird_projection_queue_depth` | Gauge | | Current queue size |

### SubscriptionRunner

| Metric | Type | Dimensions | Description |
|--------|------|------------|-------------|
| `songbird_subscription_position` | Gauge | `subscriber_id` | Current subscription position |
| `songbird_subscription_batch_size` | Gauge | `subscriber_id` | Events processed per tick |
| `songbird_subscription_tick_duration_seconds` | Timer | `subscriber_id` | Time per polling tick |
| `songbird_subscription_errors_total` | Counter | `subscriber_id` | Handler errors |

### GatewayRunner

| Metric | Type | Dimensions | Description |
|--------|------|------------|-------------|
| `songbird_gateway_delivery_duration_seconds` | Timer | `gateway_id` | Time per delivery |
| `songbird_gateway_delivery_total` | Counter | `gateway_id`, `status` | Deliveries by outcome (success/failure) |

## Testing

`TestMetricsFactory` in `SongbirdTesting` — a swift-metrics backend that captures emitted metrics in memory for assertions:

```swift
let factory = TestMetricsFactory()
MetricsSystem.bootstrapInternal(factory)

// ... run code ...

#expect(factory.counter("songbird_event_store_append_total")?.value == 1)
#expect(factory.timer("songbird_event_store_append_duration_seconds")?.lastValue != nil)
```

Test coverage per component:
- MetricsEventStore: append emits counter + timer, read emits timer, version conflict emits counter, correct dimensions
- ProjectionPipeline: lag gauge updates, processing timer records
- SubscriptionRunner: position gauge advances, tick timer records, error counter increments
- GatewayRunner: delivery counter + timer, success/failure dimensions

## Dependencies

- `swift-metrics` added to `Songbird` core module in `Package.swift`
- No new modules or targets
- `TestMetricsFactory` added to `SongbirdTesting`
