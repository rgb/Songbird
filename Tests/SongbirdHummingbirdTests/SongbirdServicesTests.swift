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
    static let categories = ["svc-test"]
    private(set) var handledEvents: [RecordedEvent] = []

    func handle(_ event: RecordedEvent) async throws {
        handledEvents.append(event)
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
            to: StreamName(category: "svc-test", id: "1"),
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
}
