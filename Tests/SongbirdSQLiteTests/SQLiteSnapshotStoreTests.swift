import Foundation
import Testing

@testable import Songbird
@testable import SongbirdSQLite

private enum SnapAggregate: Aggregate {
    struct State: Sendable, Equatable, Codable {
        var count: Int
    }

    enum Event: Songbird.Event {
        case incremented

        var eventType: String { "Incremented" }
    }

    enum Failure: Error { case none }

    static let category = "snap"
    static let initialState = State(count: 0)

    static func apply(_ state: State, _ event: Event) -> State {
        State(count: state.count + 1)
    }
}

@Suite("SQLiteSnapshotStore")
struct SQLiteSnapshotStoreTests {

    func makeStore() throws -> SQLiteSnapshotStore {
        try SQLiteSnapshotStore(path: ":memory:")
    }

    @Test func loadReturnsNilWhenNoSnapshot() async throws {
        let store = try makeStore()
        let stream = StreamName(category: "snap", id: "1")
        let result: (state: SnapAggregate.State, version: Int64)? =
            try await store.load(for: stream)
        #expect(result == nil)
    }

    @Test func saveAndLoad() async throws {
        let store = try makeStore()
        let stream = StreamName(category: "snap", id: "1")
        let state = SnapAggregate.State(count: 42)
        try await store.save(state, version: 10, for: stream)
        let loaded: (state: SnapAggregate.State, version: Int64)? =
            try await store.load(for: stream)
        #expect(loaded?.state == state)
        #expect(loaded?.version == 10)
    }

    @Test func saveOverwritesPreviousSnapshot() async throws {
        let store = try makeStore()
        let stream = StreamName(category: "snap", id: "1")
        try await store.save(SnapAggregate.State(count: 1), version: 5, for: stream)
        try await store.save(SnapAggregate.State(count: 99), version: 50, for: stream)
        let loaded: (state: SnapAggregate.State, version: Int64)? =
            try await store.load(for: stream)
        #expect(loaded?.state == SnapAggregate.State(count: 99))
        #expect(loaded?.version == 50)
    }

    // MARK: - Corrupted Row Error Paths

    #if DEBUG
    @Test func corruptedRowWithNullState() async throws {
        let store = try makeStore()
        let stream = StreamName(category: "snap", id: "corrupt")

        // Recreate the snapshots table without NOT NULL constraints so we
        // can insert a row with a NULL state blob.
        try await store.rawExecute("""
            DROP TABLE snapshots;
            CREATE TABLE snapshots (
                stream_name TEXT PRIMARY KEY,
                state       BLOB,
                version     INTEGER,
                updated_at  TEXT
            );
            INSERT INTO snapshots (stream_name, state, version, updated_at)
            VALUES ('snap-corrupt', NULL, 5, '2026-01-01T00:00:00Z');
        """)

        await #expect(throws: SQLiteSnapshotStoreError.corruptedRow(column: "state", streamName: "snap-corrupt")) {
            _ = try await store.loadData(for: stream)
        }
    }

    @Test func corruptedRowWithNullVersion() async throws {
        let store = try makeStore()
        let stream = StreamName(category: "snap", id: "corrupt")

        try await store.rawExecute("""
            DROP TABLE snapshots;
            CREATE TABLE snapshots (
                stream_name TEXT PRIMARY KEY,
                state       BLOB,
                version     INTEGER,
                updated_at  TEXT
            );
            INSERT INTO snapshots (stream_name, state, version, updated_at)
            VALUES ('snap-corrupt', X'01020304', NULL, '2026-01-01T00:00:00Z');
        """)

        await #expect(throws: SQLiteSnapshotStoreError.corruptedRow(column: "version", streamName: "snap-corrupt")) {
            _ = try await store.loadData(for: stream)
        }
    }
    #endif

    @Test func differentStreamsAreIndependent() async throws {
        let store = try makeStore()
        let stream1 = StreamName(category: "snap", id: "1")
        let stream2 = StreamName(category: "snap", id: "2")
        try await store.save(SnapAggregate.State(count: 10), version: 5, for: stream1)
        try await store.save(SnapAggregate.State(count: 20), version: 8, for: stream2)
        let loaded1: (state: SnapAggregate.State, version: Int64)? =
            try await store.load(for: stream1)
        let loaded2: (state: SnapAggregate.State, version: Int64)? =
            try await store.load(for: stream2)
        #expect(loaded1?.state.count == 10)
        #expect(loaded1?.version == 5)
        #expect(loaded2?.state.count == 20)
        #expect(loaded2?.version == 8)
    }
}
