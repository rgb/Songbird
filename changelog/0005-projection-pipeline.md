# 0005 — Projection Pipeline

Implemented Phase 4 of Songbird:

- **ProjectionPipeline** — Actor-based async event delivery from write model to read model projectors
  - AsyncStream for non-blocking event enqueueing
  - Multi-projector dispatch (each projector receives all events, filters internally)
  - Error isolation (projection failures don't stop the pipeline)
  - Waiter pattern with timeout for read-after-write consistency
  - `waitForProjection(upTo:)` and `waitForIdle()` for synchronization
  - Timeout Tasks are tracked and cancelled on resume/stop (no orphaned timers)
- **ProjectionPipelineError** — Timeout error for waiter expiration

15 tests covering dispatch, error isolation, waiter pattern, lifecycle, and edge cases.
100 tests total across 17 suites, all passing, zero warnings.
