import Testing

@testable import SongbirdTesting

@Suite("InMemoryPositionStore")
struct InMemoryPositionStoreTests {
    @Test func loadReturnsNilForUnknownSubscriber() async throws {
        let store = InMemoryPositionStore()
        let position = try await store.load(subscriberId: "unknown")
        #expect(position == nil)
    }

    @Test func saveAndLoad() async throws {
        let store = InMemoryPositionStore()
        try await store.save(subscriberId: "sub-1", globalPosition: 42)
        let position = try await store.load(subscriberId: "sub-1")
        #expect(position == 42)
    }

    @Test func saveOverwritesPrevious() async throws {
        let store = InMemoryPositionStore()
        try await store.save(subscriberId: "sub-1", globalPosition: 10)
        try await store.save(subscriberId: "sub-1", globalPosition: 50)
        let position = try await store.load(subscriberId: "sub-1")
        #expect(position == 50)
    }

    @Test func subscribersAreIsolated() async throws {
        let store = InMemoryPositionStore()
        try await store.save(subscriberId: "sub-a", globalPosition: 10)
        try await store.save(subscriberId: "sub-b", globalPosition: 20)
        #expect(try await store.load(subscriberId: "sub-a") == 10)
        #expect(try await store.load(subscriberId: "sub-b") == 20)
    }
}
