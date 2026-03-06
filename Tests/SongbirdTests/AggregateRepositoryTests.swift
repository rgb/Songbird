import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

// MARK: - Test Domain

enum BankAccountEvent: Event {
    case opened(name: String)
    case deposited(amount: Int)
    case withdrawn(amount: Int)

    var eventType: String {
        switch self {
        case .opened: "AccountOpened"
        case .deposited: "AccountDeposited"
        case .withdrawn: "AccountWithdrawn"
        }
    }
}

struct OpenAccount: Command {
    var commandType: String { "OpenAccount" }
    let name: String
}

struct Deposit: Command {
    var commandType: String { "Deposit" }
    let amount: Int
}

struct Withdraw: Command {
    var commandType: String { "Withdraw" }
    let amount: Int
}

enum BankAccountAggregate: Aggregate {
    struct State: Sendable, Equatable, Codable {
        var isOpen: Bool = false
        var balance: Int = 0
        var name: String = ""
    }

    typealias Event = BankAccountEvent
    enum Failure: Error { case notOpen, alreadyOpen, insufficientFunds }

    static let category = "account"
    static let initialState = State()

    static func apply(_ state: State, _ event: BankAccountEvent) -> State {
        switch event {
        case .opened(let name):
            State(isOpen: true, balance: 0, name: name)
        case .deposited(let amount):
            State(isOpen: state.isOpen, balance: state.balance + amount, name: state.name)
        case .withdrawn(let amount):
            State(isOpen: state.isOpen, balance: state.balance - amount, name: state.name)
        }
    }
}

enum OpenAccountHandler: CommandHandler {
    typealias Agg = BankAccountAggregate
    typealias Cmd = OpenAccount

    static func handle(
        _ command: OpenAccount,
        given state: BankAccountAggregate.State
    ) throws(BankAccountAggregate.Failure) -> [BankAccountEvent] {
        guard !state.isOpen else { throw .alreadyOpen }
        return [.opened(name: command.name)]
    }
}

enum DepositHandler: CommandHandler {
    typealias Agg = BankAccountAggregate
    typealias Cmd = Deposit

    static func handle(
        _ command: Deposit,
        given state: BankAccountAggregate.State
    ) throws(BankAccountAggregate.Failure) -> [BankAccountEvent] {
        guard state.isOpen else { throw .notOpen }
        return [.deposited(amount: command.amount)]
    }
}

enum WithdrawHandler: CommandHandler {
    typealias Agg = BankAccountAggregate
    typealias Cmd = Withdraw

    static func handle(
        _ command: Withdraw,
        given state: BankAccountAggregate.State
    ) throws(BankAccountAggregate.Failure) -> [BankAccountEvent] {
        guard state.isOpen else { throw .notOpen }
        guard state.balance >= command.amount else { throw .insufficientFunds }
        return [.withdrawn(amount: command.amount)]
    }
}

// MARK: - Tests

@Suite("AggregateRepository")
struct AggregateRepositoryTests {
    func makeRepo() -> (AggregateRepository<BankAccountAggregate>, InMemoryEventStore) {
        let registry = EventTypeRegistry()
        registry.register(BankAccountEvent.self, eventTypes: ["AccountOpened", "AccountDeposited", "AccountWithdrawn"])
        let store = InMemoryEventStore(registry: registry)
        let repo = AggregateRepository<BankAccountAggregate>(store: store, registry: registry)
        return (repo, store)
    }

    let meta = EventMetadata(traceId: "test")

    // MARK: - Load

    @Test func loadEmptyStream() async throws {
        let (repo, _) = makeRepo()
        let (state, version) = try await repo.load(id: "acct-1")
        #expect(state == BankAccountAggregate.initialState)
        #expect(version == -1)
    }

    @Test func loadWithEvents() async throws {
        let (repo, store) = makeRepo()
        let stream = StreamName(category: "account", id: "acct-1")
        _ = try await store.append(BankAccountEvent.opened(name: "Alice"), to: stream, metadata: meta, expectedVersion: nil)
        _ = try await store.append(BankAccountEvent.deposited(amount: 100), to: stream, metadata: meta, expectedVersion: nil)
        _ = try await store.append(BankAccountEvent.withdrawn(amount: 30), to: stream, metadata: meta, expectedVersion: nil)

        let (state, version) = try await repo.load(id: "acct-1")
        #expect(state == BankAccountAggregate.State(isOpen: true, balance: 70, name: "Alice"))
        #expect(version == 2)
    }

    // MARK: - Execute

    @Test func executeAppendsEvents() async throws {
        let (repo, store) = makeRepo()
        let recorded = try await repo.execute(
            OpenAccount(name: "Bob"),
            on: "acct-1",
            metadata: meta,
            using: OpenAccountHandler.self
        )
        #expect(recorded.count == 1)
        #expect(recorded[0].eventType == "AccountOpened")
        #expect(recorded[0].streamName == StreamName(category: "account", id: "acct-1"))

        let events = try await store.readStream(StreamName(category: "account", id: "acct-1"), from: 0, maxCount: 100)
        #expect(events.count == 1)
    }

