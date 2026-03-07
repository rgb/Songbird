import CryptoKit
import Foundation

/// A decorator that wraps any ``EventStore``, encrypting PII fields on append
/// and decrypting on read. Uses AES-256-GCM from CryptoKit.
///
/// Fields marked with ``FieldProtection/pii`` are encrypted with a per-entity PII key.
/// Fields marked with ``FieldProtection/retention(_:)`` are encrypted with a per-entity retention key.
/// Fields marked with ``FieldProtection/piiAndRetention(_:)`` are double-encrypted: inner PII, outer retention.
///
/// Calling ``forget(entity:)`` deletes the PII key, making all PII and piiAndRetention
/// fields for that entity permanently unreadable (shredded).
///
/// Plain (non-shreddable) events pass through unchanged.
public struct CryptoShreddingStore<Inner: EventStore>: Sendable {
    private let inner: Inner
    private let keyStore: any KeyStore
    private let registry: CryptoShreddableRegistry

    public init(inner: Inner, keyStore: any KeyStore, registry: CryptoShreddableRegistry) {
        self.inner = inner
        self.keyStore = keyStore
        self.registry = registry
    }
}

// MARK: - EventStore Conformance

extension CryptoShreddingStore: EventStore {
    public func append(
        _ event: some Event,
        to stream: StreamName,
        metadata: EventMetadata,
        expectedVersion: Int64?
    ) async throws -> RecordedEvent {
        // Check if this event type has field protection
        guard let protection = registry.fieldProtection(for: event.eventType),
              !protection.isEmpty
        else {
            // Not crypto-shreddable — pass through unchanged
            return try await inner.append(event, to: stream, metadata: metadata, expectedVersion: expectedVersion)
        }

        // Encode event to JSON, parse to field dictionary
        let jsonData = try JSONEncoder().encode(event)
        var fields = try JSONDecoder().decode([String: JSONValue].self, from: jsonData)

        // Entity ID for key lookup (from stream name)
        let entityId = stream.id ?? stream.description

        // Encrypt each protected field
        for (fieldName, level) in protection {
            guard let fieldValue = fields[fieldName], fieldValue != .null else { continue }

            let plaintext = try fieldValue.toJSONFragmentData()

            switch level {
            case .pii:
                let piiKey = try await keyStore.key(for: entityId, layer: .pii)
                let ciphertext = try encrypt(plaintext, using: piiKey)
                fields[fieldName] = .string("enc:pii:\(ciphertext)")

            case .retention(let duration):
                let retKey = try await keyStore.key(for: entityId, layer: .retention, expiresAfter: duration)
                let ciphertext = try encrypt(plaintext, using: retKey)
                fields[fieldName] = .string("enc:ret:\(ciphertext)")

            case .piiAndRetention(let duration):
                let piiKey = try await keyStore.key(for: entityId, layer: .pii)
                let retKey = try await keyStore.key(for: entityId, layer: .retention, expiresAfter: duration)
                // Double-encrypt: inner PII, outer retention
                let innerCiphertext = try encrypt(plaintext, using: piiKey)
                let outerCiphertext = try encrypt(
                    Data(innerCiphertext.utf8), using: retKey
                )
                fields[fieldName] = .string("enc:pii+ret:\(outerCiphertext)")
            }
        }

        // Set PII reference key in metadata
        var updatedMetadata = metadata
        updatedMetadata.piiReferenceKey = entityId

        // Create EncryptedPayload and pass to inner store
        let payload = EncryptedPayload(originalEventType: event.eventType, fields: fields)
        return try await inner.append(
            payload, to: stream, metadata: updatedMetadata, expectedVersion: expectedVersion
        )
    }

    public func readStream(
        _ stream: StreamName,
        from position: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        let records = try await inner.readStream(stream, from: position, maxCount: maxCount)
        return try await records.asyncMap { try await decryptRecord($0) }
    }

    public func readCategories(
        _ categories: [String],
        from globalPosition: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        let records = try await inner.readCategories(
            categories, from: globalPosition, maxCount: maxCount
        )
        return try await records.asyncMap { try await decryptRecord($0) }
    }

    public func readLastEvent(
        in stream: StreamName
    ) async throws -> RecordedEvent? {
        guard let record = try await inner.readLastEvent(in: stream) else { return nil }
        return try await decryptRecord(record)
    }

    public func streamVersion(
        _ stream: StreamName
    ) async throws -> Int64 {
        try await inner.streamVersion(stream)
    }
}

// MARK: - Shredding Operations

