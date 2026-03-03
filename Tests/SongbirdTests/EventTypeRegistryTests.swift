import Foundation
import Testing

@testable import Songbird

struct TestDeposited: Event {
    static let eventType = "TestDeposited"
    let amount: Int
}

struct TestWithdrawn: Event {
    static let eventType = "TestWithdrawn"
    let amount: Int
    let reason: String
}

@Suite("EventTypeRegistry")
struct EventTypeRegistryTests {
    @Test func registerAndDecode() throws {
        let registry = EventTypeRegistry()
        registry.register(TestDeposited.self)

        let event = TestDeposited(amount: 100)
        let data = try JSONEncoder().encode(event)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "account", id: "1"),
            position: 0,
            globalPosition: 0,
            eventType: TestDeposited.eventType,
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let decoded = try registry.decode(recorded)
        let typed = decoded as! TestDeposited
        #expect(typed.amount == 100)
    }

    @Test func decodeUnregisteredTypeThrows() throws {
        let registry = EventTypeRegistry()

        let data = try JSONEncoder().encode(TestDeposited(amount: 50))
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "account", id: "1"),
            position: 0,
            globalPosition: 0,
            eventType: TestDeposited.eventType,
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        #expect(throws: (any Error).self) {
            _ = try registry.decode(recorded)
        }
    }

    @Test func registerMultipleTypes() throws {
        let registry = EventTypeRegistry()
        registry.register(TestDeposited.self)
        registry.register(TestWithdrawn.self)

        let depositData = try JSONEncoder().encode(TestDeposited(amount: 100))
        let withdrawData = try JSONEncoder().encode(TestWithdrawn(amount: 50, reason: "ATM"))

        let depositRecorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "account", id: "1"),
            position: 0,
            globalPosition: 0,
            eventType: TestDeposited.eventType,
            data: depositData,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let withdrawRecorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "account", id: "1"),
            position: 1,
            globalPosition: 1,
            eventType: TestWithdrawn.eventType,
            data: withdrawData,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let d = try registry.decode(depositRecorded) as! TestDeposited
        let w = try registry.decode(withdrawRecorded) as! TestWithdrawn
        #expect(d.amount == 100)
        #expect(w.amount == 50)
        #expect(w.reason == "ATM")
    }
}
