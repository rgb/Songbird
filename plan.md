# Songbird Framework Evolution Plan

## Context

Songbird aims to be a general-purpose event-sourced web framework/component for Swift, built on Hummingbird, SQLite/Postgres (write model), and DuckDB via Smew (read model). We have two mature references: the ether codebase (83 iterations of a domain-specific event-sourced system) and two thoroughly analyzed books on event sourcing. The task is to extract, generalize, and elegantly package these proven patterns into a reusable Swift framework.

The guiding philosophy: **leverage Swift's type system to make incorrect usage impossible at compile time wherever we can.** Value types for pure operations, actors for stateful coordination, protocols for extension points. Clean, minimal, no unnecessary abstraction.

**Confirmed decisions:**
- GitHub repo: `rgb/Songbird`
- Multi-module from day one (5 modules)
- Method-based command handling (each command is its own type, handler is a typed closure)

---

## Phase 0: Project Scaffold & Initial Commit

**Goal:** Establish the repo, folder structure, and package manifest. Push to `github.com/rgb/Songbird`.

- `git init` the Songbird root (preserving existing files: CLAUDE.md, books.md, research/, ether/, smew/)
- Create `Package.swift` with a multi-module structure:
  - **`Songbird`** -- Core protocols and types (zero dependencies beyond Foundation)
  - **`SongbirdSQLite`** -- SQLite event store implementation (depends on `Songbird` + `SQLite.swift`)
  - **`SongbirdSmew`** -- DuckDB read model implementation (depends on `Songbird` + `Smew`)
  - **`SongbirdHummingbird`** -- Hummingbird integration (depends on `Songbird` + `Hummingbird`)
  - **`SongbirdTesting`** -- In-memory implementations and test utilities (depends on `Songbird`)
- Create `Sources/` and `Tests/` directories for each module
- Create `concept/` and `changelog/` folders
- Add `.gitignore` (Swift/SPM standard)
- Write `0001-project-scaffold.md` to changelog
- Initial commit, create GitHub repo, push

**Files:**
- `Package.swift` (multi-module, Swift 6.2+, initially only `Songbird` target compiles -- others added as we reach their phase)
- `Sources/Songbird/` (placeholder export file)
- `Tests/SongbirdTests/` (placeholder test file)
- `.gitignore` (Swift/SPM standard + ignore `ether/`, `smew/`, `*.epub` -- these are local reference materials, not part of the framework package)
- `changelog/0001-project-scaffold.md`

**Note:** `ether/` and `smew/` are local reference repos for our development -- they are not submodules or dependencies of the Songbird package. Smew will be referenced as a proper SPM dependency (`github.com/rgb/smew`) when we reach Phase 4.

---

## Phase 1: Core Domain Types (the `Songbird` module)

**Goal:** Define the fundamental protocols and types that everything else builds on. Zero dependencies. Pure Swift.

### 1a: Stream Names
- `StreamName` struct: category + optional entity ID
  - `StreamName("order-123")` -> category: `order`, id: `123`
  - `StreamName(category: "order")` -> category stream (no ID)
  - Command streams: `StreamName(category: "order", qualifier: "command", id: "123")`
  - Parsing: split on first `-` for entity streams
- `CustomStringConvertible`, `Hashable`, `Sendable`, `Codable`

### 1b: Events
- `Event` protocol: requires `Sendable`, `Codable`, `Equatable`
  - `static var eventType: String` -- past-tense name (e.g. `"OrderPlaced"`)
- `EventEnvelope<E: Event>` struct: wraps an event with store-assigned metadata
  - `event: E`
  - `id: UUID`
  - `streamName: StreamName`
  - `position: Int64` (position within stream)
  - `globalPosition: Int64` (position across entire store)
  - `timestamp: Date`
  - `metadata: EventMetadata`
- `EventMetadata` struct:
  - `traceId: String?` -- correlates all messages from one user action
  - `causationId: String?` -- the event/command that caused this
  - `correlationId: String?` -- links related events
  - `userId: String?`
- `AnyEventEnvelope` type-erased wrapper for heterogeneous stream reading

