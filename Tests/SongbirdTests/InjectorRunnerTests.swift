import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

// MARK: - Test Event Types

private struct InjectorRunnerTestEvent: Event {
    var eventType: String { "InjectorRunnerTestEvent" }
    let value: Int
}

// MARK: - Test Error

private struct InjectorTestError: Error, Equatable {}

// MARK: - Continuation-Based Test Injector

/// A controllable injector backed by an `AsyncThrowingStream` continuation.
/// Events are pushed imperatively via `yield()` and the stream is closed via `finish()`.
private actor ControllableInjector: Injector {
    let injectorId = "controllable-injector"
    private(set) var appendResults: [Result<RecordedEvent, any Error>] = []

    private let _continuation: AsyncThrowingStream<InboundEvent, Error>.Continuation
    private let _stream: AsyncThrowingStream<InboundEvent, Error>

    init() {
        let (stream, continuation) = AsyncThrowingStream<InboundEvent, Error>.makeStream()
        _stream = stream
        _continuation = continuation
    }

    nonisolated func events() -> AsyncThrowingStream<InboundEvent, Error> {
        // Safe: _stream is a let constant set during init before isolation begins.
        _stream
    }

    nonisolated func yield(_ inbound: InboundEvent) {
        _continuation.yield(inbound)
    }

    nonisolated func finish() {
        _continuation.finish()
    }

    func didAppend(_ event: InboundEvent, result: Result<RecordedEvent, any Error>) {
        appendResults.append(result)
    }
}

// MARK: - Failing Event Store

private actor FailingEventStore: EventStore {
    let inner = InMemoryEventStore()
    var shouldFail = false

    func setFailure(_ value: Bool) {
        shouldFail = value
    }

    func append(
        _ event: some Event,
        to stream: StreamName,
        metadata: EventMetadata,
        expectedVersion: Int64?
    ) async throws -> RecordedEvent {
        if shouldFail { throw InjectorTestError() }
        return try await inner.append(event, to: stream, metadata: metadata, expectedVersion: expectedVersion)
    }

    func readStream(
        _ stream: StreamName,
        from position: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        try await inner.readStream(stream, from: position, maxCount: maxCount)
    }

    func readCategories(
        _ categories: [String],
        from globalPosition: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        try await inner.readCategories(categories, from: globalPosition, maxCount: maxCount)
    }

    func readLastEvent(in stream: StreamName) async throws -> RecordedEvent? {
        try await inner.readLastEvent(in: stream)
    }

    func streamVersion(_ stream: StreamName) async throws -> Int64 {
        try await inner.streamVersion(stream)
    }
}

// MARK: - Tests

@Suite("InjectorRunner")
struct InjectorRunnerTests {

    let stream = StreamName(category: "injectorTest", id: "1")

    // MARK: - Basic Delivery

    @Test func appendsEventToStore() async throws {
        let injector = ControllableInjector()
        let store = InMemoryEventStore()
        let runner = InjectorRunner(injector: injector, store: store)

        let task = Task { try await runner.run() }

        injector.yield(InboundEvent(
            event: InjectorRunnerTestEvent(value: 42),
            stream: stream,
            metadata: EventMetadata()
        ))
        injector.finish()

        try await task.value

        let events = try await store.readStream(stream, from: 0, maxCount: 100)
        #expect(events.count == 1)
        #expect(events[0].eventType == "InjectorRunnerTestEvent")
    }

    @Test func callsDidAppendWithSuccessOnGoodAppend() async throws {
        let injector = ControllableInjector()
        let store = InMemoryEventStore()
        let runner = InjectorRunner(injector: injector, store: store)

        let task = Task { try await runner.run() }

        injector.yield(InboundEvent(
            event: InjectorRunnerTestEvent(value: 1),
            stream: stream,
            metadata: EventMetadata()
        ))
        injector.finish()

        try await task.value

        let results = await injector.appendResults
        #expect(results.count == 1)
        if case .success = results[0] {} else {
            Issue.record("Expected .success but got \(results[0])")
        }
    }

