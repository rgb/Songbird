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

        // Wait for the gateway runner to poll and process
        try await Task.sleep(for: .milliseconds(100))

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

        // Give the runner time to process the yielded event
        try await Task.sleep(for: .milliseconds(100))

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