### 1c: Commands
- `Command` protocol: requires `Sendable`
  - `static var commandType: String` -- imperative name (e.g. `"PlaceOrder"`)

### 1d: Aggregate
- `Aggregate` protocol:
  - `associatedtype State: Sendable, Equatable`
  - `associatedtype Event: Songbird.Event`
  - `associatedtype Failure: Error`
  - `static var initialState: State`
  - `static func apply(_ state: State, _ event: Event) -> State` -- pure, no throws
  - Command handling via typed methods on the aggregate (not a single `handle` dispatch)
- Key insight: `apply` is a static func on value types -- **the compiler enforces purity**. No `self` mutation, no side effects, just `(State, Event) -> State`.

### 1e: Projection
- `Projector` protocol:
  - `associatedtype Event: Songbird.Event`
  - `func apply(_ envelope: EventEnvelope<Event>) async throws`
  - `var subscriberId: String { get }`

### 1f: Process Manager (protocol only, implementation in Phase 6)
- `ProcessManager` protocol:
  - `associatedtype State: Sendable`
  - `associatedtype InputEvent: Songbird.Event`
  - `associatedtype OutputCommand: Songbird.Command`
  - `static var initialState: State`
  - `static func apply(_ state: State, _ event: InputEvent) -> State`
  - `static func commands(_ state: State, _ event: InputEvent) -> [OutputCommand]`

**Review checkpoint:** Do the protocols feel right? Are they minimal? Can we express real use cases with them?

---

## Phase 2: Event Store

**Goal:** Define the event store contract and build two implementations.

### 2a: EventStore Protocol
- `EventStore` protocol (in `Songbird` module):
  - `func append<E: Event>(_ event: E, to stream: StreamName, metadata: EventMetadata, expectedVersion: Int64?) async throws -> EventEnvelope<E>`
  - `func readStream(_ stream: StreamName, from position: Int64, maxCount: Int) async throws -> [AnyEventEnvelope]`
  - `func readCategory(_ category: String, from globalPosition: Int64, maxCount: Int) async throws -> [AnyEventEnvelope]`
  - `func readLastEvent(in stream: StreamName) async throws -> AnyEventEnvelope?`
  - `func streamVersion(_ stream: StreamName) async throws -> Int64`
- `VersionConflictError` with stream name, expected version, actual version
- Type-safe event registry for deserialization (map `eventType` string -> concrete type)

### 2b: InMemoryEventStore (in `SongbirdTesting` module)
- Actor-based, stores events in arrays
- Full protocol conformance
- Useful for unit testing without any database

### 2c: SQLiteEventStore (in `SongbirdSQLite` module)
- Actor wrapping SQLite.swift connection
- Schema based on ether's proven design:
  - `events` table with `sequence_number`, `event_type`, `stream_name`, `position`, `payload` (JSON), `metadata` (JSON), `recorded_at`, `event_hash`
  - WAL mode, `NORMAL` synchronous
- SHA-256 hash chaining (from ether)
- Optimistic concurrency via `expectedVersion`
- Version-tracked migrations
- `EventTypeRegistry` for deserializing stored JSON back to typed events

**Review checkpoint:** Write real tests using both stores. Verify append, read, concurrency control, hash chain verification.

---

## Phase 3: Aggregate Execution

**Goal:** Build the machinery to load aggregate state and execute commands.

### 3a: Aggregate Loading
- `AggregateRepository<A: Aggregate>`:
  - Backed by an `EventStore`
  - `func load(id: StreamName) async throws -> (state: A.State, version: Int64)`
    - Reads all events from the entity stream, folds through `A.apply`
  - `func execute<C: Command>(_ command: C, on id: StreamName, handler: (A.State, C) throws(A.Failure) -> [A.Event]) async throws -> [EventEnvelope<A.Event>]`
    - Load current state -> validate + produce events -> append with expected version -> return envelopes

### 3b: Command Handler Pattern (method-based)
- Each command is its own type conforming to `Command`
- Handler is a typed closure passed to `repository.execute()`:
  ```swift
  let events = try await repository.execute(
      PlaceOrder(itemId: "abc"),
      on: orderStreamName,
      metadata: metadata
  ) { state, command in
      guard !state.isPlaced else { throw OrderError.alreadyPlaced }
      return [.orderPlaced(itemId: command.itemId, ...)]
  }
  ```
