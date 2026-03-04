import Testing

@testable import Songbird
@testable import SongbirdTesting

// Test aggregate for harness tests
enum HarnessCounter: Aggregate {
    struct State: Sendable, Equatable {
        var count: Int
    }

    enum Event: Songbird.Event {
        case incremented(by: Int)
        case decremented(by: Int)

        var eventType: String {
            switch self {
            case .incremented: "Incremented"
            case .decremented: "Decremented"
            }
        }
    }

    enum Failure: Error {
        case cannotDecrementBelowZero
    }

    static let category = "harness-counter"
    static let initialState = State(count: 0)

    static func apply(_ state: State, _ event: Event) -> State {
        switch event {
        case .incremented(let by): State(count: state.count + by)
        case .decremented(let by): State(count: state.count - by)
        }
    }
}

struct IncrementBy: Command {
    var commandType: String { "IncrementBy" }
    let amount: Int
}

struct DecrementBy: Command {
    var commandType: String { "DecrementBy" }
    let amount: Int
}

enum IncrementByHandler: CommandHandler {
    typealias Agg = HarnessCounter
    typealias Cmd = IncrementBy

    static func handle(
        _ command: IncrementBy,
        given state: HarnessCounter.State
    ) throws(HarnessCounter.Failure) -> [HarnessCounter.Event] {
        [.incremented(by: command.amount)]
    }
}

enum DecrementByHandler: CommandHandler {
    typealias Agg = HarnessCounter
    typealias Cmd = DecrementBy

    static func handle(
        _ command: DecrementBy,
        given state: HarnessCounter.State
    ) throws(HarnessCounter.Failure) -> [HarnessCounter.Event] {
        guard state.count >= command.amount else { throw .cannotDecrementBelowZero }
        return [.decremented(by: command.amount)]
    }
}

@Suite("TestAggregateHarness")
struct TestAggregateHarnessTests {

    @Test func startsWithInitialState() {
        let harness = TestAggregateHarness<HarnessCounter>()
        #expect(harness.state == HarnessCounter.State(count: 0))
        #expect(harness.version == -1)
        #expect(harness.appliedEvents.isEmpty)
    }

    @Test func startsWithCustomState() {
        let harness = TestAggregateHarness<HarnessCounter>(
            state: HarnessCounter.State(count: 10)
        )
        #expect(harness.state == HarnessCounter.State(count: 10))
    }

    @Test func givenFoldsEvents() {
        var harness = TestAggregateHarness<HarnessCounter>()
        harness.given(.incremented(by: 5), .incremented(by: 3))
        #expect(harness.state == HarnessCounter.State(count: 8))
        #expect(harness.version == 1)
        #expect(harness.appliedEvents.count == 2)
    }

    @Test func givenWithArrayFoldsEvents() {
        var harness = TestAggregateHarness<HarnessCounter>()
        harness.given([.incremented(by: 1), .decremented(by: 1), .incremented(by: 10)])
        #expect(harness.state == HarnessCounter.State(count: 10))
        #expect(harness.version == 2)
    }

    @Test func whenExecutesCommandHandler() throws {
        var harness = TestAggregateHarness<HarnessCounter>()
        let events = try harness.when(IncrementBy(amount: 7), using: IncrementByHandler.self)
        #expect(events == [.incremented(by: 7)])
        #expect(harness.state == HarnessCounter.State(count: 7))
        #expect(harness.version == 0)
    }

    @Test func whenThrowsOnFailedValidation() {
        var harness = TestAggregateHarness<HarnessCounter>()
        #expect(throws: HarnessCounter.Failure.self) {
            try harness.when(DecrementBy(amount: 1), using: DecrementByHandler.self)
        }
        #expect(harness.state == HarnessCounter.State(count: 0))
        #expect(harness.version == -1)
    }

    @Test func givenThenWhenWorkflow() throws {
        var harness = TestAggregateHarness<HarnessCounter>()
        harness.given(.incremented(by: 10))
        let events = try harness.when(DecrementBy(amount: 3), using: DecrementByHandler.self)
        #expect(events == [.decremented(by: 3)])
        #expect(harness.state == HarnessCounter.State(count: 7))
        #expect(harness.version == 1)
        #expect(harness.appliedEvents.count == 2)
    }

    @Test func versionIncrementsPerEvent() throws {
        var harness = TestAggregateHarness<HarnessCounter>()
        #expect(harness.version == -1)
        harness.given(.incremented(by: 1))
        #expect(harness.version == 0)
        harness.given(.incremented(by: 1))
        #expect(harness.version == 1)
        _ = try harness.when(IncrementBy(amount: 1), using: IncrementByHandler.self)
        #expect(harness.version == 2)
    }
}
