import Foundation
import Testing

@testable import Songbird
@testable import SongbirdSQLite

@Suite("SQLitePositionStore")
struct SQLitePositionStoreTests {

    func makeStore() throws -> SQLitePositionStore {
        try SQLitePositionStore(path: ":memory:")
    }

    @Test func loadReturnsNilForUnknownSubscriber() async throws {
        let store = try makeStore()
        let position = try await store.load(subscriberId: "unknown")
        #expect(position == nil)
    }

    @Test func saveAndLoad() async throws {
        let store = try makeStore()
        try await store.save(subscriberId: "projector-1", globalPosition: 42)
        let position = try await store.load(subscriberId: "projector-1")
        #expect(position == 42)
    }

    @Test func saveOverwritesPrevious() async throws {
        let store = try makeStore()
        try await store.save(subscriberId: "projector-1", globalPosition: 10)
        try await store.save(subscriberId: "projector-1", globalPosition: 25)
        let position = try await store.load(subscriberId: "projector-1")
        #expect(position == 25)
    }

    @Test func subscribersAreIsolated() async throws {
        let store = try makeStore()
        try await store.save(subscriberId: "sub-a", globalPosition: 5)
        try await store.save(subscriberId: "sub-b", globalPosition: 99)
        let posA = try await store.load(subscriberId: "sub-a")
        let posB = try await store.load(subscriberId: "sub-b")
        #expect(posA == 5)
        #expect(posB == 99)
    }

    @Test func persistsSQLitePosition() async throws {
        let store = try makeStore()
        try await store.save(subscriberId: "sub-1", globalPosition: 7)

        // Verify via a second load round-trip
        let position = try await store.load(subscriberId: "sub-1")
        #expect(position == 7)

        // Save again to exercise the ON CONFLICT UPDATE path
        try await store.save(subscriberId: "sub-1", globalPosition: 14)
        let updated = try await store.load(subscriberId: "sub-1")
        #expect(updated == 14)
    }
}
