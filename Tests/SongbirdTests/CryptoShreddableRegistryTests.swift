import Testing
@testable import Songbird

@Suite("CryptoShreddableRegistry")
struct CryptoShreddableRegistryTests {
    struct SecureEvent: Event, CryptoShreddable {
        let name: Shreddable<String>
        let amount: Double
        var eventType: String { "SecureEvent" }
        static let fieldProtection: [String: FieldProtection] = [
            "name": .pii,
        ]
    }

    struct PlainEvent: Event {
        let data: String
        var eventType: String { "PlainEvent" }
    }

    @Test func registeredEventReturnsProtection() {
        var registry = CryptoShreddableRegistry()
        registry.register(SecureEvent.self, eventType: "SecureEvent")
        let protection = registry.fieldProtection(for: "SecureEvent")
        #expect(protection?["name"] == .pii)
    }

    @Test func unregisteredEventReturnsNil() {
        let registry = CryptoShreddableRegistry()
        let protection = registry.fieldProtection(for: "UnknownEvent")
        #expect(protection == nil)
    }

    @Test func multipleRegistrations() {
        struct AnotherEvent: Event, CryptoShreddable {
            let email: Shreddable<String>
            var eventType: String { "AnotherEvent" }
            static let fieldProtection: [String: FieldProtection] = [
                "email": .retention(.seconds(3600)),
            ]
        }

        var registry = CryptoShreddableRegistry()
        registry.register(SecureEvent.self, eventType: "SecureEvent")
        registry.register(AnotherEvent.self, eventType: "AnotherEvent")

        #expect(registry.fieldProtection(for: "SecureEvent")?["name"] == .pii)
        #expect(registry.fieldProtection(for: "AnotherEvent")?["email"] == .retention(.seconds(3600)))
    }
}
