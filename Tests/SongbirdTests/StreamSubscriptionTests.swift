import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

// Test event type for stream subscription tests
enum StreamTestEvent: Event {
    case updated(value: Int)

    var eventType: String {
        switch self {
        case .updated: "Updated"
        }
    }
}

/// Actor to safely collect events across task boundaries in tests.
private actor StreamEventCollector {
    private(set) var events: [RecordedEvent] = []

    func append(_ event: RecordedEvent) {
        events.append(event)
    }

    var count: Int { events.count }
}

@Suite("StreamSubscription")
struct StreamSubscriptionTests {

    let stream = StreamName(category: "widget", id: "42")

    func makeStore() -> InMemoryEventStore {
        let registry = EventTypeRegistry()
        registry.register(StreamTestEvent.self, eventTypes: ["Updated"])
        return InMemoryEventStore()
    }

    // MARK: - Basic Consumption

    @Test func consumesEventsFromStream() async throws {
        let store = makeStore()
        _ = try await store.append(StreamTestEvent.updated(value: 1), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(StreamTestEvent.updated(value: 2), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(StreamTestEvent.updated(value: 3), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let subscription = StreamSubscription(
            stream: stream,
            store: store,
            tickInterval: .milliseconds(10)
        )

        let collector = StreamEventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                if await collector.count == 3 { break }
            }
        }

        try await task.value
        let received = await collector.events
        #expect(received.count == 3)
        #expect(received[0].position == 0)
        #expect(received[1].position == 1)
        #expect(received[2].position == 2)
    }

    // MARK: - Start Position

    @Test func startsFromSpecifiedPosition() async throws {
        let store = makeStore()
        _ = try await store.append(StreamTestEvent.updated(value: 1), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(StreamTestEvent.updated(value: 2), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(StreamTestEvent.updated(value: 3), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let subscription = StreamSubscription(
            stream: stream,
            store: store,
            startPosition: 2,
            tickInterval: .milliseconds(10)
        )

        let collector = StreamEventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                if await collector.count == 1 { break }
            }
        }

        try await task.value
        let received = await collector.events
        #expect(received.count == 1)
        #expect(received[0].position == 2)
    }

    // MARK: - Stream Isolation

    @Test func onlyReadsFromTargetStream() async throws {
        let store = makeStore()
        let otherStream = StreamName(category: "widget", id: "99")
        _ = try await store.append(StreamTestEvent.updated(value: 1), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(StreamTestEvent.updated(value: 2), to: otherStream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(StreamTestEvent.updated(value: 3), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let subscription = StreamSubscription(
            stream: stream,
            store: store,
            tickInterval: .milliseconds(10)
        )

        let collector = StreamEventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                if await collector.count == 2 { break }
            }
        }

        try await task.value
        let received = await collector.events
        #expect(received.count == 2)
        #expect(received[0].streamName == stream)
        #expect(received[1].streamName == stream)
    }

    // MARK: - Polling for New Events

    @Test func pollsForNewEvents() async throws {
        let store = makeStore()

        let subscription = StreamSubscription(
            stream: stream,
            store: store,
            tickInterval: .milliseconds(10)
        )

        let collector = StreamEventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                if await collector.count == 2 { break }
            }
        }

        // Give the subscription time to start polling on an empty stream
        try await Task.sleep(for: .milliseconds(30))
        let earlyCount = await collector.count
        #expect(earlyCount == 0)

        // Append events -- the subscription should pick them up
        _ = try await store.append(StreamTestEvent.updated(value: 1), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(StreamTestEvent.updated(value: 2), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        try await task.value
        let finalCount = await collector.count
        #expect(finalCount == 2)
    }

    // MARK: - Cancellation

    @Test func stopsOnTaskCancellation() async throws {
        let store = makeStore()
        _ = try await store.append(StreamTestEvent.updated(value: 1), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let subscription = StreamSubscription(
            stream: stream,
            store: store,
            tickInterval: .milliseconds(10)
        )

        let collector = StreamEventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                // Don't break -- let it poll forever
            }
        }

        // Let the subscription process existing events
        try await Task.sleep(for: .milliseconds(50))

        // Cancel the task
        task.cancel()

        // The task should finish without hanging.
        let result = await task.result
        switch result {
        case .success:
            break
        case .failure(let error):
            #expect(error is CancellationError)
        }
        let count = await collector.count
        #expect(count == 1)
    }

    // MARK: - Batch Size

    @Test func batchSizeOneDeliversAllEvents() async throws {
        let store = makeStore()
        _ = try await store.append(StreamTestEvent.updated(value: 10), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(StreamTestEvent.updated(value: 20), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(StreamTestEvent.updated(value: 30), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let subscription = StreamSubscription(
            stream: stream,
            store: store,
            batchSize: 1,
            tickInterval: .milliseconds(10)
        )

        let collector = StreamEventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                if await collector.count == 3 { break }
            }
        }

        try await task.value
        let received = await collector.events
        #expect(received.count == 3)
        #expect(received[0].position == 0)
        #expect(received[1].position == 1)
        #expect(received[2].position == 2)

        // Verify the decoded data matches what was appended
        let e1 = try received[0].decode(StreamTestEvent.self)
        let e2 = try received[1].decode(StreamTestEvent.self)
        let e3 = try received[2].decode(StreamTestEvent.self)
        #expect(e1.event == .updated(value: 10))
        #expect(e2.event == .updated(value: 20))
        #expect(e3.event == .updated(value: 30))
    }

    @Test func respectsBatchSize() async throws {
        let store = makeStore()
        for i in 0..<10 {
            _ = try await store.append(StreamTestEvent.updated(value: i), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        }

        let subscription = StreamSubscription(
            stream: stream,
            store: store,
            batchSize: 3,
            tickInterval: .milliseconds(10)
        )

        let collector = StreamEventCollector()
        let task = Task {
            for try await event in subscription {
                await collector.append(event)
                if await collector.count == 10 { break }
            }
        }

        try await task.value
        let received = await collector.events
        #expect(received.count == 10)
        // Events should be in order regardless of batch boundaries
        for i in 0..<10 {
            #expect(received[i].position == Int64(i))
        }
    }
}
