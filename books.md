# Event Sourcing Books: Comparative Analysis

Two books serve as conceptual foundations for Songbird:

1. **Practical Microservices** by Ethan Garofolo (Pragmatic Bookshelf, 2020) -- uses Node.js + PostgreSQL (Message DB)
2. **Real-World Event Sourcing** by Kevin Hoffman (Pragmatic Bookshelf, 2025) -- uses Elixir + Commanded/EventStoreDB/NATS

Both are opinionated and practical, but they come from different angles and don't agree on everything.

---

## Book Overviews

### Practical Microservices (Garofolo)

**Central thesis:** A monolith is a *data model*, not a deployment strategy. The productivity wall teams hit comes from coupling inherent in CRUD-based data models. The solution is autonomous components communicating through asynchronous messages, with state stored as append-only event streams.

**Approach:** Builds a complete video tutorial platform ("Video Tutorials") incrementally across 15 chapters. Starts with a traditional Express app, evolves it into a fully event-sourced system with autonomous components, aggregators, and view data. Very hands-on, code-heavy, and opinionated about architecture.

**Key architectural vocabulary:**
- **Message Store** -- PostgreSQL-backed (Message DB), serves as both database and transport
- **Components** -- autonomous processors subscribing to command streams
- **Aggregators** -- processors subscribing to event streams, populating View Data
- **Applications** -- stateless HTTP handlers that write commands and read View Data
- **View Data** -- denormalized read models optimized for specific screens
- **Projections** -- on-demand entity state derivation by folding events (used inside components)

### Real-World Event Sourcing (Hoffman)

**Central thesis:** Everything is event-sourced -- the state of any application is best understood as derived from a sequence of immutable events. Introduces formal "Laws of Event Sourcing" as hard rules learned from production failures.

**Approach:** Builds a game ("Lunar Frontiers") progressively, starting from a simple calculator example. More theoretical and pattern-oriented than Garofolo. Covers a wider range of event store implementations (EventStoreDB, Postgres/Commanded, NATS, Redis). Code in Elixir.

**Key architectural vocabulary:**
- **Aggregates** -- entities that validate commands and emit events, with private internal state
- **Projectors** -- processors that build read-model projections from events
- **Process Managers** -- event-consuming, command-emitting state machines for multi-step workflows
- **Gateways** (Injectors + Notifiers) -- boundary components for external system interaction
- **Event Store** -- separated into event log, aggregate snapshots, and projections (potentially different storage backends)

---

## Where They Agree

### Events as the single source of truth
Both books are unequivocal: events are immutable, named in past tense, and constitute the only authoritative record of what happened. Everything else (read models, aggregate state, projections) is derived and disposable.

### CQRS is natural and necessary
Both treat Command-Query Responsibility Segregation as the natural consequence of event sourcing. You write in one shape (events) and read in one or more other shapes (projections/view data). Neither treats CQRS as optional once you commit to event sourcing.

### Commands vs. events
- **Commands**: imperative requests that may be rejected (Register, Send, PublishVideo)
- **Events**: immutable facts of what happened (Registered, Sent, VideoPublished)
- A command represents what was *requested*; an event represents what *actually happened*

### State is derived by folding
Both describe the fundamental equation: `f(state, event) = state'`. Current state is produced by reducing/folding a function over the event stream, starting from an initial state.

### Read models are disposable
Projections / view data can be destroyed and regenerated from the event log at any time. They are not the source of truth. Both books design their read models with this disposability in mind.

### Idempotency is essential
Both emphasize that handlers must be idempotent because messages may be delivered more than once. Exactly-once delivery is either impossible (Garofolo) or requires specific infrastructure guarantees (Hoffman).

### Testing is a strength
Both highlight that event sourcing enables straightforward testing: supply input (commands/events), assert output (events/projections). Aggregates and projectors are essentially pure functions.

### Don't make business decisions from read models
Both books warn against using eventually-consistent read data for business logic. Garofolo: "decisions should not be made based on view data." Hoffman (Law): "Process Managers Must Not Read from Projections."

### Event naming matters
Both insist on domain-specific, past-tense event names. Garofolo: "Your users aren't getting created when they register. They're registering." Hoffman: "Events are named in the past tense -- they represent things that actually happened."

