# 0008 -- Process Manager Runtime

Implemented Phase 7 of Songbird:

**EventReaction protocol:**
- Typed per-event-type handlers with 3 required methods (`eventTypes`, `route`, `apply`)
- Default implementations for `decode` (JSON via `RecordedEvent.decode`) and `react` (empty)
- Override `react` to produce output events, override `decode` for event versioning

**AnyReaction type erasure:**
- Two-phase design separating routing (`tryRoute`) from handling (`handle`)
- Solves the chicken-and-egg problem: route is needed to look up per-entity state before handle
- Event is decoded twice (once per phase) -- acceptable tradeoff for clean separation
- `@unchecked Sendable` for Swift 6.2 metatype capture in pure static method closures

**ProcessManager protocol (redesigned):**
- Replaces Phase 1 stub (`InputEvent`, `OutputCommand`, `apply`, `commands`)
- New shape: `processId`, `initialState`, `reactions: [AnyReaction<State>]`
- `reaction(for:categories:)` helper bridges `EventReaction` into `AnyReaction`
- Output is events (not commands) for pure event choreography

**ProcessManagerRunner actor:**
- Subscribes to all categories from PM reactions via `EventSubscription`
- Two-phase dispatch: `tryRoute` for routing, `handle` for state + output
- Per-entity state cache with `state(for:)` accessor
- Appends output events to `StreamName(category: PM.processId, id: instanceId)`
- First-match-wins for reaction dispatch, silent skip on decode errors

**ProcessStateStream:**
- Reactive `AsyncSequence<PM.State>` for a specific entity instance
- Subscribes to PM categories, filters by route matching instance ID
- Folds through matching reactions, yields state on each change
- Same pattern as `AggregateStateStream` but multi-category + reaction-based

32 new tests. 178 tests total across 26 suites, all passing, zero warnings.
