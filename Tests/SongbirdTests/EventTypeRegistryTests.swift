import Foundation
import Testing

@testable import Songbird

enum AccountEvent: Event {
    case deposited(amount: Int)
    case withdrawn(amount: Int, reason: String)

    var eventType: String {
        switch self {
        case .deposited: "Deposited"
        case .withdrawn: "Withdrawn"
        }
    }
}

@Suite("EventTypeRegistry")
struct EventTypeRegistryTests {
    @Test func registerAndDecode() throws {
        let registry = EventTypeRegistry()
        registry.register(AccountEvent.self, eventTypes: ["Deposited", "Withdrawn"])

        let event = AccountEvent.deposited(amount: 100)
        let data = try JSONEncoder().encode(event)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "account", id: "1"),
            position: 0,
            globalPosition: 0,
            eventType: "Deposited",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let decoded = try registry.decode(recorded)
        let typed = decoded as! AccountEvent
        #expect(typed == .deposited(amount: 100))
    }

    @Test func decodeUnregisteredTypeThrows() throws {
        let registry = EventTypeRegistry()

        let data = try JSONEncoder().encode(AccountEvent.deposited(amount: 50))
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "account", id: "1"),
            position: 0,
            globalPosition: 0,
            eventType: "Deposited",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        #expect(throws: EventTypeRegistryError.self) {
            _ = try registry.decode(recorded)
        }
    }

    @Test func decodeCorruptedDataThrows() throws {
        let registry = EventTypeRegistry()
        registry.register(AccountEvent.self, eventTypes: ["Deposited"])
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "account", id: "1"),
            position: 0,
            globalPosition: 0,
            eventType: "Deposited",
            data: Data("not json".utf8),
            metadata: EventMetadata(),
            timestamp: Date()
        )
        #expect(throws: DecodingError.self) {
            _ = try registry.decode(recorded)
        }
    }

    @Test func registerMultipleTypes() throws {
        let registry = EventTypeRegistry()
        registry.register(AccountEvent.self, eventTypes: ["Deposited", "Withdrawn"])

        let depositData = try JSONEncoder().encode(AccountEvent.deposited(amount: 100))
        let withdrawData = try JSONEncoder().encode(AccountEvent.withdrawn(amount: 50, reason: "ATM"))

        let depositRecorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "account", id: "1"),
            position: 0,
            globalPosition: 0,
            eventType: "Deposited",
            data: depositData,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let withdrawRecorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "account", id: "1"),
            position: 1,
            globalPosition: 1,
            eventType: "Withdrawn",
            data: withdrawData,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let d = try registry.decode(depositRecorded) as! AccountEvent
        let w = try registry.decode(withdrawRecorded) as! AccountEvent
        #expect(d == .deposited(amount: 100))
        #expect(w == .withdrawn(amount: 50, reason: "ATM"))
    }

    @Test func duplicateRegistrationOverwritesPrevious() throws {
        let registry = EventTypeRegistry()
        registry.register(AccountEvent.self, eventTypes: ["Deposited"])
        // Re-register same type for same string (misconfiguration but shouldn't crash)
        registry.register(AccountEvent.self, eventTypes: ["Deposited"])

        let data = try JSONEncoder().encode(AccountEvent.deposited(amount: 100))
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "account", id: "1"),
            position: 0,
            globalPosition: 0,
            eventType: "Deposited",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )
        let decoded = try registry.decode(recorded) as! AccountEvent
        #expect(decoded == .deposited(amount: 100))
    }

    @Test func existingEventsDefaultToVersion1() {
        #expect(AccountEvent.version == 1)
    }
}
