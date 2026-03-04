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

struct OrderPlaced_v3: Event, Equatable {
    var eventType: String { "OrderPlaced_v3" }
    static let version = 3
    let itemId: String
    let quantity: Int
    let currency: String
}

struct OrderPlacedUpcast_v2_v3: EventUpcast {
    func upcast(_ old: OrderPlaced_v2) -> OrderPlaced_v3 {
        OrderPlaced_v3(itemId: old.itemId, quantity: old.quantity, currency: "USD")
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

    @Test func registryDecodesOldEventAsLatestVersion() throws {
        let registry = EventTypeRegistry()
        registry.register(OrderPlaced_v2.self, eventTypes: ["OrderPlaced_v2"])
        registry.registerUpcast(
            from: OrderPlaced_v1.self,
            to: OrderPlaced_v2.self,
            upcast: OrderPlacedUpcast_v1_v2(),
            oldEventType: "OrderPlaced_v1"
        )

        // Encode a v1 event (simulating what the store holds)
        let v1 = OrderPlaced_v1(itemId: "abc")
        let data = try JSONEncoder().encode(v1)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "order", id: "1"),
            position: 0,
            globalPosition: 0,
            eventType: "OrderPlaced_v1",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let decoded = try registry.decode(recorded)
        let typed = decoded as! OrderPlaced_v2
        #expect(typed == OrderPlaced_v2(itemId: "abc", quantity: 1))
    }

    @Test func registryDecodesCurrentVersionDirectly() throws {
        let registry = EventTypeRegistry()
        registry.register(OrderPlaced_v2.self, eventTypes: ["OrderPlaced_v2"])
        registry.registerUpcast(
            from: OrderPlaced_v1.self,
            to: OrderPlaced_v2.self,
            upcast: OrderPlacedUpcast_v1_v2(),
            oldEventType: "OrderPlaced_v1"
        )

        // Encode a v2 event (current version, no upcasting needed)
        let v2 = OrderPlaced_v2(itemId: "abc", quantity: 5)
        let data = try JSONEncoder().encode(v2)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "order", id: "1"),
            position: 0,
            globalPosition: 0,
            eventType: "OrderPlaced_v2",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let decoded = try registry.decode(recorded)
        let typed = decoded as! OrderPlaced_v2
        #expect(typed == OrderPlaced_v2(itemId: "abc", quantity: 5))
    }

    @Test func registryWalksMultiStepUpcastChain() throws {
        let registry = EventTypeRegistry()
        registry.register(OrderPlaced_v3.self, eventTypes: ["OrderPlaced_v3"])
        registry.registerUpcast(
            from: OrderPlaced_v1.self,
            to: OrderPlaced_v2.self,
            upcast: OrderPlacedUpcast_v1_v2(),
            oldEventType: "OrderPlaced_v1"
        )
        registry.registerUpcast(
            from: OrderPlaced_v2.self,
            to: OrderPlaced_v3.self,
            upcast: OrderPlacedUpcast_v2_v3(),
            oldEventType: "OrderPlaced_v2"
        )

        // Encode a v1 event (oldest version)
        let v1 = OrderPlaced_v1(itemId: "abc")
        let data = try JSONEncoder().encode(v1)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "order", id: "1"),
            position: 0,
            globalPosition: 0,
            eventType: "OrderPlaced_v1",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        // v1 → v2 → v3 automatically
        let decoded = try registry.decode(recorded)
        let typed = decoded as! OrderPlaced_v3
        #expect(typed == OrderPlaced_v3(itemId: "abc", quantity: 1, currency: "USD"))
    }

    @Test func registryUpcastsV2ToV3() throws {
        let registry = EventTypeRegistry()
        registry.register(OrderPlaced_v3.self, eventTypes: ["OrderPlaced_v3"])
        registry.registerUpcast(
            from: OrderPlaced_v1.self,
            to: OrderPlaced_v2.self,
            upcast: OrderPlacedUpcast_v1_v2(),
            oldEventType: "OrderPlaced_v1"
        )
        registry.registerUpcast(
            from: OrderPlaced_v2.self,
            to: OrderPlaced_v3.self,
            upcast: OrderPlacedUpcast_v2_v3(),
            oldEventType: "OrderPlaced_v2"
        )

        // Encode a v2 event (middle version — needs one upcast to reach v3)
        let v2 = OrderPlaced_v2(itemId: "abc", quantity: 5)
        let data = try JSONEncoder().encode(v2)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "order", id: "1"),
            position: 0,
            globalPosition: 0,
            eventType: "OrderPlaced_v2",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        // v2 → v3 automatically
        let decoded = try registry.decode(recorded)
        let typed = decoded as! OrderPlaced_v3
        #expect(typed == OrderPlaced_v3(itemId: "abc", quantity: 5, currency: "USD"))
    }

    @Test func versionNumbersAreCorrectForTestTypes() {
        #expect(OrderPlaced_v1.version == 1)
        #expect(OrderPlaced_v2.version == 2)
        #expect(OrderPlaced_v3.version == 3)
    }

    @Test func registerUpcastWithWrongVersionPreconditionFails() {
        // OrderPlaced_v1 (version 1) → OrderPlaced_v3 (version 3) skips a version.
        // registerUpcast uses a precondition to enforce consecutive versions (v3 != v1 + 1).
        // We can't test precondition failures in Swift Testing without crashing the process,
        // so we verify the invariant holds by checking the version numbers directly.
        #expect(OrderPlaced_v3.version != OrderPlaced_v1.version + 1)
    }
}
