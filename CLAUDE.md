# CLAUDE.md

Always make a plan and a todo list first. We want to approach things step by step.

Do a thorough job and do not leave technical debt behind, clean up after yourself.
Do not attempt to find or follow a pragmatic approach when we really need a comprehensive, correct, and clean implementation.
Never adjust or delete tests when the correct approach would be to find and fix the root cause of failing tests.
We always want to have a clean build with neither warnings or errors.

When we commit to git, do not add yourself as co-contributor.

We have documented our concepts in the files located in the concept folder and in various README.md and plan.md files. Always take these into consideration when planning and implementing new features. The changelog folder describes all the features we have already implemented, in order.

When we work out a detailed plan for a feature and are ready to implement it, write the plan to a nnnn-xyz.md file in the changelog folder, where you replace the "nnnn" part with the next highest number relative to the other files in that directory, and where you replace the "xyz" part with a short slug (in kebab-case) describing our plan.

## Project Overview

Songbird is an event-sourced web framework / component library for the [Hummingbird](https://github.com/hummingbird-project/hummingbird) web framework in Swift. It provides the building blocks for event-sourced applications:

- **Write model**: Append-only event store backed by SQLite (and later PostgreSQL)
- **Read model**: Materialized projections in DuckDB via [Smew](https://github.com/rgb/smew)
- **Integration**: Designed to work with Hummingbird as the HTTP layer

### Reference Implementations and Resources

- **`ether/`** -- An openEHR Clinical Data Repository that uses exactly these patterns (event-sourced CQRS with SQLite write model + DuckDB/Smew read model + Hummingbird). The architecture is battle-tested through 83 iterations. Use it as a reference, but note that its patterns are domain-specific and not yet generalized into reusable abstractions.
- **`smew/`** -- Our DuckDB wrapper library (github.com/rgb/smew). Provides `Database`, `Connection`, `ConnectionPool` (actor-based), `QueryFragment`/`@QueryBuilder` for safe parameterized queries, `ResultSet.decode()` for Decodable mapping, `Appender` for bulk inserts, and `StreamingResultSet` for lazy async iteration.
- **`books.md`** -- Detailed comparative analysis of the two event sourcing reference books.

### Key Event Sourcing Concepts

These are drawn from the two reference books and the ether implementation. See [books.md](books.md) for the full analysis.

**Core primitives:**
- **Event Store** -- Append-only log of immutable events with optimistic concurrency control. The single source of truth. Events are past-tense domain facts (e.g., `OrderPlaced`, `ItemShipped`).
- **Aggregate** -- An entity that validates commands against current state and emits events. State is derived by folding events. Internal state is private, used only for command validation.
- **Projection / Projector** -- Builds query-optimized read models from events. Projections are disposable and rebuildable. Different projectors must not share projections.
- **Process Manager** -- Consumes events and emits commands to coordinate multi-step workflows. One flow per process manager. Must not read from projections.
- **Gateway** (Injector/Notifier) -- Boundary component for external side effects (email, webhooks, APIs). Core primitives (aggregates, projectors, process managers) must never perform side effects directly.

**Key patterns:**
- Commands are requests (imperative); events are facts (past tense). Commands may be rejected; events are immutable.
- State = fold(events). `f(state, event) = state'`
- Read models are eventually consistent and never the source of truth for business decisions.
- All handlers must be idempotent (messages may be delivered more than once).
- Event schemas are immutable -- any change produces a new event type/version.
- Subscription-based event processing with position tracking (polling-based initially).

**Ether's proven architecture flow:**
```
HTTP Request
  -> Route Handler (command validation)
  -> EventStore.append(event)           [Write: SQLite, append-only, hash-chained]
  -> ProjectionPipeline.enqueue()       [Async bridge via AsyncStream]
  -> ReadModelStore.apply(event)        [Read: DuckDB/Smew, materialized projections]
  -> Query Engine                       [Query: domain query -> SQL]
```

**What Songbird should generalize from ether:**
- `DomainEvent` pattern with metadata + typed payload + serialization
- `EventStore` actor with append-only semantics, optimistic concurrency, migrations
- `ProjectionPipeline` actor with async stream, waiter support, timeout
- `ReadModelStore` actor with event dispatch + query methods
- Schema derivation (domain model -> read model schema)
- Separate write model (SQLite/Postgres) and read model (DuckDB/Smew) storage

**What ether does NOT have (that Songbird should add):**
- Formal `Aggregate` protocol (ether does command handling in route handlers)
- Formal `Command` protocol
- Generic `EventStore` protocol (ether's is concrete SQLite)
- Generic `Projection` protocol (ether's handlers are hardcoded case statements)
- Process manager abstraction
- Event versioning/upcasting
- Gateway/notifier abstraction

## Swift Algorithms / Swift Async Algorithms
- [https://github.com/apple/swift-algorithms](Swift Algorithms)
- [https://github.com/apple/swift-async-algorithms](Swift Async Algorithms)

Familiarise yourself with Swift Algorithms and Swift Async Algorithms and utilise them where appropriate.

## Swift Concurrency

Use the reading list at [research/00-swift-concurrency-zero-to-hero.md](research/00-swift-concurrency-zero-to-hero.md) for guidance. For most cases, the information in levels 0, 1, and 2 should be sufficient. I'll list the links here as well.

Level 0:
- [research/01-approachable-swift-concurrency.md](research/01-approachable-swift-concurrency.md)
- [research/02-swift-book-concurrency.md](research/02-swift-book-concurrency.md)

Level 1:
- [research/03-step-by-step-network-request.md](research/03-step-by-step-network-request.md)
- [research/04-step-by-step-reading-from-storage.md](research/04-step-by-step-reading-from-storage.md)
- [research/05-step-by-step-stateful-systems.md](research/05-step-by-step-stateful-systems.md)
- [research/06-step-by-step-conforming-to-protocols.md](research/06-step-by-step-conforming-to-protocols.md)
- [research/07-concurrency-glossary.md](research/07-concurrency-glossary.md)

Level 2:
- [research/08-swift-concurrency-waits-for-no-one.md](research/08-swift-concurrency-waits-for-no-one.md)
