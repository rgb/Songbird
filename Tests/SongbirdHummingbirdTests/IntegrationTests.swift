import Foundation
import Hummingbird
import HummingbirdTesting
import Songbird
import SongbirdTesting
import Testing

@testable import SongbirdHummingbird

// MARK: - Domain Types

private enum BalanceEvent: Event, Equatable {
    case deposited(amount: Int)

    var eventType: String {
        switch self {
        case .deposited: "Deposited"
        }
    }
}

private enum BalanceAggregate: Aggregate {
    struct State: Sendable, Equatable { var balance: Int }
    typealias Failure = Never

    static let category = "account"
    static let initialState = State(balance: 0)

    static func apply(_ state: State, _ event: BalanceEvent) -> State {
        switch event {
        case .deposited(let amount):
            State(balance: state.balance + amount)
        }
    }
}

private struct Deposit: Command, Codable {
    let amount: Int
    var commandType: String { "Deposit" }
}

private enum DepositHandler: CommandHandler {
    typealias Agg = BalanceAggregate
    typealias Cmd = Deposit

    static func handle(
        _ command: Deposit,
        given state: BalanceAggregate.State
    ) throws(Never) -> [BalanceEvent] {
        [.deposited(amount: command.amount)]
    }
}

private actor BalanceProjector: Projector {
    let projectorId = "balance"
    private var balances: [String: Int] = [:]

    func apply(_ event: RecordedEvent) async throws {
        guard event.eventType == "Deposited",
              let decoded = try? event.decode(BalanceEvent.self).event,
              case .deposited(let amount) = decoded,
              let id = event.streamName.id
        else { return }
        balances[id, default: 0] += amount
    }

    func balance(for id: String) -> Int {
        balances[id, default: 0]
    }
}

// MARK: - Tests

@Suite("Integration")
struct IntegrationTests {
    @Test func fullHTTPRequestCycle() async throws {
        let registry = EventTypeRegistry()
        registry.register(BalanceEvent.self, eventTypes: ["Deposited"])
        let store = InMemoryEventStore(registry: registry)
        let pipeline = ProjectionPipeline()
        let balanceProjector = BalanceProjector()

        var mutableServices = SongbirdServices(
            eventStore: store,
            projectionPipeline: pipeline,
            positionStore: InMemoryPositionStore(),
            eventRegistry: registry
        )
        mutableServices.registerProjector(balanceProjector)
        let services = mutableServices

        let repository = AggregateRepository<BalanceAggregate>(
            store: store, registry: registry
        )

        let router = Router(context: SongbirdRequestContext.self)
        router.addMiddleware { RequestIdMiddleware() }
        router.addMiddleware {
            ProjectionFlushMiddleware<SongbirdRequestContext>(pipeline: pipeline)
        }

        router.post("/accounts/{id}/deposit") { request, context -> Response in
            let id = try context.parameters.require("id")
            let deposit = try await request.decode(as: Deposit.self, context: context)
            let requestId = context.requestId

            try await executeAndProject(
                deposit,
                on: id,
                metadata: EventMetadata(traceId: requestId),
                using: DepositHandler.self,
                repository: repository,
                services: services
            )

            return Response(status: .ok)
        }

        router.get("/accounts/{id}/balance") { _, context -> String in
            let id = try context.parameters.require("id")
            let balance = await balanceProjector.balance(for: id)
            return "\(balance)"
        }

        let app = Application(router: router)
        let serviceTask = Task { try await services.run() }

        try await app.test(.router) { client in
            // Deposit 100
            let depositBody = try JSONEncoder().encode(Deposit(amount: 100))
            var response = try await client.execute(
                uri: "/accounts/acct-1/deposit",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(data: depositBody)
            )
            #expect(response.status == .ok)

            // Read balance — should be 100
            response = try await client.execute(
                uri: "/accounts/acct-1/balance",
                method: .get
            )
            #expect(String(buffer: response.body) == "100")

            // Deposit 50 more
            let deposit2Body = try JSONEncoder().encode(Deposit(amount: 50))
            response = try await client.execute(
                uri: "/accounts/acct-1/deposit",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(data: deposit2Body)
            )
            #expect(response.status == .ok)

            // Balance should be 150
            response = try await client.execute(
                uri: "/accounts/acct-1/balance",
                method: .get
            )
            #expect(String(buffer: response.body) == "150")
        }

        serviceTask.cancel()
        try? await serviceTask.value
    }
}