    @Test func executeUsesOptimisticConcurrency() async throws {
        let (repo, store) = makeRepo()
        // Open the account first
        _ = try await repo.execute(OpenAccount(name: "Carol"), on: "acct-1", metadata: meta, using: OpenAccountHandler.self)

        // Deposit -- this should pass optimistic concurrency (expectedVersion: 0)
        let recorded = try await repo.execute(Deposit(amount: 50), on: "acct-1", metadata: meta, using: DepositHandler.self)
        #expect(recorded[0].position == 1)

        // Verify there are now 2 events in the stream
        let events = try await store.readStream(StreamName(category: "account", id: "acct-1"), from: 0, maxCount: 100)
        #expect(events.count == 2)
    }

    @Test func executeWithFailedValidation() async throws {
        let (repo, store) = makeRepo()
        // Try to deposit without opening -- should throw .notOpen
        await #expect(throws: BankAccountAggregate.Failure.self) {
            _ = try await repo.execute(Deposit(amount: 100), on: "acct-1", metadata: meta, using: DepositHandler.self)
        }

        // No events should have been appended
        let events = try await store.readStream(StreamName(category: "account", id: "acct-1"), from: 0, maxCount: 100)
        #expect(events.isEmpty)
    }

    @Test func executeMultipleCommands() async throws {
        let (repo, _) = makeRepo()
        _ = try await repo.execute(OpenAccount(name: "Dave"), on: "acct-1", metadata: meta, using: OpenAccountHandler.self)
        _ = try await repo.execute(Deposit(amount: 200), on: "acct-1", metadata: meta, using: DepositHandler.self)
        _ = try await repo.execute(Withdraw(amount: 75), on: "acct-1", metadata: meta, using: WithdrawHandler.self)

        let (state, version) = try await repo.load(id: "acct-1")
        #expect(state == BankAccountAggregate.State(isOpen: true, balance: 125, name: "Dave"))
        #expect(version == 2)
    }

    @Test func handlerCanReturnMultipleEvents() async throws {
        // Define a handler that returns multiple events from a single command
        enum BulkDepositHandler: CommandHandler {
            typealias Agg = BankAccountAggregate
            typealias Cmd = Deposit

            static func handle(
                _ command: Deposit,
                given state: BankAccountAggregate.State
            ) throws(BankAccountAggregate.Failure) -> [BankAccountEvent] {
                guard state.isOpen else { throw .notOpen }
                // Split deposit into two events
                let half = command.amount / 2
                let remainder = command.amount - half
                return [.deposited(amount: half), .deposited(amount: remainder)]
            }
        }

        let registry = EventTypeRegistry()
        registry.register(BankAccountEvent.self, eventTypes: ["AccountOpened", "AccountDeposited", "AccountWithdrawn"])
        let store = InMemoryEventStore(registry: registry)
        let repo = AggregateRepository<BankAccountAggregate>(store: store, registry: registry)

        _ = try await repo.execute(OpenAccount(name: "Eve"), on: "acct-1", metadata: meta, using: OpenAccountHandler.self)
        let recorded = try await repo.execute(Deposit(amount: 100), on: "acct-1", metadata: meta, using: BulkDepositHandler.self)

        #expect(recorded.count == 2)
        #expect(recorded[0].eventType == "AccountDeposited")
        #expect(recorded[1].eventType == "AccountDeposited")

        let (state, _) = try await repo.load(id: "acct-1")
        #expect(state.balance == 100)
    }

    // MARK: - Edge Cases

    @Test func executeWithEmptyEventListAppendsNothing() async throws {
        enum NoOpHandler: CommandHandler {
            typealias Agg = BankAccountAggregate
            typealias Cmd = Deposit

            static func handle(
                _ command: Deposit,
                given state: BankAccountAggregate.State
            ) throws(BankAccountAggregate.Failure) -> [BankAccountEvent] {
                []
            }
        }

        let (repo, store) = makeRepo()
        _ = try await repo.execute(OpenAccount(name: "Fay"), on: "acct-1", metadata: meta, using: OpenAccountHandler.self)
        let recorded = try await repo.execute(Deposit(amount: 100), on: "acct-1", metadata: meta, using: NoOpHandler.self)
        #expect(recorded.isEmpty)

        let events = try await store.readStream(StreamName(category: "account", id: "acct-1"), from: 0, maxCount: 100)
        #expect(events.count == 1) // only the open event
    }

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

        let stream = StreamName(category: "account", id: "acct-1")
        _ = try await store.append(BankAccountEvent.opened(name: "Bob"), to: stream, metadata: meta, expectedVersion: nil)
        _ = try await store.append(BankAccountEvent.deposited(amount: 50), to: stream, metadata: meta, expectedVersion: nil)

        let (state, version) = try await repo.load(id: "acct-1")
        #expect(state == BankAccountAggregate.State(isOpen: true, balance: 50, name: "Bob"))
        #expect(version == 1)
    }

    @Test func loadWithNoSnapshotStoreDefaultsBehavior() async throws {
        let (repo, store) = makeRepo()
        let stream = StreamName(category: "account", id: "acct-1")
        _ = try await store.append(BankAccountEvent.opened(name: "Carol"), to: stream, metadata: meta, expectedVersion: nil)

        let (state, version) = try await repo.load(id: "acct-1")
        #expect(state == BankAccountAggregate.State(isOpen: true, balance: 0, name: "Carol"))
        #expect(version == 0)
    }

    @Test func loadWithWrongRegistryThrowsUnexpectedEventType() async throws {
        // Use a registry that maps "AccountOpened" to CounterAggregate.Event (wrong type)
        let wrongRegistry = EventTypeRegistry()
        wrongRegistry.register(CounterAggregate.Event.self, eventTypes: ["AccountOpened"])

        // Use a single store -- append with the store, then load with the wrong registry
        let store = InMemoryEventStore(registry: wrongRegistry)
        _ = try await store.append(
            BankAccountEvent.opened(name: "Test"),
            to: StreamName(category: "account", id: "acct-1"),
            metadata: meta,
            expectedVersion: nil
        )

        // The repo uses wrongRegistry, which tries to decode BankAccountEvent JSON
        // as CounterAggregate.Event -- fails with a DecodingError
        let repo = AggregateRepository<BankAccountAggregate>(store: store, registry: wrongRegistry)
        await #expect(throws: (any Error).self) {
            _ = try await repo.load(id: "acct-1")
        }
    }

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

        let stream = StreamName(category: "account", id: "acct-1")

        // Event at position 0: open
        _ = try await repo.execute(OpenAccount(name: "Alice"), on: "acct-1", metadata: meta, using: OpenAccountHandler.self)
        var snapshot: (state: BankAccountAggregate.State, version: Int64)? =
            try await snapshotStore.load(for: stream)
        #expect(snapshot == nil)

        // Event at position 1: deposit — now 2 events total, should trigger snapshot
        _ = try await repo.execute(Deposit(amount: 100), on: "acct-1", metadata: meta, using: DepositHandler.self)
        snapshot = try await snapshotStore.load(for: stream)
        #expect(snapshot != nil)
        #expect(snapshot?.state == BankAccountAggregate.State(isOpen: true, balance: 100, name: "Alice"))
        #expect(snapshot?.version == 1)
    }

    @Test func executeAutoSnapshotsWithMultiEventCommand() async throws {
        // A multi-event command that skips over the N-event boundary should still trigger a snapshot
        enum BulkDepositHandler: CommandHandler {
            typealias Agg = BankAccountAggregate
            typealias Cmd = Deposit

            static func handle(
                _ command: Deposit,
                given state: BankAccountAggregate.State
            ) throws(BankAccountAggregate.Failure) -> [BankAccountEvent] {
                guard state.isOpen else { throw .notOpen }
                return [.deposited(amount: command.amount), .deposited(amount: command.amount)]
            }
        }

        let registry = EventTypeRegistry()
        registry.register(BankAccountEvent.self, eventTypes: ["AccountOpened", "AccountDeposited", "AccountWithdrawn"])
        let store = InMemoryEventStore(registry: registry)
        let snapshotStore = InMemorySnapshotStore()

        let repo = AggregateRepository<BankAccountAggregate>(
            store: store,
            registry: registry,
            snapshotStore: snapshotStore,
            snapshotPolicy: .everyNEvents(3)
        )

        let stream = StreamName(category: "account", id: "acct-1")

        // Event at position 0: open (1 total)
        _ = try await repo.execute(OpenAccount(name: "Alice"), on: "acct-1", metadata: meta, using: OpenAccountHandler.self)
        var snapshot: (state: BankAccountAggregate.State, version: Int64)? =
            try await snapshotStore.load(for: stream)
        #expect(snapshot == nil)

        // Events at positions 1 and 2: bulk deposit (3 total) — crosses the 3-event boundary
        _ = try await repo.execute(Deposit(amount: 50), on: "acct-1", metadata: meta, using: BulkDepositHandler.self)
        snapshot = try await snapshotStore.load(for: stream)
        #expect(snapshot != nil)
        #expect(snapshot?.state == BankAccountAggregate.State(isOpen: true, balance: 100, name: "Alice"))
        #expect(snapshot?.version == 2)
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

        try await repo.saveSnapshot(id: "acct-1")

        let stream = StreamName(category: "account", id: "acct-1")
        let snapshot: (state: BankAccountAggregate.State, version: Int64)? =
            try await snapshotStore.load(for: stream)
        #expect(snapshot?.state == BankAccountAggregate.State(isOpen: true, balance: 100, name: "Alice"))
        #expect(snapshot?.version == 1)
    }
}
