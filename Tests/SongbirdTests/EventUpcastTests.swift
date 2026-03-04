import Foundation
import Testing

@testable import Songbird

// MARK: - Test Versioned Events

struct OrderPlaced_v1: Event, Equatable {
    var eventType: String { "OrderPlaced_v1" }
    static let version = 1
    let itemId: String
}

struct OrderPlaced_v2: Event, Equatable {
    var eventType: String { "OrderPlaced_v2" }
    static let version = 2
    let itemId: String
    let quantity: Int
}

// MARK: - Test Upcast

struct OrderPlacedUpcast_v1_v2: EventUpcast {
    func upcast(_ old: OrderPlaced_v1) -> OrderPlaced_v2 {
        OrderPlaced_v2(itemId: old.itemId, quantity: 1)
    }
}

@Suite("EventUpcast")
struct EventUpcastTests {
    @Test func upcastTransformsOldEventToNewEvent() {
        let upcast = OrderPlacedUpcast_v1_v2()
        let old = OrderPlaced_v1(itemId: "abc")
        let new = upcast.upcast(old)
        #expect(new == OrderPlaced_v2(itemId: "abc", quantity: 1))
    }
}