---

## Where They Disagree

### Formal aggregates vs. implicit command handling

**Hoffman** defines aggregates formally: a uniquely identifiable entity with private state that validates commands and emits events. Aggregate state is explicitly *not* for external consumption. He treats aggregates as a core primitive with strict rules.

**Garofolo** has no formal aggregate concept. Command handling happens directly in components (which are subscription-based processors). Entity state is derived on-demand via projections inside the component's handler pipeline. The "aggregate" is implicit -- it's the projection of an entity stream used to make idempotency decisions.

**Impact for Songbird:** Hoffman's formal aggregate model provides clearer boundaries and is more amenable to framework abstraction. Garofolo's approach is simpler but harder to generalize.

### Process managers / sagas

**Hoffman** dedicates significant attention to process managers: event-consuming, command-emitting state machines with formal rules (one flow per manager, no reading projections, discrete beginning/middle/end). He treats them as a core architectural primitive alongside aggregates and projectors.

**Garofolo** handles multi-step processes through component orchestration -- one component writes commands to another component's command stream and watches for resulting events via `originStreamName` filtering. There is no formal "process manager" abstraction, but the pattern exists implicitly. He favors *orchestration* (explicit commands) over *choreography* (reactive event watching).

**Impact for Songbird:** Both patterns have merit. Hoffman's process manager is more formal and reusable; Garofolo's orchestration pattern is simpler and may suffice for many use cases.

### Side effects and external interactions

**Hoffman** has a strict rule: "Work Is a Side Effect." Aggregates, projectors, and process managers must *never* perform side effects. All external interaction goes through **gateways** (injectors for inbound, notifiers for outbound). This is a hard law.

**Garofolo** handles side effects pragmatically within components. The email-sending component directly calls the email API from within its handler. The decision of "check before or after" is a business decision made per-case. There is no formal gateway abstraction.

**Impact for Songbird:** Hoffman's gateway pattern provides a cleaner architectural boundary. Worth considering for the framework.

### Event schema evolution / versioning

**Hoffman** has a definitive stance: "Event Schemas Are Immutable" (Law 8). Any change produces a brand-new event type. He explicitly warns against the "backward compatibility trap" -- adding optional fields to existing events is a mistake because default values inject assumptions from outside the event stream.

**Garofolo** punts on versioning entirely, recommending Greg Young's book on event versioning and simply advising: "First of all, don't" change message contracts. He emphasizes upfront design of contracts over evolution strategies.

**Impact for Songbird:** Hoffman's strict versioning stance is the safer foundation. The framework should make it easy to define new event versions and handle multiple versions in projectors.

### Snapshots

**Hoffman** treats snapshots as a first-class concept integral to production systems. Aggregate state *is* a snapshot. He discusses snapshot-aware storage, keeping recent checkpoints, and using snapshots to bound the "live" event log. He recommends key-value stores optimized for O(1) reads for snapshot storage.

**Garofolo** acknowledges snapshots as a performance optimization but does not implement them. He notes they should be hidden behind the `fetch` function and become important only when streams have many events. His stance: "Computers are fast, and snapshots won't make a huge difference until you start having a lot of events in the same stream."

**Impact for Songbird:** Snapshots should be a supported (if initially optional) feature. Hoffman's approach of separate storage for snapshots vs. event log is worth considering.

### Storage architecture

**Hoffman** advocates strongly for choosing storage *separately* for each data type:
1. Event log -> time-series or specialized event store
2. Aggregate state/snapshots -> key-value / document store
3. Projections -> varies (relational, graph, key-value)

He discusses EventStoreDB, PostgreSQL, Redis, and NATS as concrete options.

**Garofolo** uses a single PostgreSQL instance for everything (Message DB for events, regular tables for view data). His philosophy is simpler operationally: PostgreSQL is battle-hardened and already familiar.

**Impact for Songbird:** The ether reference implementation already splits storage (SQLite for events, DuckDB for projections). Songbird should formalize this split while keeping it configurable.

### The role of the message store as transport

**Garofolo** is emphatic that the message store is both a *database* and a *transport*. Components communicate by reading from shared streams in the same message store. There is no separate message broker. He explicitly argues against Kafka for this role.