- The repository manages the load-validate-append cycle with optimistic concurrency
- Aggregates can also define static handler methods for organization:
  ```swift
  extension OrderAggregate {
      static func handle(_ cmd: PlaceOrder, given state: State) throws(Failure) -> [Event] { ... }
  }
  ```

**Review checkpoint:** Build a simple example aggregate (e.g., BankAccount or Counter), test command handling, verify optimistic concurrency under contention.

---

## Phase 4: Projection Pipeline

**Goal:** Async event delivery from store to projectors, with the waiter pattern from ether.

### 4a: ProjectionPipeline
- Actor using `AsyncStream` (proven pattern from ether)
- `enqueue(envelope: AnyEventEnvelope)` -- non-blocking
- `run()` -- processes events, dispatches to registered projectors
- `waitForProjection(upTo globalPosition: Int64, timeout: Duration) async throws`
- `waitForIdle(timeout: Duration) async throws`
- `stop()`
- Projector registration at startup

### 4b: DuckDBProjectionStore (in `SongbirdSmew` module)
- Actor wrapping Smew `Database` + `Connection`
- Schema migration support
- `RowDecoder` with `.convertFromSnakeCase` (proven pattern)
- Query helpers using `QueryFragment` / `@QueryBuilder`

### 4c: InMemoryProjectionStore (in `SongbirdTesting`)
- Simple dictionary-based projection storage for tests

**Review checkpoint:** End-to-end test: append event -> pipeline delivers -> projector updates read model -> query returns correct data.

---

## Phase 5: Subscription Engine

**Goal:** Polling-based subscription for continuous event processing (aggregators, components).

### 5a: Subscription Protocol & Runner
- `Subscription` struct/actor:
  - `streamName: String` (category stream)
  - `subscriberId: String`
  - `handlers: [String: (AnyEventEnvelope) async throws -> Void]` (keyed by event type)
  - `messagesPerTick: Int` (default 100)
  - `tickInterval: Duration` (default .milliseconds(100))
- `SubscriptionRunner`:
  - Polling loop: load position -> fetch batch -> process sequentially -> persist position
  - Position stored as events in a subscriber position stream (Garofolo pattern) or in a dedicated table
  - Idempotency: handlers must be idempotent; position is a performance optimization
  - Graceful stop via `keepRunning` flag

### 5b: Position Tracking
- Position persistence in the event store itself (subscriber position stream) or in a separate lightweight store
- Load on startup, persist every N messages

**Review checkpoint:** Test subscription with multiple handlers, verify position tracking survives restart, verify idempotent reprocessing.

---

## Phase 6: Process Manager Runtime

**Goal:** Execute process managers that consume events and emit commands.

### 6a: ProcessManagerRunner
- Loads process manager state from its own event stream (or a dedicated store)
- Subscribes to input event category
- On each event: apply to state, compute output commands, write commands to target streams
- One instance per process flow (e.g., per order ID)
- Position tracking like subscriptions

### 6b: ProcessManagerRepository
- Similar to `AggregateRepository` but for process managers
- Manages state loading, event application, command emission

**Review checkpoint:** Build a simple multi-step process (e.g., order fulfillment: reserve -> pay -> ship). Test happy path and failure/compensation paths.

---

## Phase 7: Hummingbird Integration

**Goal:** Make it natural to use Songbird in a Hummingbird web application.

### 7a: SongbirdServices
- `SongbirdServices` struct (Sendable): holds event store, projection pipeline, subscription runners
- Injected into Hummingbird's request context

### 7b: Middleware
- `ProjectionFlushMiddleware` (from ether): ensures read-after-write consistency in tests/development
- Request ID / trace ID middleware

### 7c: Route Helpers
- `appendAndProject()` helper: append event -> enqueue to pipeline -> return
- Response helpers for async-aware patterns (polling, 202 Accepted)

