import Testing

@testable import Songbird

struct IncrementCounter: Command {
    var commandType: String { "IncrementCounter" }
    let amount: Int
}

@Suite("Command")
struct CommandTests {
    @Test func commandTypeIsAccessible() {
        let cmd = IncrementCounter(amount: 1)
        #expect(cmd.commandType == "IncrementCounter")
    }

    @Test func commandIsSendable() {
        let cmd = IncrementCounter(amount: 5)
        let closure: @Sendable () -> Void = { _ = cmd.amount }
        _ = closure
    }
}
