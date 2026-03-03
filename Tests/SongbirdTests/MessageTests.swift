import Foundation
import Testing

@testable import Songbird

// MARK: - Test Types

enum TestEvent: Event {
    case happened(value: Int)

    var eventType: String {
        switch self {
        case .happened: "Happened"
        }
    }
}

struct TestCommand: Command {
    var commandType: String { "TestCommand" }
    let target: String
}

// MARK: - Tests

@Suite("Message")
struct MessageTests {

    // MARK: - Event conforms to Message

    @Test func eventConformsToMessage() {
        let event: any Message = TestEvent.happened(value: 42)
        #expect(event.messageType == "Happened")
    }

    @Test func eventMessageTypeMatchesEventType() {
        let event = TestEvent.happened(value: 7)
        #expect(event.messageType == event.eventType)
    }

    // MARK: - Command conforms to Message

    @Test func commandConformsToMessage() {
        let command: any Message = TestCommand(target: "x")
        #expect(command.messageType == "TestCommand")
    }

    @Test func commandMessageTypeMatchesCommandType() {
        let command = TestCommand(target: "y")
        #expect(command.messageType == command.commandType)
    }

    // MARK: - Command is Codable

    @Test func commandIsCodable() throws {
        let command = TestCommand(target: "hello")
        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(TestCommand.self, from: data)
        #expect(decoded == command)
    }

    // MARK: - Command is Equatable

    @Test func commandIsEquatable() {
        let a = TestCommand(target: "a")
        let b = TestCommand(target: "a")
        let c = TestCommand(target: "b")
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - Command commandType is instance property

    @Test func commandTypeIsInstanceProperty() {
        let command = TestCommand(target: "z")
        #expect(command.commandType == "TestCommand")
    }
}
