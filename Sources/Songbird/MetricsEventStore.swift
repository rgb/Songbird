import Metrics

/// A decorator that wraps any ``EventStore``, emitting swift-metrics for every operation.
///
/// Composition order:
/// ```swift
/// MetricsEventStore(CryptoShreddingStore(SQLiteEventStore(...)))
/// ```
///
/// Metrics on the outside measure total time including any middleware (encryption, etc.).
/// All metrics are prefixed with `songbird_event_store_`.
///
/// If no `MetricsSystem` backend is bootstrapped, all metric calls are zero-cost no-ops.
public struct MetricsEventStore<Inner: EventStore>: Sendable {
    private let inner: Inner

    public init(inner: Inner) {
        self.inner = inner
    }
}

// MARK: - EventStore Conformance

extension MetricsEventStore: EventStore {
    public func append(
        _ event: some Event,
        to stream: StreamName,
        metadata: EventMetadata,
        expectedVersion: Int64?
    ) async throws -> RecordedEvent {
        let dims: [(String, String)] = [("stream_category", stream.category)]
        let start = ContinuousClock.now

        do {
            let result = try await inner.append(
                event, to: stream, metadata: metadata, expectedVersion: expectedVersion
            )
            let elapsed = ContinuousClock.now - start

            Counter(label: "songbird_event_store_append_total", dimensions: dims).increment()
            Metrics.Timer(label: "songbird_event_store_append_duration_seconds", dimensions: dims)
                .recordNanoseconds(elapsed.nanoseconds)

            return result
        } catch {
            let elapsed = ContinuousClock.now - start
            Metrics.Timer(label: "songbird_event_store_append_duration_seconds", dimensions: dims)
                .recordNanoseconds(elapsed.nanoseconds)

            if error is VersionConflictError {
                Counter(label: "songbird_event_store_version_conflict_total", dimensions: dims).increment()
            } else {
                Counter(label: "songbird_event_store_append_errors_total", dimensions: dims).increment()
            }

            throw error
        }
    }

    public func readStream(
        _ stream: StreamName,
        from position: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        let dims: [(String, String)] = [("stream_category", stream.category), ("read_type", "stream")]
        let start = ContinuousClock.now

        do {
            let results = try await inner.readStream(stream, from: position, maxCount: maxCount)
            let elapsed = ContinuousClock.now - start

            Metrics.Timer(label: "songbird_event_store_read_duration_seconds", dimensions: dims)
                .recordNanoseconds(elapsed.nanoseconds)
            Counter(label: "songbird_event_store_read_events_total")
                .increment(by: Int64(results.count))

            return results
        } catch {
            let elapsed = ContinuousClock.now - start
            Metrics.Timer(label: "songbird_event_store_read_duration_seconds", dimensions: dims)
                .recordNanoseconds(elapsed.nanoseconds)
            Counter(label: "songbird_event_store_read_errors_total", dimensions: dims).increment()
            throw error
        }
    }

    public func readCategories(
        _ categories: [String],
        from globalPosition: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        let readType = categories.isEmpty ? "all" : "categories"
        let dims: [(String, String)] = [("read_type", readType)]
        let start = ContinuousClock.now

        do {
            let results = try await inner.readCategories(
                categories, from: globalPosition, maxCount: maxCount
            )
            let elapsed = ContinuousClock.now - start

            Metrics.Timer(label: "songbird_event_store_read_duration_seconds", dimensions: dims)
                .recordNanoseconds(elapsed.nanoseconds)
            Counter(label: "songbird_event_store_read_events_total")
                .increment(by: Int64(results.count))

            return results
        } catch {
            let elapsed = ContinuousClock.now - start
            Metrics.Timer(label: "songbird_event_store_read_duration_seconds", dimensions: dims)
                .recordNanoseconds(elapsed.nanoseconds)
            Counter(label: "songbird_event_store_read_errors_total", dimensions: dims).increment()
            throw error
        }
    }

    public func readLastEvent(
        in stream: StreamName
    ) async throws -> RecordedEvent? {
        let dims: [(String, String)] = [("stream_category", stream.category), ("read_type", "lastEvent")]
        let start = ContinuousClock.now

        do {
            let result = try await inner.readLastEvent(in: stream)
            let elapsed = ContinuousClock.now - start

            Metrics.Timer(label: "songbird_event_store_read_duration_seconds", dimensions: dims)
                .recordNanoseconds(elapsed.nanoseconds)
            Counter(label: "songbird_event_store_read_events_total")
                .increment(by: result != nil ? 1 : 0)

            return result
        } catch {
            let elapsed = ContinuousClock.now - start
            Metrics.Timer(label: "songbird_event_store_read_duration_seconds", dimensions: dims)
                .recordNanoseconds(elapsed.nanoseconds)
            Counter(label: "songbird_event_store_read_errors_total", dimensions: dims).increment()
            throw error
        }
    }

    public func streamVersion(
        _ stream: StreamName
    ) async throws -> Int64 {
        let dims: [(String, String)] = [("stream_category", stream.category)]
        let start = ContinuousClock.now

        do {
            let version = try await inner.streamVersion(stream)
            let elapsed = ContinuousClock.now - start
            Metrics.Timer(label: "songbird_event_store_stream_version_duration_seconds", dimensions: dims)
                .recordNanoseconds(elapsed.nanoseconds)
            return version
        } catch {
            let elapsed = ContinuousClock.now - start
            Metrics.Timer(label: "songbird_event_store_stream_version_duration_seconds", dimensions: dims)
                .recordNanoseconds(elapsed.nanoseconds)
            Counter(label: "songbird_event_store_stream_version_errors_total", dimensions: dims).increment()
            throw error
        }
    }
}

// MARK: - Duration Extension

extension Duration {
    /// Convert to nanoseconds for swift-metrics Timer recording.
    var nanoseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }
}
