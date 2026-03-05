import Foundation
import Testing

@testable import Songbird
@testable import SongbirdPostgres

extension AllPostgresTests { @Suite("PostgresPositionStore") struct PositionStoreTests {

    @Test func loadReturnsNilForUnknownSubscriber() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresPositionStore(client: client)
            let position = try await store.load(subscriberId: "unknown")
            #expect(position == nil)
        }
    }

    @Test func saveAndLoad() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresPositionStore(client: client)
            try await store.save(subscriberId: "projector-1", globalPosition: 42)
            let position = try await store.load(subscriberId: "projector-1")
            #expect(position == 42)
        }
    }

    @Test func saveOverwritesPrevious() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresPositionStore(client: client)
            try await store.save(subscriberId: "projector-1", globalPosition: 10)
            try await store.save(subscriberId: "projector-1", globalPosition: 25)
            let position = try await store.load(subscriberId: "projector-1")
            #expect(position == 25)
        }
    }

    @Test func subscribersAreIsolated() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresPositionStore(client: client)
            try await store.save(subscriberId: "sub-a", globalPosition: 5)
            try await store.save(subscriberId: "sub-b", globalPosition: 99)
            let posA = try await store.load(subscriberId: "sub-a")
            let posB = try await store.load(subscriberId: "sub-b")
            #expect(posA == 5)
            #expect(posB == 99)
        }
    }

    @Test func persistsPosition() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresPositionStore(client: client)
            try await store.save(subscriberId: "sub-1", globalPosition: 7)

            let position = try await store.load(subscriberId: "sub-1")
            #expect(position == 7)

            // Save again to exercise the ON CONFLICT UPDATE path
            try await store.save(subscriberId: "sub-1", globalPosition: 14)
            let updated = try await store.load(subscriberId: "sub-1")
            #expect(updated == 14)
        }
    }
}}
