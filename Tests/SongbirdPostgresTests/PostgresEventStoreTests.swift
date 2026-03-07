import Foundation
import Testing

@testable import Songbird
@testable import SongbirdPostgres
@testable import SongbirdTesting

enum PGAccountEvent: Event {
    case credited(amount: Int)
    case debited(amount: Int, note: String)

    var eventType: String {
        switch self {
        case .credited: "Credited"
        case .debited: "Debited"
        }
    }
}

extension AllPostgresTests { @Suite("PostgresEventStore") struct EventStoreTests {
    let stream = StreamName(category: "account", id: "abc")

    // MARK: - Append

    @Test func appendReturnsRecordedEvent() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client)
            let recorded = try await store.append(
                PGAccountEvent.credited(amount: 100),
                to: stream,
                metadata: EventMetadata(traceId: "t1"),
                expectedVersion: nil
            )
            #expect(recorded.streamName == stream)
            #expect(recorded.position == 0)
            #expect(recorded.globalPosition == 0)
            #expect(recorded.eventType == "Credited")
            #expect(recorded.metadata.traceId == "t1")
        }
    }

    @Test func appendIncrementsPositions() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client)
            let r1 = try await store.append(PGAccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            let r2 = try await store.append(PGAccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            #expect(r1.position == 0)
            #expect(r1.globalPosition == 0)
            #expect(r2.position == 1)
            #expect(r2.globalPosition == 1)
        }
    }

    @Test func appendToMultipleStreams() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client)
            let s1 = StreamName(category: "account", id: "a")
            let s2 = StreamName(category: "account", id: "b")
            let r1 = try await store.append(PGAccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
            let r2 = try await store.append(PGAccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
            #expect(r1.position == 0)
            #expect(r2.position == 0)
            #expect(r1.globalPosition == 0)
            #expect(r2.globalPosition == 1)
        }
    }

    @Test func appendedDataIsDecodable() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client)
            let recorded = try await store.append(PGAccountEvent.credited(amount: 42), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            let envelope = try recorded.decode(PGAccountEvent.self)
            #expect(envelope.event == .credited(amount: 42))
        }
    }

    // MARK: - Optimistic Concurrency

    @Test func appendWithCorrectExpectedVersion() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client)
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            let r2 = try await store.append(PGAccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: 0)
            #expect(r2.position == 1)
        }
    }

    @Test func appendWithWrongExpectedVersionThrows() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client)
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)

            await #expect(throws: VersionConflictError.self) {
                _ = try await store.append(PGAccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: 5)
            }
        }
    }

    @Test func appendWithExpectedVersionOnEmptyStreamThrows() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client)
            await #expect(throws: VersionConflictError.self) {
                _ = try await store.append(PGAccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: 0)
            }
        }
    }

    @Test func concurrentAppendsProduceVersionConflict() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client)
            let stream = StreamName(category: "account", id: "conflict-test")

            // Seed with one event
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)

            // Append with a wrong expected version — must throw VersionConflictError
            do {
                _ = try await store.append(
                    PGAccountEvent.credited(amount: 200),
                    to: stream, metadata: EventMetadata(), expectedVersion: 99
                )
                Issue.record("Expected VersionConflictError")
            } catch is VersionConflictError {
                // Expected
            }
        }
    }

    // MARK: - Read Stream

    @Test func readStreamDataIsDecodable() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client)
            let metadata = EventMetadata(traceId: "trace-1", causationId: "cause-1", correlationId: "corr-1", userId: "user-1")
            _ = try await store.append(PGAccountEvent.credited(amount: 42), to: stream, metadata: metadata, expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.debited(amount: 10, note: "fee"), to: stream, metadata: EventMetadata(traceId: "trace-2"), expectedVersion: nil)

            let events = try await store.readStream(stream, from: 0, maxCount: 100)
            #expect(events.count == 2)

            // Decode the first event and verify data round-trips
            let envelope1 = try events[0].decode(PGAccountEvent.self)
            #expect(envelope1.event == .credited(amount: 42))
            #expect(envelope1.metadata.traceId == "trace-1")
            #expect(envelope1.metadata.causationId == "cause-1")
            #expect(envelope1.metadata.correlationId == "corr-1")
            #expect(envelope1.metadata.userId == "user-1")
            #expect(envelope1.streamName == stream)
            #expect(envelope1.position == 0)
            #expect(envelope1.globalPosition == 0)

            // Decode the second event
            let envelope2 = try events[1].decode(PGAccountEvent.self)
            #expect(envelope2.event == .debited(amount: 10, note: "fee"))
            #expect(envelope2.metadata.traceId == "trace-2")
            #expect(envelope2.position == 1)
        }
    }

    @Test func readStreamReturnsEventsInOrder() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client)
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.debited(amount: 50, note: "ATM"), to: stream, metadata: EventMetadata(), expectedVersion: nil)

            let events = try await store.readStream(stream, from: 0, maxCount: 100)
            #expect(events.count == 3)
            #expect(events[0].position == 0)
            #expect(events[1].position == 1)
            #expect(events[2].position == 2)
            #expect(events[0].eventType == "Credited")
            #expect(events[2].eventType == "Debited")
        }
    }

    @Test func readStreamFromPosition() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client)
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 300), to: stream, metadata: EventMetadata(), expectedVersion: nil)

            let events = try await store.readStream(stream, from: 1, maxCount: 100)
            #expect(events.count == 2)
            #expect(events[0].position == 1)
        }
    }

    @Test func readStreamWithMaxCount() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client)
            for i in 0..<10 {
                _ = try await store.append(PGAccountEvent.credited(amount: i), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            }
            let events = try await store.readStream(stream, from: 0, maxCount: 3)
            #expect(events.count == 3)
        }
    }

    @Test func readStreamReturnsEmptyForUnknownStream() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client)
            let events = try await store.readStream(StreamName(category: "nope", id: "x"), from: 0, maxCount: 100)
            #expect(events.isEmpty)
        }
    }

    // MARK: - Read Category

    @Test func readCategoryAcrossStreams() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client)
            let s1 = StreamName(category: "account", id: "a")
            let s2 = StreamName(category: "account", id: "b")
            let s3 = StreamName(category: "other", id: "c")
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 300), to: s3, metadata: EventMetadata(), expectedVersion: nil)

            let events = try await store.readCategory("account", from: 0, maxCount: 100)
            #expect(events.count == 2)
        }
    }

    @Test func readCategoryFromGlobalPosition() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client)
            let s1 = StreamName(category: "account", id: "a")
            let s2 = StreamName(category: "account", id: "b")
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)

            let events = try await store.readCategory("account", from: 1, maxCount: 100)
            #expect(events.count == 1)
            #expect(events[0].globalPosition == 1)
        }
    }

    // MARK: - Read Last / Version

    @Test func readLastEvent() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client)
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)

            let last = try await store.readLastEvent(in: stream)
            #expect(last != nil)
            #expect(last!.position == 1)
        }
    }

    @Test func readLastEventReturnsNilForEmptyStream() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client)
            let last = try await store.readLastEvent(in: stream)
            #expect(last == nil)
        }
    }

    @Test func streamVersionReturnsLatestPosition() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client)
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)

            let version = try await store.streamVersion(stream)
            #expect(version == 1)
        }
    }

    @Test func streamVersionReturnsNegativeOneForEmpty() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client)
            let version = try await store.streamVersion(stream)
            #expect(version == -1)
        }
    }

    // MARK: - Multi-Category Reads

    @Test func readCategoriesWithMultipleCategories() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client)
            let s1 = StreamName(category: "account", id: "a")
            let s2 = StreamName(category: "invoice", id: "b")
            let s3 = StreamName(category: "order", id: "c")
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 300), to: s3, metadata: EventMetadata(), expectedVersion: nil)

            let events = try await store.readCategories(["account", "invoice"], from: 0, maxCount: 100)
            #expect(events.count == 2)
            #expect(events[0].streamName == s1)
            #expect(events[1].streamName == s2)
        }
    }

    @Test func readAllReturnsAllCategories() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client)
            let s1 = StreamName(category: "account", id: "a")
            let s2 = StreamName(category: "invoice", id: "b")
            let s3 = StreamName(category: "order", id: "c")
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 300), to: s3, metadata: EventMetadata(), expectedVersion: nil)

            let events = try await store.readAll(from: 0, maxCount: 100)
            #expect(events.count == 3)
        }
    }

    @Test func readAllFromGlobalPosition() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client)
            let s1 = StreamName(category: "account", id: "a")
            let s2 = StreamName(category: "invoice", id: "b")
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)

            let events = try await store.readAll(from: 1, maxCount: 100)
            #expect(events.count == 1)
            #expect(events[0].globalPosition == 1)
        }
    }

    @Test func readCategoriesWithEmptyArrayReturnsAllEvents() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client)
            let s1 = StreamName(category: "account", id: "a")
            let s2 = StreamName(category: "invoice", id: "b")
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)

            let events = try await store.readCategories([], from: 0, maxCount: 100)
            #expect(events.count == 2)
        }
    }

    @Test func readCategoryConvenienceStillWorks() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresEventStore(client: client)
            let s1 = StreamName(category: "account", id: "a")
            let s2 = StreamName(category: "other", id: "b")
            _ = try await store.append(PGAccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
            _ = try await store.append(PGAccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)

            let events = try await store.readCategory("account", from: 0, maxCount: 100)
            #expect(events.count == 1)
            #expect(events[0].streamName == s1)
        }
    }
}}
