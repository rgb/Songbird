import Metrics
import Testing
@testable import Songbird
@testable import SongbirdTesting

extension MetricsTestSuite {
@Suite(.serialized)
struct GatewayRunnerMetricsTests {
    struct GatewayMetricsEvent: Event {
        let data: String
        var eventType: String { "GatewayMetricsEvent" }
    }

    actor SuccessGateway: Gateway {
        static let categories: [String] = ["gwMetrics"]
        let gatewayId = "success-gw"
        var handledCount = 0

        func handle(_ event: RecordedEvent) async throws {
            handledCount += 1
        }
    }

    actor FailingGateway: Gateway {
        static let categories: [String] = ["gwMetrics"]
        let gatewayId = "failing-gw"

        func handle(_ event: RecordedEvent) async throws {
            throw TestGatewayError()
        }
    }

    struct TestGatewayError: Error {}

    init() {
        TestMetricsFactory.bootstrap()
        TestMetricsFactory.shared.reset()
    }

    @Test func successfulDeliveryEmitsMetrics() async throws {
        let store = InMemoryEventStore()
        let positionStore = InMemoryPositionStore()
        let gateway = SuccessGateway()

        let runner = GatewayRunner(
            gateway: gateway, store: store, positionStore: positionStore,
            tickInterval: .milliseconds(10)
        )
        let task = Task { try await runner.run() }

        _ = try await store.append(
            GatewayMetricsEvent(data: "hello"),
            to: StreamName(category: "gwMetrics", id: "1"),
            metadata: EventMetadata(), expectedVersion: nil
        )

        // Wait for processing
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        _ = await task.result

        // Gateway delivery metrics
        let successCounter = TestMetricsFactory.shared.counter(
            "songbird_gateway_delivery_total",
            dimensions: [("gateway_id", "success-gw"), ("status", "success")]
        )
        #expect(successCounter?.totalValue == 1)

        let deliveryTimer = TestMetricsFactory.shared.timer(
            "songbird_gateway_delivery_duration_seconds",
            dimensions: [("gateway_id", "success-gw")]
        )
        #expect(deliveryTimer?.values.count == 1)

        // Subscription metrics (emitted by EventSubscription)
        let position = TestMetricsFactory.shared.gauge(
            "songbird_subscription_position",
            dimensions: [("subscriber_id", "success-gw")]
        )
        #expect(position != nil)

        let batchSize = TestMetricsFactory.shared.gauge(
            "songbird_subscription_batch_size",
            dimensions: [("subscriber_id", "success-gw")]
        )
        #expect(batchSize != nil)
        #expect(batchSize!.lastValue == 1)

        let tickTimer = TestMetricsFactory.shared.timer(
            "songbird_subscription_tick_duration_seconds",
            dimensions: [("subscriber_id", "success-gw")]
        )
        #expect(tickTimer != nil)
    }

    @Test func failedDeliveryEmitsFailureStatus() async throws {
        let store = InMemoryEventStore()
        let positionStore = InMemoryPositionStore()
        let gateway = FailingGateway()

        let runner = GatewayRunner(
            gateway: gateway, store: store, positionStore: positionStore,
            tickInterval: .milliseconds(10)
        )
        let task = Task { try await runner.run() }

        _ = try await store.append(
            GatewayMetricsEvent(data: "hello"),
            to: StreamName(category: "gwMetrics", id: "1"),
            metadata: EventMetadata(), expectedVersion: nil
        )

        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        _ = await task.result

        let failureCounter = TestMetricsFactory.shared.counter(
            "songbird_gateway_delivery_total",
            dimensions: [("gateway_id", "failing-gw"), ("status", "failure")]
        )
        #expect(failureCounter?.totalValue == 1)

        let errorsCounter = TestMetricsFactory.shared.counter(
            "songbird_subscription_errors_total",
            dimensions: [("subscriber_id", "failing-gw")]
        )
        #expect(errorsCounter?.totalValue == 1)

        // Timer still records even on failure
        let deliveryTimer = TestMetricsFactory.shared.timer(
            "songbird_gateway_delivery_duration_seconds",
            dimensions: [("gateway_id", "failing-gw")]
        )
        #expect(deliveryTimer?.values.count == 1)
    }
}
}
