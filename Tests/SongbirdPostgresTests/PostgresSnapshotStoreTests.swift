import Foundation
import Testing

@testable import Songbird
@testable import SongbirdPostgres

private enum PGSnapAggregate: Aggregate {
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

extension AllPostgresTests { @Suite("PostgresSnapshotStore") struct SnapshotStoreTests {

    @Test func loadReturnsNilWhenNoSnapshot() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresSnapshotStore(client: client)
            let stream = StreamName(category: "snap", id: "1")
            let result: (state: PGSnapAggregate.State, version: Int64)? =
                try await store.load(for: stream)
            #expect(result == nil)
        }
    }

    @Test func saveAndLoad() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresSnapshotStore(client: client)
            let stream = StreamName(category: "snap", id: "1")
            let state = PGSnapAggregate.State(count: 42)
            try await store.save(state, version: 10, for: stream)
            let loaded: (state: PGSnapAggregate.State, version: Int64)? =
                try await store.load(for: stream)
            #expect(loaded?.state == state)
            #expect(loaded?.version == 10)
        }
    }

    @Test func saveOverwritesPreviousSnapshot() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresSnapshotStore(client: client)
            let stream = StreamName(category: "snap", id: "1")
            try await store.save(PGSnapAggregate.State(count: 1), version: 5, for: stream)
            try await store.save(PGSnapAggregate.State(count: 99), version: 50, for: stream)
            let loaded: (state: PGSnapAggregate.State, version: Int64)? =
                try await store.load(for: stream)
            #expect(loaded?.state == PGSnapAggregate.State(count: 99))
            #expect(loaded?.version == 50)
        }
    }

    @Test func differentStreamsAreIndependent() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresSnapshotStore(client: client)
            let stream1 = StreamName(category: "snap", id: "1")
            let stream2 = StreamName(category: "snap", id: "2")
            try await store.save(PGSnapAggregate.State(count: 10), version: 5, for: stream1)
            try await store.save(PGSnapAggregate.State(count: 20), version: 8, for: stream2)
            let loaded1: (state: PGSnapAggregate.State, version: Int64)? =
                try await store.load(for: stream1)
            let loaded2: (state: PGSnapAggregate.State, version: Int64)? =
                try await store.load(for: stream2)
            #expect(loaded1?.state.count == 10)
            #expect(loaded1?.version == 5)
            #expect(loaded2?.state.count == 20)
            #expect(loaded2?.version == 8)
        }
    }
}}
