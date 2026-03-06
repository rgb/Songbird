import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

// MARK: - Test Domain

enum HarnessOrderEvent: Event {
    case placed(orderId: String, total: Int)

    var eventType: String {
        switch self {
        case .placed: "HarnessOrderPlaced"
        }
    }
}

enum HarnessPaymentEvent: Event {
    case charged(orderId: String)

    var eventType: String {
        switch self {
        case .charged: "HarnessPaymentCharged"
        }
    }
}

enum HarnessFulfillmentEvent: Event {
    case paymentRequested(orderId: String, amount: Int)
    case shipmentRequested(orderId: String)

    var eventType: String {
        switch self {
        case .paymentRequested: "HarnessPaymentRequested"
        case .shipmentRequested: "HarnessShipmentRequested"
        }
    }
}

enum HarnessOnOrderPlaced: EventReaction {
    typealias PMState = HarnessFulfillmentPM.State
    typealias Input = HarnessOrderEvent

    static let eventTypes = ["HarnessOrderPlaced"]

    static func route(_ event: HarnessOrderEvent) -> String? {
        switch event { case .placed(let orderId, _): orderId }
    }

    static func apply(_ state: PMState, _ event: HarnessOrderEvent) -> PMState {
        switch event { case .placed(_, let total): .init(total: total, paid: false) }
    }

    static func react(_ state: PMState, _ event: HarnessOrderEvent) -> [any Event] {
        switch event {
        case .placed(let orderId, let total):
            [HarnessFulfillmentEvent.paymentRequested(orderId: orderId, amount: total)]
        }
    }
}

enum HarnessOnPaymentCharged: EventReaction {
    typealias PMState = HarnessFulfillmentPM.State
    typealias Input = HarnessPaymentEvent

    static let eventTypes = ["HarnessPaymentCharged"]

    static func route(_ event: HarnessPaymentEvent) -> String? {
        switch event { case .charged(let orderId): orderId }
    }

    static func apply(_ state: PMState, _ event: HarnessPaymentEvent) -> PMState {
        switch event { case .charged: .init(total: state.total, paid: true) }
    }

    static func react(_ state: PMState, _ event: HarnessPaymentEvent) -> [any Event] {
        switch event {
        case .charged(let orderId):
            [HarnessFulfillmentEvent.shipmentRequested(orderId: orderId)]
        }
    }
}

enum HarnessFulfillmentPM: ProcessManager {
    struct State: Sendable, Equatable {
        var total: Int
        var paid: Bool
    }

    static let processId = "harnessFulfillment"
    static let initialState = State(total: 0, paid: false)

    static let reactions: [AnyReaction<State>] = [
        reaction(for: HarnessOnOrderPlaced.self, categories: ["harnessOrder"]),
        reaction(for: HarnessOnPaymentCharged.self, categories: ["harnessPayment"]),
    ]
}

// MARK: - Tests

@Suite("TestProcessManagerHarness")
struct TestProcessManagerHarnessTests {

    @Test func startsEmpty() {
        let harness = TestProcessManagerHarness<HarnessFulfillmentPM>()
        #expect(harness.states.isEmpty)
        #expect(harness.output.isEmpty)
    }

    @Test func processesTypedEventAndUpdatesState() throws {
        var harness = TestProcessManagerHarness<HarnessFulfillmentPM>()
        try harness.given(
            HarnessOrderEvent.placed(orderId: "order-1", total: 100),
            streamName: StreamName(category: "harnessOrder", id: "order-1")
        )
        #expect(
            harness.state(for: "order-1")
                == HarnessFulfillmentPM.State(total: 100, paid: false))
    }

    @Test func collectsOutputEvents() throws {
        var harness = TestProcessManagerHarness<HarnessFulfillmentPM>()
        try harness.given(
            HarnessOrderEvent.placed(orderId: "order-1", total: 200),
            streamName: StreamName(category: "harnessOrder", id: "order-1")
        )
        #expect(harness.output.count == 1)
        let first = harness.output[0] as? HarnessFulfillmentEvent
        #expect(
            first == HarnessFulfillmentEvent.paymentRequested(orderId: "order-1", amount: 200))
    }

    @Test func tracksPerEntityStateIsolation() throws {
        var harness = TestProcessManagerHarness<HarnessFulfillmentPM>()
        try harness.given(
            HarnessOrderEvent.placed(orderId: "A", total: 50),
            streamName: StreamName(category: "harnessOrder", id: "A")
        )
        try harness.given(
            HarnessOrderEvent.placed(orderId: "B", total: 75),
            streamName: StreamName(category: "harnessOrder", id: "B")
        )
        #expect(harness.state(for: "A") == HarnessFulfillmentPM.State(total: 50, paid: false))
        #expect(harness.state(for: "B") == HarnessFulfillmentPM.State(total: 75, paid: false))
    }

    @Test func multiStepWorkflow() throws {
        var harness = TestProcessManagerHarness<HarnessFulfillmentPM>()
        try harness.given(
            HarnessOrderEvent.placed(orderId: "order-1", total: 300),
            streamName: StreamName(category: "harnessOrder", id: "order-1")
        )
        try harness.given(
            HarnessPaymentEvent.charged(orderId: "order-1"),
            streamName: StreamName(category: "harnessPayment", id: "order-1")
        )
        #expect(
            harness.state(for: "order-1")
                == HarnessFulfillmentPM.State(total: 300, paid: true))
        #expect(harness.output.count == 2)
        let second = harness.output[1] as? HarnessFulfillmentEvent
        #expect(second == HarnessFulfillmentEvent.shipmentRequested(orderId: "order-1"))
    }

    @Test func returnsInitialStateForUnknownEntity() {
        let harness = TestProcessManagerHarness<HarnessFulfillmentPM>()
        #expect(
            harness.state(for: "nonexistent") == HarnessFulfillmentPM.initialState)
    }

    @Test func skipsEventsWithNoMatchingReaction() throws {
        var harness = TestProcessManagerHarness<HarnessFulfillmentPM>()
        try harness.given(
            TestWidgetEvent.created(name: "irrelevant"),
            streamName: StreamName(category: "harnessOrder", id: "x")
        )
        #expect(harness.states.isEmpty)
        #expect(harness.output.isEmpty)
    }

    @Test func acceptsRawRecordedEvent() throws {
        var harness = TestProcessManagerHarness<HarnessFulfillmentPM>()
        let recorded = try RecordedEvent(
            event: HarnessOrderEvent.placed(orderId: "order-1", total: 150),
            streamName: StreamName(category: "harnessOrder", id: "order-1")
        )
        try harness.given(recorded)
        #expect(
            harness.state(for: "order-1")
                == HarnessFulfillmentPM.State(total: 150, paid: false))
    }
}
