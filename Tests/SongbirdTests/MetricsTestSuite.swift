import Testing

/// Parent suite that serializes all metrics tests across suites.
///
/// Metrics tests share a global `TestMetricsFactory` singleton whose `reset()` affects
/// all handlers. Without serialization across suites, concurrent tests can race:
/// one suite's `init()` calling `reset()` while another suite is mid-assertion.
@Suite(.serialized)
enum MetricsTestSuite {}
