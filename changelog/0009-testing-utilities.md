# 0009: Testing Utilities

Expanded the `SongbirdTesting` module with reusable test utilities that eliminate boilerplate across Songbird test files.

## New Components

### RecordedEvent Convenience Initializer
- `RecordedEvent.init(event:id:streamName:position:globalPosition:metadata:timestamp:)` — accepts any typed `Event`, JSON-encodes it automatically, and provides sensible defaults for all metadata fields.

### Test Projectors (promoted from ProjectionPipelineTests)
- **RecordingProjector** — records every event it receives
- **FilteringProjector** — records only events whose type is in the accepted set
- **FailingProjector** — throws `FailingProjectorError` on a specific event type, records all others

### TestAggregateHarness
- Value type for testing aggregates in isolation without an event store
- `given(events...)` folds events into state
- `when(command, using: handler)` executes a command handler and folds resulting events
- Tracks `state`, `version`, and `appliedEvents`

### TestProjectorHarness
- Wraps any `Projector` and feeds it typed events (auto-encoded)
- Auto-increments global positions

### TestProcessManagerHarness
- Value type for testing process managers in isolation without an event store or runner
- Routes events through `AnyReaction.tryRoute` then `AnyReaction.handle`
- Tracks per-entity `states` and accumulated `output` events

## Other Changes
- Made `AnyReaction.tryRoute` and `AnyReaction.handle` public (previously internal) so `SongbirdTesting` can access them

## Refactoring
- Removed duplicated projector definitions and `makeRecordedEvent()` helper from `ProjectionPipelineTests.swift`
- Replaced manual `RecordedEvent` construction with convenience initializer in `ProcessManagerTests.swift` and `GatewayTests.swift`
