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
    static let commandType = "OpenAccount"
    let name: String
}

struct Deposit: Command {
    static let commandType = "Deposit"
    let amount: Int
}

struct Withdraw: Command {
    static let commandType = "Withdraw"
    let amount: Int
}

enum BankAccountAggregate: Aggregate {
    struct State: Sendable, Equatable {
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
        do {
            _ = try await repo.execute(Deposit(amount: 100), on: "acct-1", metadata: meta, using: DepositHandler.self)
            Issue.record("Expected error to be thrown")
        } catch {
            // Error was thrown as expected
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
}
