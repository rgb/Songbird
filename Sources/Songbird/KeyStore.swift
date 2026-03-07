import CryptoKit

public enum KeyLayer: String, Sendable {
    case pii
    case retention
}

public protocol KeyStore: Sendable {
    func key(for reference: String, layer: KeyLayer, expiresAfter: Duration?) async throws -> SymmetricKey
    func existingKey(for reference: String, layer: KeyLayer) async throws -> SymmetricKey?
    func deleteKey(for reference: String, layer: KeyLayer) async throws
    func hasKey(for reference: String, layer: KeyLayer) async throws -> Bool
}

extension KeyStore {
    public func key(for reference: String, layer: KeyLayer) async throws -> SymmetricKey {
        try await key(for: reference, layer: layer, expiresAfter: nil)
    }
}
