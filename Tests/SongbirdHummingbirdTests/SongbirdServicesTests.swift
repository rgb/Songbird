import Foundation
import Songbird
import SongbirdTesting
import Testing

@testable import SongbirdHummingbird

private struct ServicesTestEvent: Event {
    var eventType: String { "ServicesTestEvent" }
}

private actor ServicesTestGateway: Gateway {
    let gatewayId = "services-test-gateway"
    static let categories = ["svcTest"]
    private(set) var handledEvents: [RecordedEvent] = []

    func handle(_ event: RecordedEvent) async throws {
        handledEvents.append(event)
    }
}

private enum ServicesTestReaction: EventReaction {
    typealias PMState = Void
    typealias Input = ServicesTestEvent

    static let eventTypes = ["ServicesTestEvent"]

    static func route(_ event: ServicesTestEvent) -> String? { nil }
    static func apply(_ state: Void, _ event: ServicesTestEvent) -> Void { () }
}

private enum ServicesTestPM: ProcessManager {
    typealias State = Void

    static let processId = "services-test-pm"
    static let initialState: Void = ()
    static let reactions: [AnyReaction<Void>] = [
        reaction(for: ServicesTestReaction.self, categories: ["svcTest"]),
    ]
}

private actor ServicesTestInjector: Injector {
    let injectorId = "services-test-injector"

    private let (stream, continuation) = AsyncThrowingStream<InboundEvent, Error>.makeStream()
    private(set) var appendResults: [Result<RecordedEvent, any Error>] = []

    nonisolated func events() -> AsyncThrowingStream<InboundEvent, Error> {
        stream
    }

    nonisolated func yield(_ event: InboundEvent) {
        continuation.yield(event)
    }

    nonisolated func finish() {
        continuation.finish()
    }

    func didAppend(_ event: InboundEvent, result: Result<RecordedEvent, any Error>) async {
        appendResults.append(result)
    }
}

