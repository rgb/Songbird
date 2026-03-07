import Metrics
import Synchronization

/// A swift-metrics backend that captures all emitted metrics in memory for test assertions.
///
/// Usage:
/// ```swift
/// // Once per test process:
/// TestMetricsFactory.bootstrap()
///
/// // Before each test:
/// TestMetricsFactory.shared.reset()
///
/// // After running code that emits metrics:
/// let counter = TestMetricsFactory.shared.counter("my_counter")
/// #expect(counter?.totalValue == 1)
/// ```
public final class TestMetricsFactory: MetricsFactory, Sendable {
    public static let shared = TestMetricsFactory()

    private static let _doBootstrap: Bool = {
        MetricsSystem.bootstrap(TestMetricsFactory.shared)
        return true
    }()

    /// Bootstrap the global MetricsSystem with this factory. Safe to call multiple times.
    public static func bootstrap() {
        _ = _doBootstrap
    }

    private struct State: Sendable {
        var counters: [String: TestCounter] = [:]
        var timers: [String: TestTimer] = [:]
        var recorders: [String: TestRecorder] = [:]
    }

    private let state = Mutex(State())

    init() {}

    /// Reset all metric values. Call before each test to start fresh.
    public func reset() {
        state.withLock { state in
            for counter in state.counters.values { counter.reset() }
            for timer in state.timers.values { timer.reset() }
            for recorder in state.recorders.values { recorder.reset() }
        }
    }

    // MARK: - MetricsFactory

    public func makeCounter(label: String, dimensions: [(String, String)]) -> CounterHandler {
        state.withLock { state in
            let key = Self.makeKey(label, dimensions)
            if let existing = state.counters[key] { return existing }
            let handler = TestCounter()
            state.counters[key] = handler
            return handler
        }
    }

    public func makeRecorder(label: String, dimensions: [(String, String)], aggregate: Bool) -> RecorderHandler {
        state.withLock { state in
            let key = Self.makeKey(label, dimensions)
            if let existing = state.recorders[key] { return existing }
            let handler = TestRecorder()
            state.recorders[key] = handler
            return handler
        }
    }

    public func makeTimer(label: String, dimensions: [(String, String)]) -> TimerHandler {
        state.withLock { state in
            let key = Self.makeKey(label, dimensions)
            if let existing = state.timers[key] { return existing }
            let handler = TestTimer()
            state.timers[key] = handler
            return handler
        }
    }

    public func destroyCounter(_ handler: CounterHandler) {}
    public func destroyRecorder(_ handler: RecorderHandler) {}
    public func destroyTimer(_ handler: TimerHandler) {}

    // MARK: - Query API

    public func counter(_ label: String, dimensions: [(String, String)] = []) -> TestCounter? {
        state.withLock { $0.counters[Self.makeKey(label, dimensions)] }
    }

    public func timer(_ label: String, dimensions: [(String, String)] = []) -> TestTimer? {
        state.withLock { $0.timers[Self.makeKey(label, dimensions)] }
    }

    public func gauge(_ label: String, dimensions: [(String, String)] = []) -> TestRecorder? {
        state.withLock { $0.recorders[Self.makeKey(label, dimensions)] }
    }

    // MARK: - Key Construction

    private static func makeKey(_ label: String, _ dimensions: [(String, String)]) -> String {
        if dimensions.isEmpty { return label }
        let dims = dimensions.sorted { $0.0 < $1.0 }.map { "\($0.0)=\($0.1)" }.joined(separator: ",")
        return "\(label)[\(dims)]"
    }
}

// MARK: - Test Metric Handlers

public final class TestCounter: CounterHandler, Sendable {
    private let _value = Mutex<Int64>(0)

    public var totalValue: Int64 { _value.withLock { $0 } }

    public func increment(by amount: Int64) {
        _value.withLock { $0 += amount }
    }

    public func reset() {
        _value.withLock { $0 = 0 }
    }
}

public final class TestTimer: TimerHandler, Sendable {
    private let _values = Mutex<[Int64]>([])

    public var values: [Int64] { _values.withLock { $0 } }
    public var lastValue: Int64? { _values.withLock { $0.last } }

    public func recordNanoseconds(_ duration: Int64) {
        _values.withLock { $0.append(duration) }
    }

    public func reset() {
        _values.withLock { $0.removeAll() }
    }
}

public final class TestRecorder: RecorderHandler, Sendable {
    private struct RecorderState: Sendable {
        var lastValue: Double?
        var values: [Double] = []
    }

    private let _state = Mutex(RecorderState())

    public var lastValue: Double? { _state.withLock { $0.lastValue } }
    public var values: [Double] { _state.withLock { $0.values } }

    public func record(_ value: Int64) {
        _state.withLock { state in
            let d = Double(value)
            state.lastValue = d
            state.values.append(d)
        }
    }

    public func record(_ value: Double) {
        _state.withLock { state in
            state.lastValue = value
            state.values.append(value)
        }
    }

    public func reset() {
        _state.withLock { state in
            state.lastValue = nil
            state.values.removeAll()
        }
    }
}
