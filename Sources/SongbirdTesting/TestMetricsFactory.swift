import Foundation
import Metrics

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
public final class TestMetricsFactory: MetricsFactory, @unchecked Sendable {
    public static let shared = TestMetricsFactory()

    private static let _doBootstrap: Bool = {
        MetricsSystem.bootstrap(TestMetricsFactory.shared)
        return true
    }()

    /// Bootstrap the global MetricsSystem with this factory. Safe to call multiple times.
    public static func bootstrap() {
        _ = _doBootstrap
    }

    private let lock = NSLock()
    private var _counters: [String: TestCounter] = [:]
    private var _timers: [String: TestTimer] = [:]
    private var _recorders: [String: TestRecorder] = [:]

    init() {}

    /// Reset all metric values. Call before each test to start fresh.
    public func reset() {
        lock.withLock {
            for counter in _counters.values { counter.reset() }
            for timer in _timers.values { timer.reset() }
            for recorder in _recorders.values { recorder.reset() }
        }
    }

    // MARK: - MetricsFactory

    public func makeCounter(label: String, dimensions: [(String, String)]) -> CounterHandler {
        lock.withLock {
            let key = Self.makeKey(label, dimensions)
            if let existing = _counters[key] { return existing }
            let handler = TestCounter()
            _counters[key] = handler
            return handler
        }
    }

    public func makeRecorder(label: String, dimensions: [(String, String)], aggregate: Bool) -> RecorderHandler {
        lock.withLock {
            let key = Self.makeKey(label, dimensions)
            if let existing = _recorders[key] { return existing }
            let handler = TestRecorder()
            _recorders[key] = handler
            return handler
        }
    }

    public func makeTimer(label: String, dimensions: [(String, String)]) -> TimerHandler {
        lock.withLock {
            let key = Self.makeKey(label, dimensions)
            if let existing = _timers[key] { return existing }
            let handler = TestTimer()
            _timers[key] = handler
            return handler
        }
    }

    public func destroyCounter(_ handler: CounterHandler) {}
    public func destroyRecorder(_ handler: RecorderHandler) {}
    public func destroyTimer(_ handler: TimerHandler) {}

    // MARK: - Query API

    public func counter(_ label: String, dimensions: [(String, String)] = []) -> TestCounter? {
        lock.withLock { _counters[Self.makeKey(label, dimensions)] }
    }

    public func timer(_ label: String, dimensions: [(String, String)] = []) -> TestTimer? {
        lock.withLock { _timers[Self.makeKey(label, dimensions)] }
    }

    public func gauge(_ label: String, dimensions: [(String, String)] = []) -> TestRecorder? {
        lock.withLock { _recorders[Self.makeKey(label, dimensions)] }
    }

    // MARK: - Key Construction

    private static func makeKey(_ label: String, _ dimensions: [(String, String)]) -> String {
        if dimensions.isEmpty { return label }
        let dims = dimensions.sorted { $0.0 < $1.0 }.map { "\($0.0)=\($0.1)" }.joined(separator: ",")
        return "\(label)[\(dims)]"
    }
}

// MARK: - Test Metric Handlers

public final class TestCounter: CounterHandler, @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var totalValue: Int64 = 0

    public func increment(by amount: Int64) {
        lock.withLock { totalValue += amount }
    }

    public func reset() {
        lock.withLock { totalValue = 0 }
    }
}

public final class TestTimer: TimerHandler, @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var values: [Int64] = []

    public var lastValue: Int64? { lock.withLock { values.last } }

    public func recordNanoseconds(_ duration: Int64) {
        lock.withLock { values.append(duration) }
    }

    public func reset() {
        lock.withLock { values.removeAll() }
    }
}

public final class TestRecorder: RecorderHandler, @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var lastValue: Double?
    public private(set) var values: [Double] = []

    public func record(_ value: Int64) {
        lock.withLock {
            let d = Double(value)
            lastValue = d
            values.append(d)
        }
    }

    public func record(_ value: Double) {
        lock.withLock {
            lastValue = value
            values.append(value)
        }
    }

    public func reset() {
        lock.withLock {
            lastValue = nil
            values.removeAll()
        }
    }
}