**Review checkpoint:** Build a minimal Hummingbird app with Songbird. Test full HTTP request -> command -> event -> projection -> query cycle.

---

## Phase 8: Gateway Pattern

**Goal:** Clean boundary for external side effects.

### 8a: Notifier Protocol
- `Notifier` protocol: receives events, performs outbound side effects
- Must be idempotent
- Runs as a subscription to event categories
- Examples: email sending, webhook delivery, external API calls

### 8b: Injector Protocol
- `Injector` protocol: brings external events into the system
- Examples: webhook receivers, IoT data ingestion, scheduled events

**Review checkpoint:** Build a test notifier (e.g., mock email sender). Verify idempotent delivery.

---

## Phase 9: Event Versioning

**Goal:** Support immutable event schemas with clean version evolution.

### 9a: Versioned Event Types
- Convention: `OrderPlaced_v1`, `OrderPlaced_v2` as separate types conforming to `Event`
- `EventUpcast` protocol: `func upcast(_ old: OldEvent) -> NewEvent`
- Upcasting chain registered in the `EventTypeRegistry`
- During projection replay, old events are automatically upcast to the latest version

### 9b: Registry-Based Deserialization
- `EventTypeRegistry`: maps `eventType` string -> concrete type + optional upcast chain
- Used by the event store during reads

**Review checkpoint:** Test reading old-format events, verify upcasting produces correct current-version events.

---

## Phase 10: Snapshots

**Goal:** Performance optimization for aggregates with long event histories.

### 10a: Snapshot Protocol
- `SnapshotStore` protocol:
  - `func save<A: Aggregate>(state: A.State, version: Int64, for stream: StreamName) async throws`
  - `func load<A: Aggregate>(for stream: StreamName) async throws -> (state: A.State, version: Int64)?`
- Hidden behind `AggregateRepository` -- callers don't know about snapshots
- Load snapshot -> replay only events after snapshot version

### 10b: SQLite Snapshot Store
- Separate table or database for snapshots
- JSON-encoded aggregate state + version

### 10c: Snapshot Policy
- Configurable: every N events, or on explicit request
- Automatic snapshotting in `AggregateRepository.execute()`

**Review checkpoint:** Benchmark aggregate loading with and without snapshots on a stream with many events.

---

## Phase 11: Compaction

**Goal:** Manage storage growth by archiving old events and maintaining chain continuity.

Compaction builds on snapshots (Phase 10) -- you need a snapshot before you can safely delete old events, since aggregate loading must still work.

### 11a: Archive Service
- Archive old events to a separate SQLite database file
- Configurable cutoff (by date or by sequence number)
- Copy events to archive, then delete from live store

### 11b: Chain Boundary
- Record the last hash before deletion in a `compaction_boundaries` table
- `compactionStartingHash()` returns the boundary hash instead of `"genesis"` after compaction
- Chain verification starts from the boundary, not from genesis

### 11c: Projection Rebuild Safety
- Ensure projections can still be rebuilt from remaining events + snapshots
- Compaction must not delete events that projections haven't processed yet

**Review checkpoint:** Archive events, verify chain still verifies from boundary, verify projections rebuild correctly from post-compaction state.

---

## Cross-Cutting: Testing Utilities (`SongbirdTesting` module)

Built incrementally across phases:
- `InMemoryEventStore` (Phase 2)
- `InMemoryProjectionStore` (Phase 4)
- `TestAggregateHarness<A>`: feed commands, assert events, inspect state
- `TestProjectorHarness<P>`: feed events, assert projection state
- `TestProcessManagerHarness<PM>`: feed events, assert emitted commands

---

## Review Cadence

After each phase:
1. Review all code for clarity, minimalism, and correctness
2. Ensure tests pass with zero warnings
3. Check that protocols are minimal -- no method that isn't needed yet
4. Check that implementations don't leak abstractions
5. Commit with a changelog entry
6. Decide if any refactoring is needed before the next phase

---

## Immediate Next Steps

1. **Phase 0**: Initialize git repo, create Package.swift, push to GitHub
2. **Phase 1**: Core types -- this is where we spend the most design energy, because everything builds on these protocols