extension CryptoShreddingStore {
    /// Permanently forget an entity by deleting their PII encryption key.
    /// All PII and piiAndRetention fields for this entity become permanently unreadable.
    public func forget(entity: String) async throws {
        try await keyStore.deleteKey(for: entity, layer: .pii)
    }
}

// MARK: - Encryption Helpers

extension CryptoShreddingStore {
    /// AES-256-GCM encrypt, returns base64-encoded (nonce + ciphertext + tag).
    private func encrypt(_ plaintext: Data, using key: SymmetricKey) throws -> String {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw CryptoShreddingError.sealFailure
        }
        return combined.base64EncodedString()
    }

    /// AES-256-GCM decrypt from base64-encoded combined data.
    private func decrypt(_ base64Ciphertext: String, using key: SymmetricKey) throws -> Data {
        guard let combined = Data(base64Encoded: base64Ciphertext) else {
            throw CryptoShreddingError.invalidCiphertext
        }
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(sealedBox, using: key)
    }

    /// Decrypt a single field value, returning the decrypted JSONValue or .null if shredded.
    private func decryptField(_ encryptedString: String, entityId: String) async throws -> JSONValue {
        if encryptedString.hasPrefix("enc:pii:") {
            let ciphertext = String(encryptedString.dropFirst("enc:pii:".count))
            guard let key = try await keyStore.existingKey(for: entityId, layer: .pii) else {
                return .null // shredded
            }
            let plaintext = try decrypt(ciphertext, using: key)
            return try JSONValue.fromJSONFragmentData(plaintext)

        } else if encryptedString.hasPrefix("enc:ret:") {
            let ciphertext = String(encryptedString.dropFirst("enc:ret:".count))
            guard let key = try await keyStore.existingKey(for: entityId, layer: .retention) else {
                return .null // expired
            }
            let plaintext = try decrypt(ciphertext, using: key)
            return try JSONValue.fromJSONFragmentData(plaintext)

        } else if encryptedString.hasPrefix("enc:pii+ret:") {
            let outerCiphertext = String(encryptedString.dropFirst("enc:pii+ret:".count))

            // Outer layer: retention
            guard let retKey = try await keyStore.existingKey(for: entityId, layer: .retention) else {
                return .null // retention expired
            }
            let innerCiphertextData = try decrypt(outerCiphertext, using: retKey)
            guard let innerCiphertext = String(data: innerCiphertextData, encoding: .utf8) else {
                throw CryptoShreddingError.invalidCiphertext
            }

            // Inner layer: PII
            guard let piiKey = try await keyStore.existingKey(for: entityId, layer: .pii) else {
                return .null // PII shredded
            }
            let plaintext = try decrypt(innerCiphertext, using: piiKey)
            return try JSONValue.fromJSONFragmentData(plaintext)

        } else {
            // Not an encrypted value — shouldn't happen for protected fields
            return .string(encryptedString)
        }
    }

    /// Decrypt all protected fields in a RecordedEvent, returning a new RecordedEvent with plaintext data.
    private func decryptRecord(_ record: RecordedEvent) async throws -> RecordedEvent {
        guard let protection = registry.fieldProtection(for: record.eventType),
              !protection.isEmpty
        else {
            return record // not crypto-shreddable
        }

        let entityId = record.streamName.id ?? record.streamName.description
        var fields = try JSONDecoder().decode([String: JSONValue].self, from: record.data)

        for (fieldName, _) in protection {
            guard case .string(let encryptedString) = fields[fieldName],
                  encryptedString.hasPrefix("enc:")
            else { continue }

            fields[fieldName] = try await decryptField(encryptedString, entityId: entityId)
        }

        // Re-encode with sorted keys for determinism
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let decryptedData = try encoder.encode(fields)

        return RecordedEvent(
            id: record.id,
            streamName: record.streamName,
            position: record.position,
            globalPosition: record.globalPosition,
            eventType: record.eventType,
            data: decryptedData,
            metadata: record.metadata,
            timestamp: record.timestamp
        )
    }
}

// MARK: - Async Map Helper

extension Array where Element: Sendable {
    func asyncMap<T: Sendable>(
        _ transform: (Element) async throws -> T
    ) async rethrows -> [T] {
        var results: [T] = []
        results.reserveCapacity(count)
        for element in self {
            results.append(try await transform(element))
        }
        return results
    }
}

// MARK: - Errors

public enum CryptoShreddingError: Error, Equatable {
    case invalidCiphertext
    case sealFailure
}
