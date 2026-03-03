import Testing

@testable import Songbird

struct IncrementCounter: Command {
    static let commandType = "IncrementCounter"
    let amount: Int
}

@Suite("Command")
struct CommandTests {
    @Test func commandTypeIsAccessible() {
        #expect(IncrementCounter.commandType == "IncrementCounter")
    }

    @Test func commandIsSendable() {
        let cmd = IncrementCounter(amount: 5)
        let closure: @Sendable () -> Void = { _ = cmd.amount }
        _ = closure
    }
}
