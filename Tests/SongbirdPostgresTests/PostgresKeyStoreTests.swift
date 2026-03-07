import CryptoKit
import Foundation
import Testing

@testable import Songbird
@testable import SongbirdPostgres

extension AllPostgresTests { @Suite("PostgresKeyStore") struct KeyStoreTests {

    @Test func getOrCreateReturnsSameKey() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresKeyStore(client: client)
            let key1 = try await store.key(for: "entity-1", layer: .pii)
            let key2 = try await store.key(for: "entity-1", layer: .pii)
            #expect(key1 == key2)
        }
    }

    @Test func differentEntitiesGetDifferentKeys() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresKeyStore(client: client)
            let key1 = try await store.key(for: "entity-1", layer: .pii)
            let key2 = try await store.key(for: "entity-2", layer: .pii)
            #expect(key1 != key2)
        }
    }

    @Test func deleteKeyMakesItUnavailable() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresKeyStore(client: client)
            _ = try await store.key(for: "entity-1", layer: .pii)
            try await store.deleteKey(for: "entity-1", layer: .pii)
            let found = try await store.existingKey(for: "entity-1", layer: .pii)
            #expect(found == nil)
        }
    }

    @Test func keyPersistsAcrossLookups() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresKeyStore(client: client)
            let created = try await store.key(for: "entity-1", layer: .pii)
            let found = try await store.existingKey(for: "entity-1", layer: .pii)
            #expect(found == created)
        }
    }

    @Test func differentLayersAreIndependent() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresKeyStore(client: client)
            let piiKey = try await store.key(for: "entity-1", layer: .pii)
            let retKey = try await store.key(for: "entity-1", layer: .retention)
            #expect(piiKey != retKey)
            try await store.deleteKey(for: "entity-1", layer: .pii)
            #expect(try await store.hasKey(for: "entity-1", layer: .retention) == true)
        }
    }

    @Test func hasKeyReturnsFalseAfterDelete() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresKeyStore(client: client)
            _ = try await store.key(for: "entity-1", layer: .pii)
            try await store.deleteKey(for: "entity-1", layer: .pii)
            #expect(try await store.hasKey(for: "entity-1", layer: .pii) == false)
        }
    }

    @Test func expiredKeyIsNotReturned() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresKeyStore(client: client)

            // Create a key with a long expiry so it's valid initially
            let key1 = try await store.key(for: "ref-exp", layer: .retention, expiresAfter: .seconds(3600))

            // Key should exist immediately
            #expect(try await store.hasKey(for: "ref-exp", layer: .retention) == true)
            #expect(try await store.existingKey(for: "ref-exp", layer: .retention) != nil)

            // Manually expire the key by setting expires_at to the past
            try await client.query(
                "UPDATE encryption_keys SET expires_at = NOW() - interval '1 hour' WHERE reference = \("ref-exp") AND layer = \("retention")"
            )

            // Key should now be filtered out
            #expect(try await store.existingKey(for: "ref-exp", layer: .retention) == nil)
            #expect(try await store.hasKey(for: "ref-exp", layer: .retention) == false)

            // Requesting a key should generate a new one (replacing the expired one)
            let key2 = try await store.key(for: "ref-exp", layer: .retention)
            #expect(key1 != key2)
        }
    }

    @Test func expiresAfterStoresExpiryAndKeyIsRetrievable() async throws {
        try await PostgresTestHelper.withTestClient { client in
            try await PostgresTestHelper.cleanTables(client: client)
            let store = PostgresKeyStore(client: client)

            // Create a key with a 1-hour expiry
            let created = try await store.key(for: "entity-1", layer: .pii, expiresAfter: .seconds(3600))

            // Verify the key is retrievable before expiry
            let found = try await store.existingKey(for: "entity-1", layer: .pii)
            #expect(found == created)

            // Verify expires_at was actually stored in the database (not NULL)
            let rows = try await client.query(
                "SELECT expires_at FROM encryption_keys WHERE reference = \("entity-1") AND layer = \("pii")"
            )
            var expiresAtFound = false
            for try await (expiresAt,) in rows.decode((Date?,).self) {
                #expect(expiresAt != nil, "expires_at should be stored when expiresAfter is provided")
                expiresAtFound = true
            }
            #expect(expiresAtFound, "Expected a row in encryption_keys")
        }
    }
}}
