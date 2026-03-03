import Testing

@testable import Songbird

struct ItemReserved: Event {
    static let eventType = "ItemReserved"
    let orderId: String
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

    typealias InputEvent = ItemReserved
    typealias OutputCommand = ChargePayment

    static let processId = "fulfillment"
    static let initialState = State(reserved: false)

    static func apply(_ state: State, _ event: ItemReserved) -> State {
        State(reserved: true)
    }

    static func commands(_ state: State, _ event: ItemReserved) -> [ChargePayment] {
        [ChargePayment(orderId: event.orderId, amount: 100)]
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
            ItemReserved(orderId: "o1")
        )
        #expect(state.reserved == true)
    }

    @Test func commandsProducesOutput() {
        let commands = FulfillmentProcess.commands(
            FulfillmentProcess.initialState,
            ItemReserved(orderId: "o1")
        )
        #expect(commands.count == 1)
        #expect(commands[0].orderId == "o1")
    }
}
