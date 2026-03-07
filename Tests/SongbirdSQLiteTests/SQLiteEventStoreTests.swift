import Foundation
import Testing

@testable import Songbird
@testable import SongbirdSQLite

enum AccountEvent: Event {
    case credited(amount: Int)
    case debited(amount: Int, note: String)

    var eventType: String {
        switch self {
        case .credited: "Credited"
        case .debited: "Debited"
        }
    }
}

@Suite("SQLiteEventStore")
struct SQLiteEventStoreTests {
    func makeStore() throws -> SQLiteEventStore {
        try SQLiteEventStore(path: ":memory:")
    }

    let stream = StreamName(category: "account", id: "abc")

    // MARK: - Append

    @Test func appendReturnsRecordedEvent() async throws {
        let store = try makeStore()
        let recorded = try await store.append(
            AccountEvent.credited(amount: 100),
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

    @Test func appendIncrementsPositions() async throws {
        let store = try makeStore()
        let r1 = try await store.append(AccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        let r2 = try await store.append(AccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        #expect(r1.position == 0)
        #expect(r1.globalPosition == 0)
        #expect(r2.position == 1)
        #expect(r2.globalPosition == 1)
    }

    @Test func appendToMultipleStreams() async throws {
        let store = try makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "account", id: "b")
        let r1 = try await store.append(AccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        let r2 = try await store.append(AccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
        #expect(r1.position == 0)
        #expect(r2.position == 0)
        #expect(r1.globalPosition == 0)
        #expect(r2.globalPosition == 1)
    }

    @Test func appendedDataIsDecodable() async throws {
        let store = try makeStore()
        let recorded = try await store.append(AccountEvent.credited(amount: 42), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        let envelope = try recorded.decode(AccountEvent.self)
        #expect(envelope.event == .credited(amount: 42))
    }

    // MARK: - Optimistic Concurrency

    @Test func appendWithCorrectExpectedVersion() async throws {
        let store = try makeStore()
        _ = try await store.append(AccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        let r2 = try await store.append(AccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: 0)
        #expect(r2.position == 1)
    }

    @Test func appendWithWrongExpectedVersionThrows() async throws {
        let store = try makeStore()
        _ = try await store.append(AccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        await #expect(throws: VersionConflictError.self) {
            _ = try await store.append(AccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: 5)
        }
    }

    @Test func appendWithExpectedVersionOnEmptyStreamThrows() async throws {
        let store = try makeStore()
        await #expect(throws: VersionConflictError.self) {
            _ = try await store.append(AccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: 0)
        }
    }

    // MARK: - Read Stream

    @Test func readStreamDataIsDecodable() async throws {
        let store = try makeStore()
        let metadata = EventMetadata(traceId: "trace-1", causationId: "cause-1", correlationId: "corr-1", userId: "user-1")
        _ = try await store.append(AccountEvent.credited(amount: 42), to: stream, metadata: metadata, expectedVersion: nil)
        _ = try await store.append(AccountEvent.debited(amount: 10, note: "fee"), to: stream, metadata: EventMetadata(traceId: "trace-2"), expectedVersion: nil)

        let events = try await store.readStream(stream, from: 0, maxCount: 100)
        #expect(events.count == 2)

        // Decode the first event and verify data round-trips
        let envelope1 = try events[0].decode(AccountEvent.self)
        #expect(envelope1.event == .credited(amount: 42))
        #expect(envelope1.metadata.traceId == "trace-1")
        #expect(envelope1.metadata.causationId == "cause-1")
        #expect(envelope1.metadata.correlationId == "corr-1")
        #expect(envelope1.metadata.userId == "user-1")
        #expect(envelope1.streamName == stream)
        #expect(envelope1.position == 0)
        #expect(envelope1.globalPosition == 0)

        // Decode the second event
        let envelope2 = try events[1].decode(AccountEvent.self)
        #expect(envelope2.event == .debited(amount: 10, note: "fee"))
        #expect(envelope2.metadata.traceId == "trace-2")
        #expect(envelope2.position == 1)
    }

    @Test func readStreamReturnsEventsInOrder() async throws {
        let store = try makeStore()
        _ = try await store.append(AccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.debited(amount: 50, note: "ATM"), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readStream(stream, from: 0, maxCount: 100)
        #expect(events.count == 3)
        #expect(events[0].position == 0)
        #expect(events[1].position == 1)
        #expect(events[2].position == 2)
        #expect(events[0].eventType == "Credited")
        #expect(events[2].eventType == "Debited")
    }

    @Test func readStreamFromPosition() async throws {
        let store = try makeStore()
        _ = try await store.append(AccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 300), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readStream(stream, from: 1, maxCount: 100)
        #expect(events.count == 2)
        #expect(events[0].position == 1)
    }

    @Test func readStreamWithMaxCount() async throws {
        let store = try makeStore()
        for i in 0..<10 {
            _ = try await store.append(AccountEvent.credited(amount: i), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        }
        let events = try await store.readStream(stream, from: 0, maxCount: 3)
        #expect(events.count == 3)
    }

    @Test func readStreamReturnsEmptyForUnknownStream() async throws {
        let store = try makeStore()
        let events = try await store.readStream(StreamName(category: "nope", id: "x"), from: 0, maxCount: 100)
        #expect(events.isEmpty)
    }

    // MARK: - Read Category

    @Test func readCategoryAcrossStreams() async throws {
        let store = try makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "account", id: "b")
        let s3 = StreamName(category: "other", id: "c")
        _ = try await store.append(AccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 300), to: s3, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readCategory("account", from: 0, maxCount: 100)
        #expect(events.count == 2)
    }

    @Test func readCategoryFromGlobalPosition() async throws {
        let store = try makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "account", id: "b")
        _ = try await store.append(AccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readCategory("account", from: 1, maxCount: 100)
        #expect(events.count == 1)
        #expect(events[0].globalPosition == 1)
    }

    // MARK: - Read Last / Version

    @Test func readLastEvent() async throws {
        let store = try makeStore()
        _ = try await store.append(AccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let last = try await store.readLastEvent(in: stream)
        #expect(last != nil)
        #expect(last!.position == 1)
    }

    @Test func readLastEventReturnsNilForEmptyStream() async throws {
        let store = try makeStore()
        let last = try await store.readLastEvent(in: stream)
        #expect(last == nil)
    }

    @Test func streamVersionReturnsLatestPosition() async throws {
        let store = try makeStore()
        _ = try await store.append(AccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let version = try await store.streamVersion(stream)
        #expect(version == 1)
    }

    @Test func streamVersionReturnsNegativeOneForEmpty() async throws {
        let store = try makeStore()
        let version = try await store.streamVersion(stream)
        #expect(version == -1)
    }

    // MARK: - Hash Chain

    @Test func hashChainIsIntactAfterAppends() async throws {
        let store = try makeStore()
        _ = try await store.append(AccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.debited(amount: 50, note: "fee"), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let result = try await store.verifyChain()
        #expect(result.intact == true)
        #expect(result.eventsVerified == 3)
        #expect(result.brokenAtSequence == nil)
    }

    @Test func emptyStoreChainIsIntact() async throws {
        let store = try makeStore()
        let result = try await store.verifyChain()
        #expect(result.intact == true)
        #expect(result.eventsVerified == 0)
    }

    #if DEBUG
    @Test func tamperedEventBreaksChain() async throws {
        let store = try makeStore()
        _ = try await store.append(AccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 300), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        // Tamper with the second event's data
        try await store.rawExecute(
            "UPDATE events SET data = '{\"amount\":999}' WHERE global_position = 2"
        )

        let result = try await store.verifyChain()
        #expect(result.intact == false)
        #expect(result.eventsVerified == 1)
        #expect(result.brokenAtSequence == 1)
    }
    #endif

    // MARK: - Read Categories (Multi-Category)

    @Test func readCategoriesWithMultipleCategories() async throws {
        let store = try makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "invoice", id: "b")
        let s3 = StreamName(category: "order", id: "c")
        _ = try await store.append(AccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 300), to: s3, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readCategories(["account", "invoice"], from: 0, maxCount: 100)
        #expect(events.count == 2)
        #expect(events[0].streamName == s1)
        #expect(events[1].streamName == s2)
    }

    @Test func readAllReturnsAllCategories() async throws {
        let store = try makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "invoice", id: "b")
        let s3 = StreamName(category: "order", id: "c")
        _ = try await store.append(AccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 300), to: s3, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readAll(from: 0, maxCount: 100)
        #expect(events.count == 3)
    }

    @Test func readAllFromGlobalPosition() async throws {
        let store = try makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "invoice", id: "b")
        _ = try await store.append(AccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readAll(from: 1, maxCount: 100)
        #expect(events.count == 1)
        #expect(events[0].globalPosition == 1)
    }

    @Test func readCategoriesWithEmptyArrayReturnsAllEvents() async throws {
        let store = try makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "invoice", id: "b")
        _ = try await store.append(AccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readCategories([], from: 0, maxCount: 100)
        #expect(events.count == 2)
    }

    // MARK: - Cross-Connection Concurrency

    @Test func concurrentAppendFromSeparateConnectionsDetectsConflict() async throws {
        // Two stores sharing the same SQLite file simulate cross-process access
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("songbird-concurrent-test-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let store1 = try SQLiteEventStore(path: dbPath)
        let store2 = try SQLiteEventStore(path: dbPath)

        let stream = StreamName(category: "account", id: "abc")

        // First append from store1 should succeed
        _ = try await store1.append(
            AccountEvent.credited(amount: 100),
            to: stream,
            metadata: EventMetadata(),
            expectedVersion: -1
        )

        // Second append from store2 with expectedVersion: -1 should fail
        // because store1 already wrote position 0
        await #expect(throws: VersionConflictError.self) {
            try await store2.append(
                AccountEvent.credited(amount: 200),
                to: stream,
                metadata: EventMetadata(),
                expectedVersion: -1
            )
        }
    }

    @Test func verifyChainWithBatchSizeOne() async throws {
        let store = try makeStore()
        _ = try await store.append(AccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 300), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        let result = try await store.verifyChain(batchSize: 1)
        #expect(result.intact == true)
        #expect(result.eventsVerified == 3)
    }

    @Test func verifyChainWithBatchSizeTwo() async throws {
        let store = try makeStore()
        _ = try await store.append(AccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 300), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        // batchSize=2 means first batch has 2 events, second batch has 1
        let result = try await store.verifyChain(batchSize: 2)
        #expect(result.intact == true)
        #expect(result.eventsVerified == 3)
    }

    @Test func readCategoryConvenienceStillWorks() async throws {
        let store = try makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "other", id: "b")
        _ = try await store.append(AccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readCategory("account", from: 0, maxCount: 100)
        #expect(events.count == 1)
        #expect(events[0].streamName == s1)
    }

    // MARK: - Read Categories Max Count

    @Test func readCategoriesRespectsMaxCount() async throws {
        let store = try makeStore()
        let s1 = StreamName(category: "account", id: "a")
        let s2 = StreamName(category: "account", id: "b")
        let s3 = StreamName(category: "account", id: "c")
        _ = try await store.append(AccountEvent.credited(amount: 100), to: s1, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: s2, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 300), to: s3, metadata: EventMetadata(), expectedVersion: nil)

        let events = try await store.readCategories(["account"], from: 0, maxCount: 2)
        #expect(events.count == 2)
    }

    // MARK: - Corrupted Row Error Paths

    #if DEBUG
    @Test func corruptedRowWithNullEventType() async throws {
        let store = try makeStore()
        _ = try await store.append(
            AccountEvent.credited(amount: 100),
            to: stream,
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Recreate the events table without NOT NULL constraints so we can
        // insert a row with a NULL event_type to exercise the corruptedRow path.
        try await store.rawExecute("""
            CREATE TABLE events_tmp AS SELECT * FROM events;
            DROP TABLE events;
            CREATE TABLE events (
                global_position  INTEGER PRIMARY KEY AUTOINCREMENT,
                stream_name      TEXT,
                stream_category  TEXT,
                position         INTEGER,
                event_type       TEXT,
                data             TEXT,
                metadata         TEXT,
                event_id         TEXT,
                timestamp        TEXT,
                event_hash       TEXT
            );
            INSERT INTO events SELECT * FROM events_tmp;
            DROP TABLE events_tmp;
            UPDATE events SET event_type = NULL WHERE global_position = 1;
        """)

        await #expect(throws: SQLiteEventStoreError.corruptedRow(column: "event_type", globalPosition: 0)) {
            _ = try await store.readStream(stream, from: 0, maxCount: 100)
        }
    }

    @Test func corruptedRowWithNullData() async throws {
        let store = try makeStore()
        _ = try await store.append(
            AccountEvent.credited(amount: 100),
            to: stream,
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        try await store.rawExecute("""
            CREATE TABLE events_tmp AS SELECT * FROM events;
            DROP TABLE events;
            CREATE TABLE events (
                global_position  INTEGER PRIMARY KEY AUTOINCREMENT,
                stream_name      TEXT,
                stream_category  TEXT,
                position         INTEGER,
                event_type       TEXT,
                data             TEXT,
                metadata         TEXT,
                event_id         TEXT,
                timestamp        TEXT,
                event_hash       TEXT
            );
            INSERT INTO events SELECT * FROM events_tmp;
            DROP TABLE events_tmp;
            UPDATE events SET data = NULL WHERE global_position = 1;
        """)

        await #expect(throws: SQLiteEventStoreError.corruptedRow(column: "data", globalPosition: 0)) {
            _ = try await store.readStream(stream, from: 0, maxCount: 100)
        }
    }

    @Test func corruptedRowWithNullTimestamp() async throws {
        let store = try makeStore()
        _ = try await store.append(
            AccountEvent.credited(amount: 100),
            to: stream,
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        try await store.rawExecute("""
            CREATE TABLE events_tmp AS SELECT * FROM events;
            DROP TABLE events;
            CREATE TABLE events (
                global_position  INTEGER PRIMARY KEY AUTOINCREMENT,
                stream_name      TEXT,
                stream_category  TEXT,
                position         INTEGER,
                event_type       TEXT,
                data             TEXT,
                metadata         TEXT,
                event_id         TEXT,
                timestamp        TEXT,
                event_hash       TEXT
            );
            INSERT INTO events SELECT * FROM events_tmp;
            DROP TABLE events_tmp;
            UPDATE events SET timestamp = NULL WHERE global_position = 1;
        """)

        await #expect(throws: SQLiteEventStoreError.corruptedRow(column: "timestamp", globalPosition: 0)) {
            _ = try await store.readStream(stream, from: 0, maxCount: 100)
        }
    }

    @Test func corruptedRowWithInvalidTimestamp() async throws {
        let store = try makeStore()
        _ = try await store.append(
            AccountEvent.credited(amount: 100),
            to: stream,
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Set an invalid ISO 8601 string — the cast to String succeeds but
        // Date parsing fails, triggering the second timestamp corruptedRow path.
        try await store.rawExecute(
            "UPDATE events SET timestamp = 'not-a-date' WHERE global_position = 1"
        )

        await #expect(throws: SQLiteEventStoreError.corruptedRow(column: "timestamp", globalPosition: 0)) {
            _ = try await store.readStream(stream, from: 0, maxCount: 100)
        }
    }

    @Test func corruptedRowWithInvalidEventId() async throws {
        let store = try makeStore()
        _ = try await store.append(
            AccountEvent.credited(amount: 100),
            to: stream,
            metadata: EventMetadata(),
            expectedVersion: nil
        )

        // Set an invalid UUID string — the cast to String succeeds but
        // UUID parsing fails, triggering the second event_id corruptedRow path.
        try await store.rawExecute(
            "UPDATE events SET event_id = 'not-a-uuid' WHERE global_position = 1"
        )

        await #expect(throws: SQLiteEventStoreError.corruptedRow(column: "event_id", globalPosition: 0)) {
            _ = try await store.readStream(stream, from: 0, maxCount: 100)
        }
    }
    #endif

    // MARK: - Verify Chain with NULL Hashes

    #if DEBUG
    @Test func verifyChainWithNullHashesTreatsAsValid() async throws {
        let store = try makeStore()
        _ = try await store.append(AccountEvent.credited(amount: 100), to: stream, metadata: EventMetadata(), expectedVersion: nil)
        _ = try await store.append(AccountEvent.credited(amount: 200), to: stream, metadata: EventMetadata(), expectedVersion: nil)

        // Clear hashes to simulate pre-hash-chain events
        try await store.rawExecute("UPDATE events SET event_hash = NULL")

        let result = try await store.verifyChain()
        #expect(result.intact == true)
        #expect(result.eventsVerified == 2)
    }
    #endif
}
