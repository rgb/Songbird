import Foundation
import Songbird
import SongbirdTesting
import Testing

@testable import SongbirdHummingbird

private struct TestEvent: Event {
    var eventType: String { "TestEvent" }
    let value: Int
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
}
