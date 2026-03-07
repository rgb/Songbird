import Foundation
import Songbird
import SongbirdTesting
import Testing

@testable import SongbirdHummingbird

private struct TestEvent: Event {
    var eventType: String { "TestEvent" }
    let value: Int
}

// Domain types for executeAndProject tests
private enum CounterEvent: Event, Equatable {
    case incremented(amount: Int)

    var eventType: String {
        switch self {
        case .incremented: "Incremented"
        }
    }
}

private enum CounterAggregate: Aggregate {
    struct State: Sendable, Equatable, Codable {
        var count: Int
    }
    typealias Failure = CounterError

    static let category = "counter"
    static let initialState = State(count: 0)

    static func apply(_ state: State, _ event: CounterEvent) -> State {
        switch event {
        case .incremented(let amount):
            State(count: state.count + amount)
        }
    }
}

private enum CounterError: Error {
    case negativeAmount
}

private struct IncrementCounter: Command {
    let amount: Int
    var commandType: String { "IncrementCounter" }
}

private enum IncrementHandler: CommandHandler {
    typealias Agg = CounterAggregate
    typealias Cmd = IncrementCounter

    static func handle(
        _ command: IncrementCounter,
        given state: CounterAggregate.State
    ) throws(CounterAggregate.Failure) -> [CounterEvent] {
        guard command.amount > 0 else { throw .negativeAmount }
        return [.incremented(amount: command.amount)]
    }
}

@Suite("RouteHelpers")
struct RouteHelperTests {
    @Test func appendAndProjectStoresEvent() async throws {
        let store = InMemoryEventStore()
        let pipeline = ProjectionPipeline()
        let projector = RecordingProjector()
        await pipeline.register(projector)
        let pipelineTask = Task { await pipeline.run() }

        let recorded = try await appendAndProject(
            TestEvent(value: 42),
            to: StreamName(category: "test", id: "1"),
            metadata: EventMetadata(traceId: "trace-1"),
            services: SongbirdServices(
                eventStore: store,
                projectionPipeline: pipeline,
                positionStore: InMemoryPositionStore(),
                eventRegistry: EventTypeRegistry()
            )
        )

        #expect(recorded.eventType == "TestEvent")
        #expect(recorded.streamName == StreamName(category: "test", id: "1"))
        #expect(recorded.metadata.traceId == "trace-1")

        try await pipeline.waitForIdle()
        let count = await projector.appliedEvents.count
        #expect(count == 1)

        await pipeline.stop()
        await pipelineTask.value
    }

    @Test func appendAndProjectRespectsExpectedVersion() async throws {
        let store = InMemoryEventStore()
        let pipeline = ProjectionPipeline()
        let pipelineTask = Task { await pipeline.run() }
        let services = SongbirdServices(
            eventStore: store,
            projectionPipeline: pipeline,
            positionStore: InMemoryPositionStore(),
            eventRegistry: EventTypeRegistry()
        )
        let stream = StreamName(category: "test", id: "1")

        _ = try await appendAndProject(
            TestEvent(value: 1),
            to: stream,
            metadata: EventMetadata(),
            expectedVersion: -1,
            services: services
        )

        await #expect(throws: VersionConflictError.self) {
            try await appendAndProject(
                TestEvent(value: 2),
                to: stream,
                metadata: EventMetadata(),
                expectedVersion: -1,
                services: services
            )
        }

        await pipeline.stop()
        await pipelineTask.value
    }

    // MARK: - executeAndProject

    @Test func executeAndProjectStoresAndProjectsEvents() async throws {
        let registry = EventTypeRegistry()
        registry.register(CounterEvent.self, eventTypes: ["Incremented"])
        let store = InMemoryEventStore()
        let pipeline = ProjectionPipeline()
        let projector = RecordingProjector()
        await pipeline.register(projector)
        let pipelineTask = Task { await pipeline.run() }
        let services = SongbirdServices(
            eventStore: store,
            projectionPipeline: pipeline,
            positionStore: InMemoryPositionStore(),
            eventRegistry: registry
        )
        let repository = AggregateRepository<CounterAggregate>(
            store: store, registry: registry
        )

        let recorded = try await executeAndProject(
            IncrementCounter(amount: 5),
            on: "counter-1",
            metadata: EventMetadata(traceId: "trace-1"),
            using: IncrementHandler.self,
            repository: repository,
            services: services
        )

        #expect(recorded.count == 1)
        #expect(recorded[0].eventType == "Incremented")

        try await pipeline.waitForIdle()
        let count = await projector.appliedEvents.count
        #expect(count == 1)

        await pipeline.stop()
        await pipelineTask.value
    }

    @Test func executeAndProjectPropagatesCommandFailure() async throws {
        let registry = EventTypeRegistry()
        registry.register(CounterEvent.self, eventTypes: ["Incremented"])
        let store = InMemoryEventStore()
        let pipeline = ProjectionPipeline()
        let pipelineTask = Task { await pipeline.run() }
        let services = SongbirdServices(
            eventStore: store,
            projectionPipeline: pipeline,
            positionStore: InMemoryPositionStore(),
            eventRegistry: registry
        )
        let repository = AggregateRepository<CounterAggregate>(
            store: store, registry: registry
        )

        await #expect(throws: CounterError.self) {
            try await executeAndProject(
                IncrementCounter(amount: -1),
                on: "counter-1",
                metadata: EventMetadata(),
                using: IncrementHandler.self,
                repository: repository,
                services: services
            )
        }

        await pipeline.stop()
        await pipelineTask.value
    }
}
