import CryptoKit
import Foundation
import Testing
@testable import Songbird
@testable import SongbirdTesting

@Suite("InMemoryKeyStore")
struct InMemoryKeyStoreTests {
    @Test func getOrCreateReturnsSameKey() async throws {
        let store = InMemoryKeyStore()
        let key1 = try await store.key(for: "entity-1", layer: .pii)
        let key2 = try await store.key(for: "entity-1", layer: .pii)
        #expect(key1 == key2)
    }

    @Test func differentEntitiesGetDifferentKeys() async throws {
        let store = InMemoryKeyStore()
        let key1 = try await store.key(for: "entity-1", layer: .pii)
        let key2 = try await store.key(for: "entity-2", layer: .pii)
        #expect(key1 != key2)
    }

    @Test func differentLayersGetDifferentKeys() async throws {
        let store = InMemoryKeyStore()
        let piiKey = try await store.key(for: "entity-1", layer: .pii)
        let retKey = try await store.key(for: "entity-1", layer: .retention)
        #expect(piiKey != retKey)
    }

    @Test func existingKeyReturnsKeyWhenPresent() async throws {
        let store = InMemoryKeyStore()
        let created = try await store.key(for: "entity-1", layer: .pii)
        let found = try await store.existingKey(for: "entity-1", layer: .pii)
        #expect(found == created)
    }

    @Test func existingKeyReturnsNilWhenMissing() async throws {
        let store = InMemoryKeyStore()
        let found = try await store.existingKey(for: "entity-1", layer: .pii)
        #expect(found == nil)
    }

    @Test func deleteKeyMakesItUnavailable() async throws {
        let store = InMemoryKeyStore()
        _ = try await store.key(for: "entity-1", layer: .pii)
        try await store.deleteKey(for: "entity-1", layer: .pii)
        let found = try await store.existingKey(for: "entity-1", layer: .pii)
        #expect(found == nil)
    }

    @Test func hasKeyReturnsTrueWhenPresent() async throws {
        let store = InMemoryKeyStore()
        _ = try await store.key(for: "entity-1", layer: .pii)
        #expect(try await store.hasKey(for: "entity-1", layer: .pii) == true)
    }

    @Test func hasKeyReturnsFalseAfterDelete() async throws {
        let store = InMemoryKeyStore()
        _ = try await store.key(for: "entity-1", layer: .pii)
        try await store.deleteKey(for: "entity-1", layer: .pii)
        #expect(try await store.hasKey(for: "entity-1", layer: .pii) == false)
    }

    @Test func deleteDoesNotAffectOtherEntities() async throws {
        let store = InMemoryKeyStore()
        _ = try await store.key(for: "entity-1", layer: .pii)
        _ = try await store.key(for: "entity-2", layer: .pii)
        try await store.deleteKey(for: "entity-1", layer: .pii)
        #expect(try await store.hasKey(for: "entity-2", layer: .pii) == true)
    }

    @Test func deleteDoesNotAffectOtherLayers() async throws {
        let store = InMemoryKeyStore()
        _ = try await store.key(for: "entity-1", layer: .pii)
        _ = try await store.key(for: "entity-1", layer: .retention)
        try await store.deleteKey(for: "entity-1", layer: .pii)
        #expect(try await store.hasKey(for: "entity-1", layer: .retention) == true)
    }
}
