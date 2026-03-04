# Snapshots Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add snapshot support to Songbird so aggregates with long event histories can load quickly by resuming from a saved state checkpoint.

**Architecture:** A `SnapshotStore` protocol defines save/load for aggregate state. `AggregateRepository` and `AggregateStateStream` accept an optional `SnapshotStore` (defaulting to `nil` for backward compatibility). A `SnapshotPolicy` enum controls automatic snapshotting after `execute()`. Implementations: `InMemorySnapshotStore` (testing) and `SQLiteSnapshotStore` (production).

**Tech Stack:** Swift 6.2+, Swift Testing (@Test, #expect), SQLite.swift

**Design doc:** `docs/plans/2026-03-04-snapshots-design.md`

---

### Task 1: Add `Codable` to Aggregate.State Constraint

**Files:**
- Modify: `Sources/Songbird/Aggregate.swift:2`
- Modify: 6 test files (State struct declarations need `Codable` added)

Adding `Codable` to the `Aggregate` protocol's `State` associated type. All existing aggregate state types are simple value-type structs (Int, String, Bool fields) that are implicitly `Codable` — they just need the conformance declared.

**Step 1: Modify the Aggregate protocol**

In `Sources/Songbird/Aggregate.swift`, change line 2 from:

```swift
    associatedtype State: Sendable, Equatable
```

to:

```swift
    associatedtype State: Sendable, Equatable, Codable
```

**Step 2: Fix all test aggregate State declarations**

In each of these files, add `Codable` to the `State` struct declaration:

- `Tests/SongbirdTests/AggregateRepositoryTests.swift:39` — change `struct State: Sendable, Equatable {` to `struct State: Sendable, Equatable, Codable {`
- `Tests/SongbirdTests/AggregateStateStreamTests.swift:10` — change `struct State: Sendable, Equatable {` to `struct State: Sendable, Equatable, Codable {`
- `Tests/SongbirdTests/AggregateTests.swift:6` — change `struct State: Sendable, Equatable {` to `struct State: Sendable, Equatable, Codable {`
- `Tests/SongbirdTestingTests/TestAggregateHarnessTests.swift:8` — change `struct State: Sendable, Equatable {` to `struct State: Sendable, Equatable, Codable {`
- `Tests/SongbirdHummingbirdTests/IntegrationTests.swift:23` — change `struct State: Sendable, Equatable` to `struct State: Sendable, Equatable, Codable`
- `Tests/SongbirdHummingbirdTests/RouteHelperTests.swift:25` — change `struct State: Sendable, Equatable {` to `struct State: Sendable, Equatable, Codable {`

**Step 3: Run the full test suite to verify nothing breaks**

Run: `swift test 2>&1`
Expected: All 254 tests pass. The `Codable` constraint is satisfied by all existing state types.

**Step 4: Commit**

```bash
git add Sources/Songbird/Aggregate.swift Tests/SongbirdTests/AggregateRepositoryTests.swift Tests/SongbirdTests/AggregateStateStreamTests.swift Tests/SongbirdTests/AggregateTests.swift Tests/SongbirdTestingTests/TestAggregateHarnessTests.swift Tests/SongbirdHummingbirdTests/IntegrationTests.swift Tests/SongbirdHummingbirdTests/RouteHelperTests.swift
git commit -m "Add Codable constraint to Aggregate.State for snapshot serialization"
```

---

### Task 2: Create SnapshotStore Protocol and SnapshotPolicy

**Files:**
- Create: `Sources/Songbird/SnapshotStore.swift`

**Step 1: Create the protocol and policy enum**

Create `Sources/Songbird/SnapshotStore.swift`:

```swift
import Foundation

/// A store for aggregate state snapshots, used to optimize loading of aggregates
/// with long event histories.
///
/// Snapshots are checkpoints of an aggregate's state at a known stream version.
/// When loading an aggregate, the repository checks for a snapshot first, then
/// folds only the events after the snapshot version — skipping the full replay.
///
/// Only the latest snapshot per stream is meaningful. Implementations may keep
/// history, but `load` always returns the most recent one.
///
/// ```swift
/// // Save a snapshot after folding events
/// try await snapshotStore.save(state, version: 42, for: stream)
///
/// // Load the latest snapshot (returns nil if none exists)
/// if let snapshot = try await snapshotStore.load(for: stream) as (MyAggregate.State, Int64)? {
///     // Resume folding from snapshot.version + 1
/// }
/// ```
public protocol SnapshotStore: Sendable {
    /// Saves a snapshot of an aggregate's state at the given stream version.
    ///
    /// Replaces any existing snapshot for the same stream. The `version` is the
    /// stream position of the last event folded into this state.
    func save<A: Aggregate>(
        _ state: A.State,
        version: Int64,
        for stream: StreamName
    ) async throws

    /// Loads the latest snapshot for an aggregate stream.
    ///
    /// Returns `nil` if no snapshot exists. The returned `version` is the stream
    /// position of the last event that was folded into the state — the caller
    /// should read events from `version + 1` onward.
    func load<A: Aggregate>(
        for stream: StreamName
    ) async throws -> (state: A.State, version: Int64)?
}

/// Controls when the `AggregateRepository` automatically saves snapshots.
public enum SnapshotPolicy: Sendable, Equatable {
    /// No automatic snapshotting. Use `saveSnapshot(id:)` for explicit saves.
    case none
    /// Save a snapshot every N events since the last snapshot (or since the beginning).
    case everyNEvents(Int)
}
```

**Step 2: Verify it compiles**

Run: `swift build --target Songbird 2>&1`
Expected: Build succeeds.

**Step 3: Commit**

```bash
git add Sources/Songbird/SnapshotStore.swift
git commit -m "Add SnapshotStore protocol and SnapshotPolicy enum"
```

---

### Task 3: Create InMemorySnapshotStore

**Files:**
- Create: `Sources/SongbirdTesting/InMemorySnapshotStore.swift`
- Create: `Tests/SongbirdTestingTests/InMemorySnapshotStoreTests.swift`

**Step 1: Write the failing tests**

Create `Tests/SongbirdTestingTests/InMemorySnapshotStoreTests.swift`:

```swift
import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

// Reuse a minimal aggregate for testing
private enum SnapAggregate: Aggregate {
    struct State: Sendable, Equatable, Codable {
        var count: Int
    }
    enum Event: Songbird.Event {
        case incremented
        var eventType: String { "Incremented" }
    }
    enum Failure: Error { case none }

    static let category = "snap"
    static let initialState = State(count: 0)
    static func apply(_ state: State, _ event: Event) -> State {
        State(count: state.count + 1)
    }
}

@Suite("InMemorySnapshotStore")
struct InMemorySnapshotStoreTests {
    @Test func loadReturnsNilWhenNoSnapshot() async throws {
        let store = InMemorySnapshotStore()
        let stream = StreamName(category: "snap", id: "1")
        let result: (state: SnapAggregate.State, version: Int64)? =
            try await store.load(for: stream) as (SnapAggregate.State, Int64)?
        #expect(result == nil)
    }

    @Test func saveAndLoad() async throws {
        let store = InMemorySnapshotStore()
        let stream = StreamName(category: "snap", id: "1")
        let state = SnapAggregate.State(count: 42)
        try await store.save(state, version: 10, for: stream) as Void
        let loaded: (state: SnapAggregate.State, version: Int64)? =
            try await store.load(for: stream)
        #expect(loaded?.state == state)
        #expect(loaded?.version == 10)
    }

    @Test func saveOverwritesPreviousSnapshot() async throws {
        let store = InMemorySnapshotStore()
        let stream = StreamName(category: "snap", id: "1")
        try await store.save(SnapAggregate.State(count: 1), version: 5, for: stream) as Void
        try await store.save(SnapAggregate.State(count: 99), version: 50, for: stream) as Void
        let loaded: (state: SnapAggregate.State, version: Int64)? =
            try await store.load(for: stream)
        #expect(loaded?.state == SnapAggregate.State(count: 99))
        #expect(loaded?.version == 50)
    }

    @Test func differentStreamsAreIndependent() async throws {
        let store = InMemorySnapshotStore()
        let stream1 = StreamName(category: "snap", id: "1")
        let stream2 = StreamName(category: "snap", id: "2")
        try await store.save(SnapAggregate.State(count: 10), version: 5, for: stream1) as Void
        try await store.save(SnapAggregate.State(count: 20), version: 8, for: stream2) as Void
        let loaded1: (state: SnapAggregate.State, version: Int64)? =
            try await store.load(for: stream1)
        let loaded2: (state: SnapAggregate.State, version: Int64)? =
            try await store.load(for: stream2)
        #expect(loaded1?.state.count == 10)
        #expect(loaded2?.state.count == 20)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter InMemorySnapshotStoreTests`
Expected: FAIL — `InMemorySnapshotStore` not defined

**Step 3: Write the implementation**

Create `Sources/SongbirdTesting/InMemorySnapshotStore.swift`:

```swift
import Foundation
import Songbird

/// An in-memory snapshot store for testing. Stores snapshots in a dictionary
/// keyed by `StreamName`. Each entry holds JSON-encoded state data and the version.
public actor InMemorySnapshotStore: SnapshotStore {
    private var snapshots: [StreamName: (data: Data, version: Int64)] = [:]

    public init() {}

    public func save<A: Aggregate>(
        _ state: A.State,
        version: Int64,
        for stream: StreamName
    ) async throws {
        let data = try JSONEncoder().encode(state)
        snapshots[stream] = (data, version)
    }

    public func load<A: Aggregate>(
        for stream: StreamName
    ) async throws -> (state: A.State, version: Int64)? {
        guard let entry = snapshots[stream] else { return nil }
        let state = try JSONDecoder().decode(A.State.self, from: entry.data)
        return (state, entry.version)
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter InMemorySnapshotStoreTests`
Expected: All 4 tests pass.

**Step 5: Commit**

```bash
git add Sources/SongbirdTesting/InMemorySnapshotStore.swift Tests/SongbirdTestingTests/InMemorySnapshotStoreTests.swift
git commit -m "Add InMemorySnapshotStore for testing"
```

---

### Task 4: Snapshot-Aware AggregateRepository — Load

**Files:**
- Modify: `Sources/Songbird/AggregateRepository.swift`
- Test: `Tests/SongbirdTests/AggregateRepositoryTests.swift`

**Step 1: Write the failing tests**

Add these tests to the `AggregateRepositoryTests` struct in `Tests/SongbirdTests/AggregateRepositoryTests.swift`:

```swift
// MARK: - Snapshot Loading

@Test func loadUsesSnapshotWhenAvailable() async throws {
    let registry = EventTypeRegistry()
    registry.register(BankAccountEvent.self, eventTypes: ["AccountOpened", "AccountDeposited", "AccountWithdrawn"])
    let store = InMemoryEventStore(registry: registry)
    let snapshotStore = InMemorySnapshotStore()

    let repo = AggregateRepository<BankAccountAggregate>(
        store: store,
        registry: registry,
        snapshotStore: snapshotStore
    )

    // Append 3 events
    let stream = StreamName(category: "account", id: "acct-1")
    _ = try await store.append(BankAccountEvent.opened(name: "Alice"), to: stream, metadata: meta, expectedVersion: nil)
    _ = try await store.append(BankAccountEvent.deposited(amount: 100), to: stream, metadata: meta, expectedVersion: nil)
    _ = try await store.append(BankAccountEvent.withdrawn(amount: 30), to: stream, metadata: meta, expectedVersion: nil)

    // Save a snapshot at version 1 (after opened + deposited)
    let snappedState = BankAccountAggregate.State(isOpen: true, balance: 100, name: "Alice")
    try await snapshotStore.save(snappedState, version: 1, for: stream)

    // Load should resume from snapshot, only replaying the withdraw
    let (state, version) = try await repo.load(id: "acct-1")
    #expect(state == BankAccountAggregate.State(isOpen: true, balance: 70, name: "Alice"))
    #expect(version == 2)
}

@Test func loadWithoutSnapshotStillWorks() async throws {
    let registry = EventTypeRegistry()
    registry.register(BankAccountEvent.self, eventTypes: ["AccountOpened", "AccountDeposited", "AccountWithdrawn"])
    let store = InMemoryEventStore(registry: registry)
    let snapshotStore = InMemorySnapshotStore()

    let repo = AggregateRepository<BankAccountAggregate>(
        store: store,
        registry: registry,
        snapshotStore: snapshotStore
    )

    // Append events but no snapshot saved
    let stream = StreamName(category: "account", id: "acct-1")
    _ = try await store.append(BankAccountEvent.opened(name: "Bob"), to: stream, metadata: meta, expectedVersion: nil)
    _ = try await store.append(BankAccountEvent.deposited(amount: 50), to: stream, metadata: meta, expectedVersion: nil)

    let (state, version) = try await repo.load(id: "acct-1")
    #expect(state == BankAccountAggregate.State(isOpen: true, balance: 50, name: "Bob"))
    #expect(version == 1)
}

@Test func loadWithNoSnapshotStoreDefaultsBehavior() async throws {
    // No snapshotStore at all (nil) — existing behavior
    let (repo, store) = makeRepo()
    let stream = StreamName(category: "account", id: "acct-1")
    _ = try await store.append(BankAccountEvent.opened(name: "Carol"), to: stream, metadata: meta, expectedVersion: nil)

    let (state, version) = try await repo.load(id: "acct-1")
    #expect(state == BankAccountAggregate.State(isOpen: true, balance: 0, name: "Carol"))
    #expect(version == 0)
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter AggregateRepositoryTests`
Expected: FAIL — `AggregateRepository` init doesn't accept `snapshotStore`

**Step 3: Modify AggregateRepository**

Replace the entire contents of `Sources/Songbird/AggregateRepository.swift` with:

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
    ) {
        self.store = store
        self.registry = registry
        self.snapshotStore = snapshotStore
        self.snapshotPolicy = snapshotPolicy
    }

    public func load(id: String) async throws -> (state: A.State, version: Int64) {
        let stream = StreamName(category: A.category, id: id)

        // Try loading a snapshot
        var state = A.initialState
        var fromPosition: Int64 = 0
        if let snapshotStore {
            if let snapshot: (state: A.State, version: Int64) = try await snapshotStore.load(for: stream) {
                state = snapshot.state
                fromPosition = snapshot.version + 1
            }
        }

        // Fold events from the snapshot version (or 0 if no snapshot)
        let records = try await store.readStream(stream, from: fromPosition, maxCount: Int.max)
        for record in records {
            let decoded = try registry.decode(record)
            guard let event = decoded as? A.Event else {
                throw AggregateError.unexpectedEventType(record.eventType)
            }
            state = A.apply(state, event)
        }
        let version = records.last?.position ?? (fromPosition > 0 ? fromPosition - 1 : -1)
        return (state, version)
    }

    public func execute<H: CommandHandler>(
        _ command: H.Cmd,
        on id: String,
        metadata: EventMetadata,
        using handler: H.Type
    ) async throws -> [RecordedEvent] where H.Agg == A {
        let (state, version) = try await load(id: id)
        let events = try handler.handle(command, given: state)
        let stream = StreamName(category: A.category, id: id)
        var recorded: [RecordedEvent] = []
        for (index, event) in events.enumerated() {
            let result = try await store.append(
                event,
                to: stream,
                metadata: metadata,
                expectedVersion: version + Int64(index)
            )
            recorded.append(result)
        }
        return recorded
    }

    /// Explicitly saves a snapshot of the aggregate's current state.
    ///
    /// Loads the aggregate from the event store (using any existing snapshot),
    /// then saves the resulting state to the snapshot store.
    public func saveSnapshot(id: String) async throws {
        guard let snapshotStore else { return }
        let stream = StreamName(category: A.category, id: id)
        let (state, version) = try await load(id: id)
        guard version >= 0 else { return }  // no events, nothing to snapshot
        try await snapshotStore.save(state, version: version, for: stream)
    }
}

public enum AggregateError: Error {
    case unexpectedEventType(String)
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter AggregateRepositoryTests`
Expected: All tests pass (existing + 3 new).

**Step 5: Commit**

```bash
git add Sources/Songbird/AggregateRepository.swift Tests/SongbirdTests/AggregateRepositoryTests.swift
git commit -m "Add snapshot-aware loading to AggregateRepository"
```

---

### Task 5: AggregateRepository Auto-Snapshotting in Execute

**Files:**
- Modify: `Sources/Songbird/AggregateRepository.swift`
- Test: `Tests/SongbirdTests/AggregateRepositoryTests.swift`

**Step 1: Write the failing tests**

Add these tests to `AggregateRepositoryTests`:

```swift
// MARK: - Auto-Snapshotting

@Test func executeAutoSnapshotsEveryNEvents() async throws {
    let registry = EventTypeRegistry()
    registry.register(BankAccountEvent.self, eventTypes: ["AccountOpened", "AccountDeposited", "AccountWithdrawn"])
    let store = InMemoryEventStore(registry: registry)
    let snapshotStore = InMemorySnapshotStore()

    let repo = AggregateRepository<BankAccountAggregate>(
        store: store,
        registry: registry,
        snapshotStore: snapshotStore,
        snapshotPolicy: .everyNEvents(2)
    )

    // Event 0: open
    _ = try await repo.execute(OpenAccount(name: "Alice"), on: "acct-1", metadata: meta, using: OpenAccountHandler.self)

    // No snapshot yet (version 0, need 2 events for first snapshot)
    let stream = StreamName(category: "account", id: "acct-1")
    var snapshot: (state: BankAccountAggregate.State, version: Int64)? =
        try await snapshotStore.load(for: stream)
    #expect(snapshot == nil)

    // Event 1: deposit — now at version 1, which is >= 2 events total
    _ = try await repo.execute(Deposit(amount: 100), on: "acct-1", metadata: meta, using: DepositHandler.self)

    snapshot = try await snapshotStore.load(for: stream)
    #expect(snapshot != nil)
    #expect(snapshot?.state == BankAccountAggregate.State(isOpen: true, balance: 100, name: "Alice"))
    #expect(snapshot?.version == 1)
}

@Test func executeWithPolicyNoneDoesNotSnapshot() async throws {
    let registry = EventTypeRegistry()
    registry.register(BankAccountEvent.self, eventTypes: ["AccountOpened", "AccountDeposited", "AccountWithdrawn"])
    let store = InMemoryEventStore(registry: registry)
    let snapshotStore = InMemorySnapshotStore()

    let repo = AggregateRepository<BankAccountAggregate>(
        store: store,
        registry: registry,
        snapshotStore: snapshotStore,
        snapshotPolicy: .none
    )

    _ = try await repo.execute(OpenAccount(name: "Alice"), on: "acct-1", metadata: meta, using: OpenAccountHandler.self)
    _ = try await repo.execute(Deposit(amount: 100), on: "acct-1", metadata: meta, using: DepositHandler.self)
    _ = try await repo.execute(Deposit(amount: 200), on: "acct-1", metadata: meta, using: DepositHandler.self)

    let stream = StreamName(category: "account", id: "acct-1")
    let snapshot: (state: BankAccountAggregate.State, version: Int64)? =
        try await snapshotStore.load(for: stream)
    #expect(snapshot == nil)
}

@Test func explicitSaveSnapshotWorks() async throws {
    let registry = EventTypeRegistry()
    registry.register(BankAccountEvent.self, eventTypes: ["AccountOpened", "AccountDeposited", "AccountWithdrawn"])
    let store = InMemoryEventStore(registry: registry)
    let snapshotStore = InMemorySnapshotStore()

    let repo = AggregateRepository<BankAccountAggregate>(
        store: store,
        registry: registry,
        snapshotStore: snapshotStore,
        snapshotPolicy: .none
    )

    _ = try await repo.execute(OpenAccount(name: "Alice"), on: "acct-1", metadata: meta, using: OpenAccountHandler.self)
    _ = try await repo.execute(Deposit(amount: 100), on: "acct-1", metadata: meta, using: DepositHandler.self)

    // Explicitly save a snapshot
    try await repo.saveSnapshot(id: "acct-1")

    let stream = StreamName(category: "account", id: "acct-1")
    let snapshot: (state: BankAccountAggregate.State, version: Int64)? =
        try await snapshotStore.load(for: stream)
    #expect(snapshot?.state == BankAccountAggregate.State(isOpen: true, balance: 100, name: "Alice"))
    #expect(snapshot?.version == 1)
}
```

**Step 2: Run tests to verify the auto-snapshot test fails**

Run: `swift test --filter AggregateRepositoryTests`
Expected: `executeAutoSnapshotsEveryNEvents` FAILS (execute doesn't auto-snapshot yet). The other two should pass (saveSnapshot was added in Task 4, policy `.none` trivially passes).

**Step 3: Add auto-snapshotting to `execute()`**

In `Sources/Songbird/AggregateRepository.swift`, modify the `execute` method. After appending events, add the auto-snapshot logic. The full `execute` method becomes:

```swift
    public func execute<H: CommandHandler>(
        _ command: H.Cmd,
        on id: String,
        metadata: EventMetadata,
        using handler: H.Type
    ) async throws -> [RecordedEvent] where H.Agg == A {
        let (state, version) = try await load(id: id)
        let events = try handler.handle(command, given: state)
        let stream = StreamName(category: A.category, id: id)
        var recorded: [RecordedEvent] = []
        for (index, event) in events.enumerated() {
            let result = try await store.append(
                event,
                to: stream,
                metadata: metadata,
                expectedVersion: version + Int64(index)
            )
            recorded.append(result)
        }

        // Auto-snapshot based on policy
        if case .everyNEvents(let n) = snapshotPolicy, let snapshotStore, !recorded.isEmpty {
            let newVersion = version + Int64(recorded.count)
            // Snapshot when the new version crosses an N-event boundary
            if (newVersion + 1) >= Int64(n) && (newVersion + 1) % Int64(n) == 0
                || (version + 1) < Int64(n) && (newVersion + 1) >= Int64(n) {
                // Fold the new events into the loaded state for the snapshot
                var snapshotState = state
                for event in events {
                    snapshotState = A.apply(snapshotState, event)
                }
                try await snapshotStore.save(snapshotState, version: newVersion, for: stream)
            }
        }

        return recorded
    }
```

**Note:** The snapshot condition checks if we've accumulated enough events. A simpler approach: snapshot whenever `(newVersion + 1) % n == 0` (i.e., at versions 1, 3, 5... for `n=2`, or 99, 199... for `n=100`). If the test expects a snapshot at version 1 with `everyNEvents(2)`, the condition is `(1 + 1) % 2 == 0` which is true. Let me simplify:

```swift
        // Auto-snapshot based on policy
        if case .everyNEvents(let n) = snapshotPolicy, let snapshotStore, !recorded.isEmpty {
            let newVersion = version + Int64(recorded.count)
            if (newVersion + 1) % Int64(n) == 0 {
                var snapshotState = state
                for event in events {
                    snapshotState = A.apply(snapshotState, event)
                }
                try await snapshotStore.save(snapshotState, version: newVersion, for: stream)
            }
        }
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter AggregateRepositoryTests`
Expected: All tests pass.

**Step 5: Commit**

```bash
git add Sources/Songbird/AggregateRepository.swift Tests/SongbirdTests/AggregateRepositoryTests.swift
git commit -m "Add auto-snapshotting to AggregateRepository.execute"
```

---

### Task 6: Snapshot-Aware AggregateStateStream

**Files:**
- Modify: `Sources/Songbird/AggregateStateStream.swift`
- Test: `Tests/SongbirdTests/AggregateStateStreamTests.swift`

**Step 1: Write the failing test**

Add this test to the `AggregateStateStreamTests` struct in `Tests/SongbirdTests/AggregateStateStreamTests.swift`:

```swift
// MARK: - Snapshot-Aware Loading

@Test func snapshotSkipsEarlyEvents() async throws {
    let (store, registry) = makeStore()
    let snapshotStore = InMemorySnapshotStore()

    // Append 3 events
    _ = try await store.append(BalanceAggregate.Event.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
    _ = try await store.append(BalanceAggregate.Event.credited(amount: 50), to: stream, metadata: EventMetadata(), expectedVersion: nil)
    _ = try await store.append(BalanceAggregate.Event.debited(amount: 20), to: stream, metadata: EventMetadata(), expectedVersion: nil)

    // Save a snapshot at version 1 (after first two events: balance 150)
    try await snapshotStore.save(
        BalanceAggregate.State(balance: 150),
        version: 1,
        for: stream
    )

    let stateStream = AggregateStateStream<BalanceAggregate>(
        id: "acct-1",
        store: store,
        registry: registry,
        snapshotStore: snapshotStore,
        tickInterval: .milliseconds(10)
    )

    let collector = StateCollector<BalanceAggregate.State>()
    let task = Task {
        for try await state in stateStream {
            await collector.append(state)
            if await collector.count == 1 { break }
        }
    }

    try await task.value
    let states = await collector.states
    #expect(states.count == 1)
    // Snapshot (150) + event at position 2 (debit 20) = 130
    #expect(states[0] == BalanceAggregate.State(balance: 130))
}
```

**Step 2: Run tests to verify it fails**

Run: `swift test --filter AggregateStateStreamTests`
Expected: FAIL — `AggregateStateStream` init doesn't accept `snapshotStore`

**Step 3: Modify AggregateStateStream**

In `Sources/Songbird/AggregateStateStream.swift`, add the optional `snapshotStore` parameter and use it during the initial fold. The key changes:

1. Add `public let snapshotStore: (any SnapshotStore)?` field
2. Add `snapshotStore: (any SnapshotStore)? = nil` to init
3. Pass it through to `Iterator`
4. In `Iterator.next()` Phase 1, load from snapshot before folding

Replace the full file with:

```swift
import Foundation

/// A reactive `AsyncSequence` that yields the current state of an aggregate, updating live
/// as new events arrive in the entity stream.
///
/// On the first iteration call, the stream checks for a snapshot (if a `SnapshotStore` is
/// provided), then reads remaining events, decodes them via the provided `EventTypeRegistry`,
/// folds them through `Aggregate.apply`, and yields the resulting state. If no events or
/// snapshot exist, `Aggregate.initialState` is yielded. After the initial fold, the stream
/// polls for new events from the last known position, applies each one, and yields the
/// updated state for every event.
///
/// The stream does not save snapshots -- it is read-only. Snapshots are saved by the
/// `AggregateRepository` during command execution.
///
/// Usage:
/// ```swift
/// let stateStream = AggregateStateStream<BankAccountAggregate>(
///     id: "acct-123",
///     store: eventStore,
///     registry: registry,
///     snapshotStore: snapshotStore  // optional
/// )
///
/// let task = Task {
///     for try await state in stateStream {
///         print("Balance: \(state.balance)")
///     }
/// }
///
/// // Later: cancel stops the polling loop
/// task.cancel()
/// ```
public struct AggregateStateStream<A: Aggregate>: AsyncSequence, Sendable {
    public typealias Element = A.State

    public let id: String
    public let store: any EventStore
    public let registry: EventTypeRegistry
    public let snapshotStore: (any SnapshotStore)?
    public let batchSize: Int
    public let tickInterval: Duration

    public init(
        id: String,
        store: any EventStore,
        registry: EventTypeRegistry,
        snapshotStore: (any SnapshotStore)? = nil,
        batchSize: Int = 100,
        tickInterval: Duration = .milliseconds(100)
    ) {
        self.id = id
        self.store = store
        self.registry = registry
        self.snapshotStore = snapshotStore
        self.batchSize = batchSize
        self.tickInterval = tickInterval
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(
            stream: StreamName(category: A.category, id: id),
            store: store,
            registry: registry,
            snapshotStore: snapshotStore,
            batchSize: batchSize,
            tickInterval: tickInterval
        )
    }

    public struct Iterator: AsyncIteratorProtocol {
        let stream: StreamName
        let store: any EventStore
        let registry: EventTypeRegistry
        let snapshotStore: (any SnapshotStore)?
        let batchSize: Int
        let tickInterval: Duration
        private var state: A.State = A.initialState
        private var position: Int64 = 0
        private var initialFoldDone: Bool = false

        init(
            stream: StreamName,
            store: any EventStore,
            registry: EventTypeRegistry,
            snapshotStore: (any SnapshotStore)?,
            batchSize: Int,
            tickInterval: Duration
        ) {
            self.stream = stream
            self.store = store
            self.registry = registry
            self.snapshotStore = snapshotStore
            self.batchSize = batchSize
            self.tickInterval = tickInterval
        }

        public mutating func next() async throws -> A.State? {
            // Phase 1: Initial fold -- optionally load snapshot, then read remaining events
            if !initialFoldDone {
                initialFoldDone = true

                // Try loading a snapshot
                if let snapshotStore,
                   let snapshot: (state: A.State, version: Int64) = try await snapshotStore.load(for: stream) {
                    state = snapshot.state
                    position = snapshot.version + 1
                }

                while true {
                    let batch = try await store.readStream(
                        stream,
                        from: position,
                        maxCount: batchSize
                    )

                    for record in batch {
                        let decoded = try registry.decode(record)
                        guard let event = decoded as? A.Event else {
                            throw AggregateError.unexpectedEventType(record.eventType)
                        }
                        state = A.apply(state, event)
                        position = record.position + 1
                    }

                    if batch.count < batchSize { break }
                }

                return state
            }

            // Phase 2: Poll for new events, yield state after each one
            while !Task.isCancelled {
                try Task.checkCancellation()

                let batch = try await store.readStream(
                    stream,
                    from: position,
                    maxCount: batchSize
                )

                if !batch.isEmpty {
                    let record = batch[0]
                    let decoded = try registry.decode(record)
                    guard let event = decoded as? A.Event else {
                        throw AggregateError.unexpectedEventType(record.eventType)
                    }
                    state = A.apply(state, event)
                    position = record.position + 1
                    return state
                }

                try await Task.sleep(for: tickInterval)
            }

            return nil  // cancelled
        }
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter AggregateStateStreamTests`
Expected: All tests pass (existing 5 + 1 new).

**Step 5: Commit**

```bash
git add Sources/Songbird/AggregateStateStream.swift Tests/SongbirdTests/AggregateStateStreamTests.swift
git commit -m "Add snapshot-aware loading to AggregateStateStream"
```

---

### Task 7: SQLiteSnapshotStore

**Files:**
- Create: `Sources/SongbirdSQLite/SQLiteSnapshotStore.swift`
- Create: `Tests/SongbirdSQLiteTests/SQLiteSnapshotStoreTests.swift`

**Step 1: Write the failing tests**

Create `Tests/SongbirdSQLiteTests/SQLiteSnapshotStoreTests.swift`:

```swift
import Foundation
import Testing

@testable import Songbird
@testable import SongbirdSQLite

private enum SnapAggregate: Aggregate {
    struct State: Sendable, Equatable, Codable {
        var count: Int
    }
    enum Event: Songbird.Event {
        case incremented
        var eventType: String { "Incremented" }
    }
    enum Failure: Error { case none }

    static let category = "snap"
    static let initialState = State(count: 0)
    static func apply(_ state: State, _ event: Event) -> State {
        State(count: state.count + 1)
    }
}

@Suite("SQLiteSnapshotStore")
struct SQLiteSnapshotStoreTests {
    @Test func loadReturnsNilWhenNoSnapshot() async throws {
        let store = try SQLiteSnapshotStore(path: ":memory:")
        let stream = StreamName(category: "snap", id: "1")
        let result: (state: SnapAggregate.State, version: Int64)? =
            try await store.load(for: stream)
        #expect(result == nil)
    }

    @Test func saveAndLoad() async throws {
        let store = try SQLiteSnapshotStore(path: ":memory:")
        let stream = StreamName(category: "snap", id: "1")
        let state = SnapAggregate.State(count: 42)
        try await store.save(state, version: 10, for: stream) as Void
        let loaded: (state: SnapAggregate.State, version: Int64)? =
            try await store.load(for: stream)
        #expect(loaded?.state == state)
        #expect(loaded?.version == 10)
    }

    @Test func saveOverwritesPreviousSnapshot() async throws {
        let store = try SQLiteSnapshotStore(path: ":memory:")
        let stream = StreamName(category: "snap", id: "1")
        try await store.save(SnapAggregate.State(count: 1), version: 5, for: stream) as Void
        try await store.save(SnapAggregate.State(count: 99), version: 50, for: stream) as Void
        let loaded: (state: SnapAggregate.State, version: Int64)? =
            try await store.load(for: stream)
        #expect(loaded?.state == SnapAggregate.State(count: 99))
        #expect(loaded?.version == 50)
    }

    @Test func differentStreamsAreIndependent() async throws {
        let store = try SQLiteSnapshotStore(path: ":memory:")
        let stream1 = StreamName(category: "snap", id: "1")
        let stream2 = StreamName(category: "snap", id: "2")
        try await store.save(SnapAggregate.State(count: 10), version: 5, for: stream1) as Void
        try await store.save(SnapAggregate.State(count: 20), version: 8, for: stream2) as Void
        let loaded1: (state: SnapAggregate.State, version: Int64)? =
            try await store.load(for: stream1)
        let loaded2: (state: SnapAggregate.State, version: Int64)? =
            try await store.load(for: stream2)
        #expect(loaded1?.state.count == 10)
        #expect(loaded2?.state.count == 20)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter SQLiteSnapshotStoreTests`
Expected: FAIL — `SQLiteSnapshotStore` not defined

**Step 3: Write the implementation**

Create `Sources/SongbirdSQLite/SQLiteSnapshotStore.swift`:

```swift
import Dispatch
import Foundation
import Songbird
import SQLite

/// A SQLite-backed snapshot store that persists aggregate state checkpoints.
///
/// Uses a single `snapshots` table with the stream name as the primary key.
/// Only the latest snapshot per stream is kept (upsert on save).
public actor SQLiteSnapshotStore: SnapshotStore {
    /// The underlying SQLite connection. Marked `nonisolated(unsafe)` because all access
    /// is serialized through this actor's custom `DispatchSerialQueue` executor.
    nonisolated(unsafe) let db: Connection
    private let iso8601Formatter = ISO8601DateFormatter()
    private let executor: DispatchSerialQueue

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    public init(path: String) throws {
        self.executor = DispatchSerialQueue(label: "songbird.sqlite-snapshot-store")
        if path == ":memory:" {
            self.db = try Connection(.inMemory)
        } else {
            self.db = try Connection(path)
        }
        try Self.configurePragmas(db)
        try Self.migrate(db)
    }

    // MARK: - Pragmas

    private static func configurePragmas(_ db: Connection) throws {
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("PRAGMA synchronous = NORMAL")
    }

    // MARK: - Migrations

    private static func migrate(_ db: Connection) throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS snapshots (
                stream_name TEXT PRIMARY KEY,
                state       BLOB NOT NULL,
                version     INTEGER NOT NULL,
                updated_at  TEXT NOT NULL
            )
        """)
    }

    // MARK: - SnapshotStore

    public func save<A: Aggregate>(
        _ state: A.State,
        version: Int64,
        for stream: StreamName
    ) async throws {
        let data = try JSONEncoder().encode(state)
        let now = iso8601Formatter.string(from: Date())
        try db.run("""
            INSERT INTO snapshots (stream_name, state, version, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(stream_name) DO UPDATE SET
                state = excluded.state,
                version = excluded.version,
                updated_at = excluded.updated_at
        """, stream.description, data.datatypeValue, version, now)
    }

    public func load<A: Aggregate>(
        for stream: StreamName
    ) async throws -> (state: A.State, version: Int64)? {
        let rows = try db.prepare("""
            SELECT state, version FROM snapshots WHERE stream_name = ? LIMIT 1
        """, stream.description)

        for row in rows {
            guard let blob = row[0] as? Blob else { return nil }
            guard let version = row[1] as? Int64 else { return nil }
            let data = Data(blob.bytes)
            let state = try JSONDecoder().decode(A.State.self, from: data)
            return (state, version)
        }
        return nil
    }
}
```

**Note:** SQLite.swift uses `Blob` for BLOB columns. `data.datatypeValue` converts `Data` to the SQLite binding type. If that doesn't work, use `Blob(bytes: [UInt8](data))` instead.

**Step 4: Run tests to verify they pass**

Run: `swift test --filter SQLiteSnapshotStoreTests`
Expected: All 4 tests pass.

**Step 5: Commit**

```bash
git add Sources/SongbirdSQLite/SQLiteSnapshotStore.swift Tests/SongbirdSQLiteTests/SQLiteSnapshotStoreTests.swift
git commit -m "Add SQLiteSnapshotStore with upsert-based persistence"
```

---

### Task 8: Clean Build and Full Test Suite

**Step 1: Run full build**

Run: `swift build 2>&1`
Expected: Build succeeds with no warnings and no errors.

**Step 2: Run full test suite**

Run: `swift test 2>&1`
Expected: All tests pass (should be ~265+ tests). No failures, no warnings.

**Step 3: If any issues, fix them and re-run**

Common issues to watch for:
- `Codable` conformance missing on a state struct we missed
- SQLite `Blob`/`Data` conversion issues
- Generic type inference on `SnapshotStore.load` return type — callers may need explicit type annotations

**Step 4: Commit (if any fixes were needed)**

```bash
git add -A
git commit -m "Fix build issues from snapshot integration"
```

---

### Task 9: Changelog Entry

**Step 1: Verify this file is complete and accurate**

This file (`changelog/0014-snapshots.md`) serves as both the implementation plan and the changelog entry.

**Step 2: Commit the changelog**

```bash
git add changelog/0014-snapshots.md
git commit -m "Add snapshots changelog entry"
```
