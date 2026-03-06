import Metrics
import Testing
@testable import Songbird
@testable import SongbirdTesting

@Suite(.serialized)
struct ProjectionPipelineMetricsTests {
    struct MetricsTestEvent: Event {
        var eventType: String { "MetricsTestEvent" }
    }

    init() {
        TestMetricsFactory.bootstrap()
        TestMetricsFactory.shared.reset()
    }

    @Test func processingRecordsTimerPerProjector() async throws {
        let pipeline = ProjectionPipeline()
        let projector = RecordingProjector(id: "test-projector")
        await pipeline.register(projector)

        let task = Task { await pipeline.run() }

        let event = try RecordedEvent(event: MetricsTestEvent(), globalPosition: 0)
        await pipeline.enqueue(event)
        try await pipeline.waitForIdle()
        await pipeline.stop()
        await task.value

        let timer = TestMetricsFactory.shared.timer(
            "songbird_projection_process_duration_seconds",
            dimensions: [("projector_id", "test-projector")]
        )
        #expect(timer != nil)
        #expect(timer!.values.count == 1)
        #expect(timer!.values[0] > 0)
    }

    @Test func lagGaugeUpdatesAfterProcessing() async throws {
        let pipeline = ProjectionPipeline()
        let projector = RecordingProjector(id: "lag-projector")
        await pipeline.register(projector)

        let task = Task { await pipeline.run() }

        // Enqueue two events
        let event1 = try RecordedEvent(event: MetricsTestEvent(), globalPosition: 0)
        let event2 = try RecordedEvent(event: MetricsTestEvent(), globalPosition: 1)
        await pipeline.enqueue(event1)
        await pipeline.enqueue(event2)
        try await pipeline.waitForIdle()
        await pipeline.stop()
        await task.value

        let lag = TestMetricsFactory.shared.gauge("songbird_projection_lag")
        #expect(lag != nil)
        // After processing all events, lag should be 0
        #expect(lag?.lastValue == 0)
    }

    @Test func queueDepthUpdatesOnEnqueue() async throws {
        let pipeline = ProjectionPipeline()
        let projector = RecordingProjector(id: "depth-projector")
        await pipeline.register(projector)

        let task = Task { await pipeline.run() }

        let event = try RecordedEvent(event: MetricsTestEvent(), globalPosition: 0)
        await pipeline.enqueue(event)
        try await pipeline.waitForIdle()
        await pipeline.stop()
        await task.value

        let depth = TestMetricsFactory.shared.gauge("songbird_projection_queue_depth")
        #expect(depth != nil)
    }
}
