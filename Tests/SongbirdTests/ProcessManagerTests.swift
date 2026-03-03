import Testing

@testable import Songbird

enum OrderEvent: Event {
    case itemReserved(orderId: String)

    var eventType: String {
        switch self {
        case .itemReserved: "ItemReserved"
        }
    }
}

struct ChargePayment: Command {
    static let commandType = "ChargePayment"
    let orderId: String
    let amount: Int
}

enum FulfillmentProcess: ProcessManager {
    struct State: Sendable {
        var reserved: Bool
    }

    typealias InputEvent = OrderEvent
    typealias OutputCommand = ChargePayment

    static let processId = "fulfillment"
    static let initialState = State(reserved: false)

    static func apply(_ state: State, _ event: OrderEvent) -> State {
        switch event {
        case .itemReserved: State(reserved: true)
        }
    }

    static func commands(_ state: State, _ event: OrderEvent) -> [ChargePayment] {
        switch event {
        case .itemReserved(let orderId):
            [ChargePayment(orderId: orderId, amount: 100)]
        }
    }
}

@Suite("ProcessManager")
struct ProcessManagerTests {
    @Test func processIdIsAccessible() {
        #expect(FulfillmentProcess.processId == "fulfillment")
    }

    @Test func applyUpdatesState() {
        let state = FulfillmentProcess.apply(
            FulfillmentProcess.initialState,
            .itemReserved(orderId: "o1")
        )
        #expect(state.reserved == true)
    }

    @Test func commandsProducesOutput() {
        let commands = FulfillmentProcess.commands(
            FulfillmentProcess.initialState,
            .itemReserved(orderId: "o1")
        )
        #expect(commands.count == 1)
        #expect(commands[0].orderId == "o1")
    }
}
