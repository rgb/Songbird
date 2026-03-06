import Metrics
import Testing
@testable import Songbird
@testable import SongbirdTesting

extension MetricsTestSuite {
@Suite(.serialized)
struct MetricsEventStoreTests {
    struct TestEvent: Event {
        let data: String
        var eventType: String { "TestEvent" }
    }

    init() {
        TestMetricsFactory.bootstrap()
        TestMetricsFactory.shared.reset()
    }

    private func makeStore() -> MetricsEventStore<InMemoryEventStore> {
        MetricsEventStore(inner: InMemoryEventStore())
    }

    @Test func appendEmitsCounterAndTimer() async throws {
        let store = makeStore()
        let stream = StreamName(category: "order", id: "1")

        _ = try await store.append(
            TestEvent(data: "hello"), to: stream,
            metadata: EventMetadata(), expectedVersion: nil
        )

        let counter = TestMetricsFactory.shared.counter(
            "songbird_event_store_append_total",
            dimensions: [("stream_category", "order")]
        )
        #expect(counter?.totalValue == 1)

        let timer = TestMetricsFactory.shared.timer(
            "songbird_event_store_append_duration_seconds",
            dimensions: [("stream_category", "order")]
        )
        #expect(timer != nil)
        #expect(timer!.values.count == 1)
        #expect(timer!.values[0] > 0)
    }

    @Test func readStreamEmitsTimerAndEventCount() async throws {
        let store = makeStore()
        let stream = StreamName(category: "order", id: "1")

        _ = try await store.append(
            TestEvent(data: "a"), to: stream,
            metadata: EventMetadata(), expectedVersion: nil
        )
        _ = try await store.append(
            TestEvent(data: "b"), to: stream,
            metadata: EventMetadata(), expectedVersion: 0
        )
        TestMetricsFactory.shared.reset()

        _ = try await store.readStream(stream, from: 0, maxCount: 10)

        let timer = TestMetricsFactory.shared.timer(
            "songbird_event_store_read_duration_seconds",
            dimensions: [("stream_category", "order"), ("read_type", "stream")]
        )
        #expect(timer?.values.count == 1)

        let eventCount = TestMetricsFactory.shared.counter("songbird_event_store_read_events_total")
        #expect(eventCount?.totalValue == 2)
    }

    @Test func readCategoriesEmitsMetrics() async throws {
        let store = makeStore()

        _ = try await store.append(
            TestEvent(data: "a"), to: StreamName(category: "order", id: "1"),
            metadata: EventMetadata(), expectedVersion: nil
        )
        TestMetricsFactory.shared.reset()

        _ = try await store.readCategories(["order"], from: 0, maxCount: 10)

        let timer = TestMetricsFactory.shared.timer(
            "songbird_event_store_read_duration_seconds",
            dimensions: [("read_type", "categories")]
        )
        #expect(timer?.values.count == 1)
    }

    @Test func readAllUsesAllReadType() async throws {
        let store = makeStore()

        _ = try await store.append(
            TestEvent(data: "a"), to: StreamName(category: "order", id: "1"),
            metadata: EventMetadata(), expectedVersion: nil
        )
        TestMetricsFactory.shared.reset()

        _ = try await store.readAll(from: 0, maxCount: 10)

        let timer = TestMetricsFactory.shared.timer(
            "songbird_event_store_read_duration_seconds",
            dimensions: [("read_type", "all")]
        )
        #expect(timer?.values.count == 1)
    }

    @Test func readLastEventEmitsMetrics() async throws {
        let store = makeStore()
        let stream = StreamName(category: "order", id: "1")

        _ = try await store.append(
            TestEvent(data: "a"), to: stream,
            metadata: EventMetadata(), expectedVersion: nil
        )
        TestMetricsFactory.shared.reset()

        _ = try await store.readLastEvent(in: stream)

        let timer = TestMetricsFactory.shared.timer(
            "songbird_event_store_read_duration_seconds",
            dimensions: [("stream_category", "order"), ("read_type", "lastEvent")]
        )
        #expect(timer?.values.count == 1)

        let eventCount = TestMetricsFactory.shared.counter("songbird_event_store_read_events_total")
        #expect(eventCount?.totalValue == 1)
    }

    @Test func versionConflictEmitsCounter() async throws {
        let store = makeStore()
        let stream = StreamName(category: "order", id: "1")

        _ = try await store.append(
            TestEvent(data: "first"), to: stream,
            metadata: EventMetadata(), expectedVersion: nil
        )
        TestMetricsFactory.shared.reset()

        do {
            _ = try await store.append(
                TestEvent(data: "conflict"), to: stream,
                metadata: EventMetadata(), expectedVersion: 99
            )
        } catch {}

        let counter = TestMetricsFactory.shared.counter(
            "songbird_event_store_version_conflict_total",
            dimensions: [("stream_category", "order")]
        )
        #expect(counter?.totalValue == 1)

        // Append counter should NOT increment on conflict
        let appendCounter = TestMetricsFactory.shared.counter(
            "songbird_event_store_append_total",
            dimensions: [("stream_category", "order")]
        )
        #expect(appendCounter == nil || appendCounter?.totalValue == 0)
    }

    @Test func streamVersionEmitsNoMetrics() async throws {
        let store = makeStore()
        let stream = StreamName(category: "order", id: "1")

        _ = try await store.append(
            TestEvent(data: "a"), to: stream,
            metadata: EventMetadata(), expectedVersion: nil
        )
        TestMetricsFactory.shared.reset()

        _ = try await store.streamVersion(stream)

        // streamVersion is lightweight — no metrics
        let timer = TestMetricsFactory.shared.timer(
            "songbird_event_store_read_duration_seconds",
            dimensions: [("read_type", "streamVersion")]
        )
        #expect(timer == nil)
    }
}
}