**Hoffman** treats the event store primarily as storage and discusses separate transport mechanisms (NATS, Kafka) for event distribution. He separates the concerns of durable storage from message delivery.

**Impact for Songbird:** Garofolo's unified approach (store = transport) is simpler for a single-process system like ether. Hoffman's separated approach scales better for distributed systems. Songbird could start unified and support separation later.

### Subscription mechanism

**Garofolo** uses polling-based subscriptions: components periodically query the message store for new messages. He defends polling as "reliable and simple." Subscriber position is tracked in the message store itself (as events in a position stream).

**Hoffman** uses push-based subscriptions via frameworks (Commanded subscriptions, NATS consumers). Position tracking is handled by the infrastructure (durable consumers, subscription checkpoints).

**Impact for Songbird:** Polling is simpler to implement initially and aligns with ether's current approach. Push-based can be added later.

### Concurrency control

**Garofolo** uses optimistic concurrency via `expectedVersion` on writes. The message store raises a version conflict error if the stream has advanced beyond the expected version. He recommends this on *all* writes.

**Hoffman** does not emphasize optimistic concurrency as strongly. Aggregates validate commands against current state, which implicitly handles conflicts, but there is less discussion of write-level version checking in the event store itself.

**Impact for Songbird:** Optimistic concurrency control at the event store level is important and should be a core feature, as ether already demonstrates.

---

## Unique Contributions of Each Book

### Garofolo only

- **"A monolith is a data model"** -- reframes the monolith/microservice debate entirely around data coupling rather than deployment
- **Message store as unified database + transport** -- eliminates the need for a separate message broker
- **Contract files** -- each component documents its message types, stream names, and behavior in a `contract.md`
- **traceId propagation** -- all messages from a single user action share a correlation ID for end-to-end debugging
- **originStreamName pattern** -- allows a component to filter another component's events to only those it caused
- **Admin portal / debugging tools** -- complete observability of streams, subscriber positions, and correlated traces
- **"Background jobs are just a degenerate form of streams"** -- no separate job queue infrastructure needed
- **Practical UI patterns** for async systems (polling interstitials, task-based UIs)
- **Economic argument against over-testing** -- diminishing returns, opportunity cost, monitoring as testing

### Hoffman only

- **10 "Laws of Event Sourcing"** -- formalized rules with clear rationale, learned from production failures
- **Formal aggregate pattern** with strict rules about private state and pure functions
- **Process manager as a core primitive** -- event-consuming, command-emitting state machines
- **Gateway pattern** (injectors/notifiers) -- clean boundary for all external side effects
- **Event schema immutability** and the "backward compatibility trap" -- definitive stance on versioning
- **Multiple event store implementations** compared (EventStoreDB, Postgres/Commanded, NATS/JetStream, Redis)
- **Cloud Events specification** as a standardized event envelope format
- **Schema definition languages** comparison (JSON Schema, Protocol Buffers, Avro)
- **Event modeling tools** (Event Storming, AsyncAPI, Event Catalog, RDF/Turtle)
- **Edge/geographic distribution** patterns and eventual consistency strategies
- **CRDTs** as a tool for distributed projection consistency
- **Separate storage per data type** -- different databases for event log, snapshots, and projections

---

## Synthesis for Songbird

Drawing from both books and the ether reference implementation, Songbird's architecture should incorporate:

| Concept | Source | Priority |
|---------|--------|----------|
| Append-only event store with optimistic concurrency | Both + ether | Core |
| Formal aggregate protocol (validate commands, emit events) | Hoffman | Core |
| Projection/projector protocol for read models | Both + ether | Core |
| Process manager protocol | Hoffman | Core |
| Separate write model (SQLite/Postgres) and read model (DuckDB/Smew) | Ether | Core |
| Subscription mechanism (polling-based initially) | Garofolo + ether | Core |
| Idempotent handlers with position tracking | Both + ether | Core |
| Event versioning via new types (immutable schemas) | Hoffman | Core |
| Snapshot support | Hoffman + ether | Important |
| Gateway/notifier pattern for side effects | Hoffman | Important |
| Hummingbird integration | Ether | Core |
| traceId / correlationId propagation | Both | Important |
| Contract documentation | Garofolo | Nice-to-have |
| Event schema definition (Codable + versioning) | Both | Core |
