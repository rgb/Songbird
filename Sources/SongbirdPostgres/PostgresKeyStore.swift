import CryptoKit
import Foundation
import PostgresNIO
import Songbird

/// A PostgreSQL-backed key store that persists AES-256 encryption keys.
///
/// Uses an `encryption_keys` table with a composite primary key of `(reference, layer)`.
/// Keys are stored as `BYTEA` columns and reconstructed as `SymmetricKey` on read.
public struct PostgresKeyStore: KeyStore, Sendable {
    private let client: PostgresClient

    public init(client: PostgresClient) {
        self.client = client
    }

    public func key(for reference: String, layer: KeyLayer) async throws -> SymmetricKey {
        if let existing = try await existingKey(for: reference, layer: layer) {
            return existing
        }

        let newKey = SymmetricKey(size: .bits256)
        let keyBytes = newKey.withUnsafeBytes { Data($0) }
        let layerStr = layer.rawValue

        try await client.query("""
            INSERT INTO encryption_keys (reference, layer, key_data, created_at)
            VALUES (\(reference), \(layerStr), \(keyBytes), NOW())
            """)

        return newKey
    }

    public func existingKey(for reference: String, layer: KeyLayer) async throws -> SymmetricKey? {
        let layerStr = layer.rawValue
        let rows = try await client.query(
            "SELECT key_data FROM encryption_keys WHERE reference = \(reference) AND layer = \(layerStr)"
        )

        for try await (keyData,) in rows.decode((Data,).self) {
            return SymmetricKey(data: keyData)
        }
        return nil
    }

    public func deleteKey(for reference: String, layer: KeyLayer) async throws {
        let layerStr = layer.rawValue
        try await client.query(
            "DELETE FROM encryption_keys WHERE reference = \(reference) AND layer = \(layerStr)"
        )
    }

    public func hasKey(for reference: String, layer: KeyLayer) async throws -> Bool {
        let layerStr = layer.rawValue
        let rows = try await client.query(
            "SELECT COUNT(*) FROM encryption_keys WHERE reference = \(reference) AND layer = \(layerStr)"
        )

        for try await (count,) in rows.decode((Int64,).self) {
            return count > 0
        }
        return false
    }
}
