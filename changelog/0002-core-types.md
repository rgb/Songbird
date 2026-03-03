# 0002 — Core Domain Types

Implemented the foundational protocols and types for Songbird (Phase 1):

- **StreamName** — Structured stream identity (category + optional entity ID)
- **Event** — Protocol for immutable domain events (Sendable + Codable + Equatable)
- **EventMetadata** — Tracing fields (traceId, causationId, correlationId, userId)
- **RecordedEvent** — Raw event envelope from the store with decode() bridge
- **EventEnvelope\<E\>** — Typed event wrapper for user code
- **Command** — Protocol for imperative requests (Sendable)
- **Aggregate** — Protocol with static apply for pure state folding
- **Projector** — Protocol for event-driven read model updates
- **EventStore** — Protocol for append-only event persistence with optimistic concurrency
- **ProcessManager** — Protocol stub for event-to-command state machines
- **Gateway** — Protocol stub for external side effect boundaries
- **VersionConflictError** — Error type for optimistic concurrency failures

33 tests across 12 suites, all passing, zero warnings.