@Suite("SongbirdServices")
struct SongbirdServicesTests {
    /// Polls a condition until it returns true, with a timeout safety net.
    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while try !(await condition()) {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @Test func registerProjectorAndRunPipeline() async throws {
        let store = InMemoryEventStore()
        let pipeline = ProjectionPipeline()
        let projector = RecordingProjector()

        var services = SongbirdServices(
            eventStore: store,
            projectionPipeline: pipeline,
            positionStore: InMemoryPositionStore(),
            eventRegistry: EventTypeRegistry()
        )
        services.registerProjector(projector)

        let serviceTask = Task { try await services.run() }

        let recorded = try await store.append(
            ServicesTestEvent(),
            to: StreamName(category: "test", id: "1"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )
        await pipeline.enqueue(recorded)
        try await pipeline.waitForIdle()

        let count = await projector.appliedEvents.count
        #expect(count == 1)

        serviceTask.cancel()
        try? await serviceTask.value
    }

    @Test func registerGatewayAndRun() async throws {
        let store = InMemoryEventStore()
        let pipeline = ProjectionPipeline()
        let gateway = ServicesTestGateway()

        var services = SongbirdServices(
            eventStore: store,
            projectionPipeline: pipeline,
            positionStore: InMemoryPositionStore(),
            eventRegistry: EventTypeRegistry()
        )
        services.registerGateway(gateway, tickInterval: .milliseconds(10))

        let serviceTask = Task { try await services.run() }

        // Append an event in the gateway's subscribed category
        _ = try await store.append(
            ServicesTestEvent(),
            to: StreamName(category: "svcTest", id: "1"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Poll until the gateway runner processes the event
        try await waitUntil {
            await gateway.handledEvents.count >= 1
        }

        let count = await gateway.handledEvents.count
        #expect(count == 1)

        serviceTask.cancel()
        try? await serviceTask.value
    }

    @Test func cancellationStopsService() async throws {
        let pipeline = ProjectionPipeline()
        let services = SongbirdServices(
            eventStore: InMemoryEventStore(),
            projectionPipeline: pipeline,
            positionStore: InMemoryPositionStore(),
            eventRegistry: EventTypeRegistry()
        )

        let serviceTask = Task { try await services.run() }

        try await Task.sleep(for: .milliseconds(50))

        serviceTask.cancel()
        // Should complete without hanging
        try? await serviceTask.value
    }

    @Test func registerProcessManager() async throws {
        let store = InMemoryEventStore()
        let pipeline = ProjectionPipeline()
        let positionStore = InMemoryPositionStore()

        var services = SongbirdServices(
            eventStore: store,
            projectionPipeline: pipeline,
            positionStore: positionStore,
            eventRegistry: EventTypeRegistry()
        )
        services.registerProcessManager(ServicesTestPM.self)

        let serviceTask = Task { try await services.run() }

        // Append an event in the PM's subscribed category
        _ = try await store.append(
            ServicesTestEvent(),
            to: StreamName(category: "svcTest", id: "1"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Poll until the PM runner processes the event
        let streamName = StreamName(category: "svcTest", id: "1")
        try await waitUntil {
            let events = try await store.readStream(streamName, from: 0, maxCount: 10)
            return events.count >= 1
        }

        // Verify the event was persisted in the store
        let storedEvents = try await store.readStream(
            StreamName(category: "svcTest", id: "1"),
            from: 0,
            maxCount: 10
        )
        #expect(storedEvents.count == 1)
        #expect(storedEvents[0].eventType == "ServicesTestEvent")

        serviceTask.cancel()
        try? await serviceTask.value
    }

    @Test func registerMultipleProjectors() async throws {
        let store = InMemoryEventStore()
        let pipeline = ProjectionPipeline()
        let projectorA = RecordingProjector(id: "projector-a")
        let projectorB = RecordingProjector(id: "projector-b")

        var services = SongbirdServices(
            eventStore: store,
            projectionPipeline: pipeline,
            positionStore: InMemoryPositionStore(),
            eventRegistry: EventTypeRegistry()
        )
        services.registerProjector(projectorA)
        services.registerProjector(projectorB)

        let serviceTask = Task { try await services.run() }

        let recorded = try await store.append(
            ServicesTestEvent(),
            to: StreamName(category: "test", id: "1"),
            metadata: EventMetadata(),
            expectedVersion: nil
        )
        await pipeline.enqueue(recorded)
        try await pipeline.waitForIdle()

        let countA = await projectorA.appliedEvents.count
        let countB = await projectorB.appliedEvents.count
        #expect(countA == 1)
        #expect(countB == 1)

        serviceTask.cancel()
        try? await serviceTask.value
    }

    @Test func registerInjectorAndRun() async throws {
        let store = InMemoryEventStore()
        let pipeline = ProjectionPipeline()
        let injector = ServicesTestInjector()

        var services = SongbirdServices(
            eventStore: store,
            projectionPipeline: pipeline,
            positionStore: InMemoryPositionStore(),
            eventRegistry: EventTypeRegistry()
        )
        services.registerInjector(injector)

        let serviceTask = Task { try await services.run() }

        let inbound = InboundEvent(
            event: ServicesTestEvent(),
            stream: StreamName(category: "inboundTest", id: "1"),
            metadata: EventMetadata()
        )
        injector.yield(inbound)

        // Poll until the injector runner processes the yielded event
        let inboundStream = StreamName(category: "inboundTest", id: "1")
        try await waitUntil {
            let events = try await store.readStream(inboundStream, from: 0, maxCount: 10)
            return events.count >= 1
        }

        let storedEvents = try await store.readStream(
            StreamName(category: "inboundTest", id: "1"),
            from: 0,
            maxCount: 10
        )
        #expect(storedEvents.count == 1)

        let results = await injector.appendResults
        #expect(results.count == 1)
        if case .failure(let error) = results[0] {
            Issue.record("Expected success but got failure: \(error)")
        }

        serviceTask.cancel()
        try? await serviceTask.value
    }
}
