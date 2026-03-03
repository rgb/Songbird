import Foundation
import Testing

@testable import Songbird

// MARK: - Domain Events (from external aggregates)

enum PMOrderEvent: Event {
    case placed(orderId: String, total: Int)

    var eventType: String {
        switch self {
        case .placed: "OrderPlaced"
        }
    }
}

enum PMPaymentEvent: Event {
    case charged(orderId: String)
    case failed(orderId: String, reason: String)

    var eventType: String {
        switch self {
        case .charged: "PaymentCharged"
        case .failed: "PaymentFailed"
        }
    }
}

// MARK: - Reaction Events (emitted by the process manager)

enum PMFulfillmentEvent: Event {
    case paymentRequested(orderId: String, amount: Int)
    case shipmentRequested(orderId: String)

    var eventType: String {
        switch self {
        case .paymentRequested: "PaymentRequested"
        case .shipmentRequested: "ShipmentRequested"
        }
    }
}

// MARK: - Typed Reactors

enum PMOnOrderPlaced: EventReaction {
    typealias PMState = PMFulfillmentPM.State
    typealias Input = PMOrderEvent

    static let eventTypes = ["OrderPlaced"]

    static func route(_ event: PMOrderEvent) -> String? {
        switch event {
        case .placed(let orderId, _): orderId
        }
    }

    static func apply(_ state: PMState, _ event: PMOrderEvent) -> PMState {
        switch event {
        case .placed(_, let total):
            PMFulfillmentPM.State(total: total, paid: false)
        }
    }

    static func react(_ state: PMState, _ event: PMOrderEvent) -> [any Event] {
        switch event {
        case .placed(let orderId, let total):
            [PMFulfillmentEvent.paymentRequested(orderId: orderId, amount: total)]
        }
    }
}

enum PMOnPaymentResult: EventReaction {
    typealias PMState = PMFulfillmentPM.State
    typealias Input = PMPaymentEvent

    static let eventTypes = ["PaymentCharged", "PaymentFailed"]

    static func route(_ event: PMPaymentEvent) -> String? {
        switch event {
        case .charged(let orderId): orderId
        case .failed(let orderId, _): orderId
        }
    }

    static func apply(_ state: PMState, _ event: PMPaymentEvent) -> PMState {
        switch event {
        case .charged:
            PMFulfillmentPM.State(total: state.total, paid: true)
        case .failed:
            state
        }
    }

    static func react(_ state: PMState, _ event: PMPaymentEvent) -> [any Event] {
        switch event {
        case .charged(let orderId):
            [PMFulfillmentEvent.shipmentRequested(orderId: orderId)]
        case .failed:
            []
        }
    }
}

// MARK: - Process Manager

enum PMFulfillmentPM: ProcessManager {
    struct State: Sendable, Equatable {
        var total: Int
        var paid: Bool
    }

    static let processId = "fulfillment"
    static let initialState = State(total: 0, paid: false)

    static let reactions: [AnyReaction<State>] = [
        reaction(for: PMOnOrderPlaced.self, categories: ["order"]),
        reaction(for: PMOnPaymentResult.self, categories: ["payment"]),
    ]
}

// MARK: - Tests

@Suite("ProcessManager")
struct ProcessManagerTests {

    // MARK: - Protocol Properties

    @Test func processIdIsAccessible() {
        #expect(PMFulfillmentPM.processId == "fulfillment")
    }

    @Test func initialStateIsAccessible() {
        #expect(PMFulfillmentPM.initialState == PMFulfillmentPM.State(total: 0, paid: false))
    }

    @Test func reactionsContainsBothReactors() {
        #expect(PMFulfillmentPM.reactions.count == 2)
    }

    // MARK: - Reaction Registration

    @Test func firstReactionHasCorrectEventTypes() {
        #expect(PMFulfillmentPM.reactions[0].eventTypes == ["OrderPlaced"])
    }

    @Test func firstReactionHasCorrectCategories() {
        #expect(PMFulfillmentPM.reactions[0].categories == ["order"])
    }

    @Test func secondReactionHasCorrectEventTypes() {
        #expect(PMFulfillmentPM.reactions[1].eventTypes == ["PaymentCharged", "PaymentFailed"])
    }

    @Test func secondReactionHasCorrectCategories() {
        #expect(PMFulfillmentPM.reactions[1].categories == ["payment"])
    }

    // MARK: - AnyReaction Routing via Registration Helper

    @Test func reactionRoutesOrderPlacedEvent() throws {
        let event = PMOrderEvent.placed(orderId: "order-1", total: 100)
        let data = try JSONEncoder().encode(event)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "order", id: "order-1"),
            position: 0,
            globalPosition: 0,
            eventType: "OrderPlaced",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let route = try PMFulfillmentPM.reactions[0].tryRoute(recorded)
        #expect(route == "order-1")
    }

    @Test func reactionReturnsNilForNonMatchingEventType() throws {
        let event = PMOrderEvent.placed(orderId: "order-1", total: 100)
        let data = try JSONEncoder().encode(event)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "order", id: "order-1"),
            position: 0,
            globalPosition: 0,
            eventType: "SomethingElse",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let route = try PMFulfillmentPM.reactions[0].tryRoute(recorded)
        #expect(route == nil)
    }

    // MARK: - AnyReaction Handle via Registration Helper

    @Test func reactionAppliesOrderPlacedAndProducesOutput() throws {
        let event = PMOrderEvent.placed(orderId: "order-1", total: 250)
        let data = try JSONEncoder().encode(event)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "order", id: "order-1"),
            position: 0,
            globalPosition: 0,
            eventType: "OrderPlaced",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let initialState = PMFulfillmentPM.initialState
        let (newState, output) = try PMFulfillmentPM.reactions[0].handle(initialState, recorded)

        #expect(newState == PMFulfillmentPM.State(total: 250, paid: false))
        #expect(output.count == 1)
        #expect(
            (output[0] as? PMFulfillmentEvent) == PMFulfillmentEvent.paymentRequested(
                orderId: "order-1", amount: 250))
    }

    @Test func reactionAppliesPaymentChargedAndProducesShipment() throws {
        let event = PMPaymentEvent.charged(orderId: "order-1")
        let data = try JSONEncoder().encode(event)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "payment", id: "order-1"),
            position: 0,
            globalPosition: 0,
            eventType: "PaymentCharged",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let currentState = PMFulfillmentPM.State(total: 250, paid: false)
        let (newState, output) = try PMFulfillmentPM.reactions[1].handle(currentState, recorded)

        #expect(newState == PMFulfillmentPM.State(total: 250, paid: true))
        #expect(output.count == 1)
        #expect(
            (output[0] as? PMFulfillmentEvent) == PMFulfillmentEvent.shipmentRequested(
                orderId: "order-1"))
    }

    @Test func reactionAppliesPaymentFailedWithNoOutput() throws {
        let event = PMPaymentEvent.failed(orderId: "order-1", reason: "Insufficient funds")
        let data = try JSONEncoder().encode(event)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "payment", id: "order-1"),
            position: 0,
            globalPosition: 0,
            eventType: "PaymentFailed",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let currentState = PMFulfillmentPM.State(total: 250, paid: false)
        let (newState, output) = try PMFulfillmentPM.reactions[1].handle(currentState, recorded)

        #expect(newState == PMFulfillmentPM.State(total: 250, paid: false))
        #expect(output.isEmpty)
    }
}
