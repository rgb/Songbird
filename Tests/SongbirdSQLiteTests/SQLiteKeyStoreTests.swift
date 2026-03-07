import Foundation
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

    @Test func expiredKeyIsNotReturned() async throws {
        let store = try makeStore()

        // Create a key with an expiry
        _ = try await store.key(for: "entity-1", layer: .pii, expiresAfter: .seconds(3600))

        // Verify it exists before expiry
        #expect(try await store.existingKey(for: "entity-1", layer: .pii) != nil)
        #expect(try await store.hasKey(for: "entity-1", layer: .pii) == true)

        // Manually backdate expires_at to a past timestamp
        let pastDate = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -60))
        try store.db.run(
            "UPDATE encryption_keys SET expires_at = ? WHERE reference = ? AND layer = ?",
            pastDate, "entity-1", KeyLayer.pii.rawValue
        )

        // Verify the expired key is no longer returned
        #expect(try await store.existingKey(for: "entity-1", layer: .pii) == nil)
        #expect(try await store.hasKey(for: "entity-1", layer: .pii) == false)
    }

    @Test func nonExpiringKeyIsAlwaysReturned() async throws {
        let store = try makeStore()

        // Create a key without expiry (expires_at is NULL)
        _ = try await store.key(for: "entity-1", layer: .pii)

        // Verify it exists
        #expect(try await store.existingKey(for: "entity-1", layer: .pii) != nil)
        #expect(try await store.hasKey(for: "entity-1", layer: .pii) == true)
    }

    @Test func keyWithExpiryReturnsNewKeyAfterExpiry() async throws {
        let store = try makeStore()

        // Create a key with an expiry
        let originalKey = try await store.key(for: "entity-1", layer: .pii, expiresAfter: .seconds(3600))

        // Manually backdate expires_at to a past timestamp
        let pastDate = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -60))
        try store.db.run(
            "UPDATE encryption_keys SET expires_at = ? WHERE reference = ? AND layer = ?",
            pastDate, "entity-1", KeyLayer.pii.rawValue
        )

        // Delete the expired row so a new key can be created
        try await store.deleteKey(for: "entity-1", layer: .pii)

        // Request a new key — should generate a fresh one since the old one was deleted
        let newKey = try await store.key(for: "entity-1", layer: .pii, expiresAfter: .seconds(3600))
        #expect(newKey != originalKey)
    }
}
