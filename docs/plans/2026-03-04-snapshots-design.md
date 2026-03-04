# Snapshots Design

**Date:** 2026-03-04
**Status:** Approved

## Problem

`AggregateRepository.load()` and `AggregateStateStream` fold every event from position 0 on every load. For aggregates with long event histories, this becomes a performance bottleneck. Snapshots let us save a checkpoint of the aggregate state at a known version and resume folding from there.

## Solution

A `SnapshotStore` protocol defines save/load for aggregate state. `AggregateRepository` and `AggregateStateStream` accept an optional `SnapshotStore` and use it to skip replaying old events. A `SnapshotPolicy` enum controls automatic snapshotting (every N events or explicit only). `Aggregate.State` gains a `Codable` constraint so snapshot stores can serialize it.

## Approach

Optional injection with backward-compatible defaults. When no `SnapshotStore` is provided (the default), behavior is unchanged. When provided, `load()` checks for a snapshot first, then folds only events after the snapshot version. Snapshots are saved automatically (per policy) or explicitly.

## Components

### 1. Aggregate Protocol Change

```swift
public protocol Aggregate {
    associatedtype State: Sendable, Equatable, Codable  // Codable added
    associatedtype Event: Songbird.Event
    associatedtype Failure: Error

    static var category: String { get }
    static var initialState: State { get }
    static func apply(_ state: State, _ event: Event) -> State
}
```

All existing aggregate states are value-type structs with `Codable` properties, so this is non-breaking in practice.

### 2. SnapshotStore Protocol

```swift
public protocol SnapshotStore: Sendable {
    func save<A: Aggregate>(
        _ state: A.State,
        version: Int64,
        for stream: StreamName
    ) async throws

    func load<A: Aggregate>(
        for stream: StreamName
    ) async throws -> (state: A.State, version: Int64)?
}
```

Returns `nil` when no snapshot exists. The `version` is the stream position of the last event folded into this state. On load, the repository reads events from `version + 1` onward.

### 3. SnapshotPolicy

```swift
public enum SnapshotPolicy: Sendable {
    case none
    case everyNEvents(Int)
}
```

With `.everyNEvents(n)`, the repository saves a snapshot after `execute()` when the new version crosses an N-event threshold since the last snapshot.

### 4. AggregateRepository Changes

```swift
public struct AggregateRepository<A: Aggregate>: Sendable {
    public let store: any EventStore
    public let registry: EventTypeRegistry
    public let snapshotStore: (any SnapshotStore)?
    public let snapshotPolicy: SnapshotPolicy

    public init(
        store: any EventStore,
        registry: EventTypeRegistry,
        snapshotStore: (any SnapshotStore)? = nil,
        snapshotPolicy: SnapshotPolicy = .none
    ) { ... }
}
```

**`load()` changes:**
1. If `snapshotStore` is present, try loading a snapshot for the stream
2. If found, set initial state and start position from snapshot
3. Fold remaining events from `snapshot.version + 1`
4. If no snapshot (or no store), fold from 0 as before

**`execute()` changes:**
After successful append, check snapshot policy. If `.everyNEvents(n)` and enough events have elapsed, save a snapshot of the new state.

**`saveSnapshot(id:)`:**
Explicit method to save a snapshot at any time. Loads the current state and persists it.

### 5. AggregateStateStream Changes

Accepts an optional `SnapshotStore`. During the initial fold (Phase 1), loads a snapshot if available and starts folding from there. No snapshot saving — the state stream is read-only.

### 6. Implementations

**InMemorySnapshotStore** (in `SongbirdTesting`):
- Actor-based, dictionary keyed by `StreamName`
- Stores JSON-encoded state + version

**SQLiteSnapshotStore** (in `SongbirdSQLite`):
- Actor wrapping SQLite connection
- Table: `snapshots(stream_name TEXT PRIMARY KEY, state BLOB, version INTEGER, updated_at TEXT)`
- `INSERT OR REPLACE` for saves (only latest snapshot per stream)

## Impact on Existing Components

- **Aggregate protocol** — `Codable` added to `State` constraint
- **AggregateRepository** — new optional params with backward-compatible defaults
- **AggregateStateStream** — new optional param with backward-compatible default
- **ProcessManagerRunner** — no changes (uses in-memory state cache, not event folding)
- **Projectors, Gateways, Injectors** — no changes
- **EventStore** — no changes
- **Test harnesses** — no changes needed

## Non-Goals

- Snapshot history/versioning — only the latest snapshot per stream is kept
- Snapshot invalidation on schema changes — user responsibility to clear snapshots when aggregate state type changes
- Snapshot-aware test harness — `TestAggregateHarness` tests pure logic, doesn't need snapshots
