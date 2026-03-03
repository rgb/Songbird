import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

struct Deposited: Event {
    static let eventType = "Deposited"
    let amount: Int
}

struct Withdrawn: Event {
    static let eventType = "Withdrawn"
    let amount: Int
    let reason: String
}

@Suite("InMemoryEventStore")
struct InMemoryEventStoreTests {
    func makeStore() -> InMemoryEventStore {
        let registry = EventTypeRegistry()
        registry.register(Deposited.self)
        registry.register(Withdrawn.self)
        return InMemoryEventStore(registry: registry)
    }

    let stream = StreamName(category: "account", id: "123")

    // MARK: - Append

    @Test func appendReturnsRecordedEvent() async throws {
        let store = makeStore()
        let recorded = try await store.append(
            Deposited(amount: 100),
            to: stream,
            metadata: EventMetadata(traceId: "t1"),
            expectedVersion: nil
        )
        #expect(recorded.streamName == stream)
        #expect(recorded.position == 0)
        #expect(recorded.globalPosition == 0)
        #expect(recorded.eventType == "Deposited")
        #expect(recorded.metadata.traceId == "t1")
    }

    @Test func appendIncrementsPositions() async throws {
        let store = makeStore()
        let r1 = try await store.append(Deposited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        let r2 = try await store.append(Deposited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        #expect(r1.position == 0)
        #expect(r1.globalPosition == 0)
        #expect(r2.position == 1)
        #expect(r2.globalPosition == 1)
    }

    @Test func appendToMultipleStreams() async throws {
        let store = makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "account", id: "b")
        let r1 = try await store.append(Deposited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        let r2 = try await store.append(Deposited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
        #expect(r1.position == 0)
        #expect(r2.position == 0)
        #expect(r1.globalPosition == 0)
        #expect(r2.globalPosition == 1)
    }

    @Test func appendedDataIsDecodable() async throws {
        let store = makeStore()
        let recorded = try await store.append(Deposited(amount: 42), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        let envelope = try recorded.decode(Deposited.self)
        #expect(envelope.event.amount == 42)
    }

    // MARK: - Optimistic Concurrency

    @Test func appendWithCorrectExpectedVersion() async throws {
        let store = makeStore()
        _ = try await store.append(Deposited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        let r2 = try await store.append(Deposited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: 0)
        #expect(r2.position == 1)
    }

    @Test func appendWithWrongExpectedVersionThrows() async throws {
        let store = makeStore()
        _ = try await store.append(Deposited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        await #expect(throws: VersionConflictError.self) {
            _ = try await store.append(Deposited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: 5)
        }
    }

    @Test func appendWithExpectedVersionOnEmptyStreamThrows() async throws {
        let store = makeStore()
        await #expect(throws: VersionConflictError.self) {
            _ = try await store.append(Deposited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: 0)
        }
    }

    // MARK: - Read Stream

    @Test func readStreamReturnsEventsInOrder() async throws {
        let store = makeStore()
        _ = try await store.append(Deposited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Deposited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Withdrawn(amount: 50, reason: "ATM"), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readStream(stream, from: 0, maxCount: 100)
        #expect(events.count == 3)
        #expect(events[0].position == 0)
        #expect(events[1].position == 1)
        #expect(events[2].position == 2)
        #expect(events[0].eventType == "Deposited")
        #expect(events[2].eventType == "Withdrawn")
    }

    @Test func readStreamFromPosition() async throws {
        let store = makeStore()
        _ = try await store.append(Deposited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Deposited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Deposited(amount: 300), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readStream(stream, from: 1, maxCount: 100)
        #expect(events.count == 2)
        #expect(events[0].position == 1)
    }

    @Test func readStreamWithMaxCount() async throws {
        let store = makeStore()
        for i in 0..<10 {
            _ = try await store.append(Deposited(amount: i), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        }
        let events = try await store.readStream(stream, from: 0, maxCount: 3)
        #expect(events.count == 3)
    }

    @Test func readStreamReturnsEmptyForUnknownStream() async throws {
        let store = makeStore()
        let events = try await store.readStream(StreamName(category: "nope", id: "x"), from: 0, maxCount: 100)
        #expect(events.isEmpty)
    }

    // MARK: - Read Category

    @Test func readCategoryAcrossStreams() async throws {
        let store = makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "account", id: "b")
        let s3 = StreamName(category: "other", id: "c")
        _ = try await store.append(Deposited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Deposited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Deposited(amount: 300), to: s3, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readCategory("account", from: 0, maxCount: 100)
        #expect(events.count == 2)
        #expect(events[0].streamName == s1)
        #expect(events[1].streamName == s2)
    }

    @Test func readCategoryFromGlobalPosition() async throws {
        let store = makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "account", id: "b")
        _ = try await store.append(Deposited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Deposited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readCategory("account", from: 1, maxCount: 100)
        #expect(events.count == 1)
        #expect(events[0].globalPosition == 1)
    }

    // MARK: - Read Last Event

    @Test func readLastEvent() async throws {
        let store = makeStore()
        _ = try await store.append(Deposited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Deposited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let last = try await store.readLastEvent(in: stream)
        #expect(last != nil)
        #expect(last!.position == 1)
    }

    @Test func readLastEventReturnsNilForEmptyStream() async throws {
        let store = makeStore()
        let last = try await store.readLastEvent(in: stream)
        #expect(last == nil)
    }

    // MARK: - Stream Version

    @Test func streamVersionReturnsLatestPosition() async throws {
        let store = makeStore()
        _ = try await store.append(Deposited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(Deposited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let version = try await store.streamVersion(stream)
        #expect(version == 1)
    }

    @Test func streamVersionReturnsNegativeOneForEmpty() async throws {
        let store = makeStore()
        let version = try await store.streamVersion(stream)
        #expect(version == -1)
    }
}
