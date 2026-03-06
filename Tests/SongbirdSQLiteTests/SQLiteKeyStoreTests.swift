import Testing

@testable import Songbird
@testable import SongbirdSQLite

@Suite("SQLiteKeyStore")
struct SQLiteKeyStoreTests {

    private func makeStore() throws -> SQLiteKeyStore {
        try SQLiteKeyStore(path: ":memory:")
    }

    @Test func getOrCreateReturnsSameKey() async throws {
        let store = try makeStore()
        let key1 = try await store.key(for: "entity-1", layer: .pii)
        let key2 = try await store.key(for: "entity-1", layer: .pii)
        #expect(key1 == key2)
    }

    @Test func differentEntitiesGetDifferentKeys() async throws {
        let store = try makeStore()
        let key1 = try await store.key(for: "entity-1", layer: .pii)
        let key2 = try await store.key(for: "entity-2", layer: .pii)
        #expect(key1 != key2)
    }

    @Test func deleteKeyMakesItUnavailable() async throws {
        let store = try makeStore()
        _ = try await store.key(for: "entity-1", layer: .pii)
        try await store.deleteKey(for: "entity-1", layer: .pii)
        let found = try await store.existingKey(for: "entity-1", layer: .pii)
        #expect(found == nil)
    }

    @Test func keyPersistsAcrossLookups() async throws {
        let store = try makeStore()
        let created = try await store.key(for: "entity-1", layer: .pii)
        let found = try await store.existingKey(for: "entity-1", layer: .pii)
        #expect(found == created)
    }

    @Test func differentLayersAreIndependent() async throws {
        let store = try makeStore()
        let piiKey = try await store.key(for: "entity-1", layer: .pii)
        let retKey = try await store.key(for: "entity-1", layer: .retention)
        #expect(piiKey != retKey)
        try await store.deleteKey(for: "entity-1", layer: .pii)
        #expect(try await store.hasKey(for: "entity-1", layer: .retention) == true)
    }

    @Test func hasKeyReturnsFalseAfterDelete() async throws {
        let store = try makeStore()
        _ = try await store.key(for: "entity-1", layer: .pii)
        try await store.deleteKey(for: "entity-1", layer: .pii)
        #expect(try await store.hasKey(for: "entity-1", layer: .pii) == false)
    }
}
