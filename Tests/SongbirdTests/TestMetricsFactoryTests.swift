import Metrics
import Testing
@testable import SongbirdTesting

@Suite(.serialized)
struct TestMetricsFactoryTests {
    init() {
        TestMetricsFactory.bootstrap()
        TestMetricsFactory.shared.reset()
    }

    @Test func counterIncrements() {
        Counter(label: "test_counter").increment()
        Counter(label: "test_counter").increment(by: 4)

        let counter = TestMetricsFactory.shared.counter("test_counter")
        #expect(counter?.totalValue == 5)
    }

    @Test func timerRecordsValues() {
        Metrics.Timer(label: "test_timer").recordNanoseconds(1000)
        Metrics.Timer(label: "test_timer").recordNanoseconds(2000)

        let timer = TestMetricsFactory.shared.timer("test_timer")
        #expect(timer?.values == [1000, 2000])
    }

    @Test func gaugeRecordsLastValue() {
        Gauge(label: "test_gauge").record(42)
        Gauge(label: "test_gauge").record(99)

        let gauge = TestMetricsFactory.shared.gauge("test_gauge")
        #expect(gauge?.lastValue == 99)
    }

    @Test func dimensionsCreateSeparateHandlers() {
        Counter(label: "dim_counter", dimensions: [("env", "prod")]).increment()
        Counter(label: "dim_counter", dimensions: [("env", "test")]).increment(by: 3)

        let prod = TestMetricsFactory.shared.counter("dim_counter", dimensions: [("env", "prod")])
        let test = TestMetricsFactory.shared.counter("dim_counter", dimensions: [("env", "test")])
        #expect(prod?.totalValue == 1)
        #expect(test?.totalValue == 3)
    }

    @Test func resetClearsAllValues() {
        Counter(label: "reset_counter").increment()
        Metrics.Timer(label: "reset_timer").recordNanoseconds(100)
        Gauge(label: "reset_gauge").record(50)

        TestMetricsFactory.shared.reset()

        #expect(TestMetricsFactory.shared.counter("reset_counter")?.totalValue == 0)
        #expect(TestMetricsFactory.shared.timer("reset_timer")?.values.isEmpty == true)
        #expect(TestMetricsFactory.shared.gauge("reset_gauge")?.lastValue == nil)
    }
}