    @Test func appendsMultipleEventsInOrder() async throws {
        let injector = ControllableInjector()
        let store = InMemoryEventStore()
        let runner = InjectorRunner(injector: injector, store: store)

        let task = Task { try await runner.run() }

        for value in 1...3 {
            injector.yield(InboundEvent(
                event: InjectorRunnerTestEvent(value: value),
                stream: stream,
                metadata: EventMetadata()
            ))
        }
        injector.finish()

        try await task.value

        let events = try await store.readStream(stream, from: 0, maxCount: 100)
        #expect(events.count == 3)

        let results = await injector.appendResults
        #expect(results.count == 3)
        for result in results {
            if case .success = result {} else {
                Issue.record("Expected all results to be .success")
            }
        }
    }

    @Test func returnsWhenSequenceFinishes() async throws {
        let injector = ControllableInjector()
        let store = InMemoryEventStore()
        let runner = InjectorRunner(injector: injector, store: store)

        let task = Task { try await runner.run() }

        // Finish without yielding anything
        injector.finish()

        // Should complete without hanging
        try await task.value

        let events = try await store.readAll(from: 0, maxCount: 100)
        #expect(events.isEmpty)
    }

    // MARK: - Error Handling

    @Test func didAppendReceivesFailureOnStoreError() async throws {
        let injector = ControllableInjector()
        let store = FailingEventStore()
        let runner = InjectorRunner(injector: injector, store: store)

        let task = Task { try await runner.run() }

        // First event: store will fail
        await store.setFailure(true)
        injector.yield(InboundEvent(
            event: InjectorRunnerTestEvent(value: 1),
            stream: stream,
            metadata: EventMetadata()
        ))

        // Allow the first event to be processed before changing the failure state.
        // We finish the stream after a brief pause to ensure ordering.
        try await Task.sleep(for: .milliseconds(50))

        // Second event: store will succeed
        await store.setFailure(false)
        injector.yield(InboundEvent(
            event: InjectorRunnerTestEvent(value: 2),
            stream: stream,
            metadata: EventMetadata()
        ))
        injector.finish()

        try await task.value

        let results = await injector.appendResults
        #expect(results.count == 2)

        // First result should be a failure
        if case .failure(let error) = results[0] {
            #expect(error is InjectorTestError)
        } else {
            Issue.record("Expected first result to be .failure(InjectorTestError)")
        }

        // Second result should be a success
        if case .success = results[1] {} else {
            Issue.record("Expected second result to be .success")
        }
    }

    @Test func runnerContinuesAfterStoreError() async throws {
        let injector = ControllableInjector()
        let store = FailingEventStore()
        let runner = InjectorRunner(injector: injector, store: store)

        let task = Task { try await runner.run() }

        // First event: store will fail — should NOT be persisted
        await store.setFailure(true)
        injector.yield(InboundEvent(
            event: InjectorRunnerTestEvent(value: 1),
            stream: stream,
            metadata: EventMetadata()
        ))

        try await Task.sleep(for: .milliseconds(50))

        // Second event: store succeeds — should be persisted
        await store.setFailure(false)
        injector.yield(InboundEvent(
            event: InjectorRunnerTestEvent(value: 2),
            stream: stream,
            metadata: EventMetadata()
        ))
        injector.finish()

        try await task.value

        // Only the second event should be in the store
        let events = try await store.inner.readStream(stream, from: 0, maxCount: 100)
        #expect(events.count == 1)
        #expect(events[0].eventType == "InjectorRunnerTestEvent")
    }

    // MARK: - Cancellation

    @Test func cancellationStopsTheRunner() async throws {
        let injector = ControllableInjector()
        let store = InMemoryEventStore()
        let runner = InjectorRunner(injector: injector, store: store)

        // Start the runner — the stream is open, so it would run indefinitely
        let task = Task { try await runner.run() }

        // Allow the runner to start
        try await Task.sleep(for: .milliseconds(50))

        task.cancel()

        // The task should finish cleanly (success or CancellationError)
        let result = await task.result
        switch result {
        case .success:
            break
        case .failure(let error):
            #expect(error is CancellationError)
        }
    }
}
