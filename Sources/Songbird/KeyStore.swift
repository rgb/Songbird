import CryptoKit

public enum KeyLayer: String, Sendable {
    case pii
    case retention
}

public protocol KeyStore: Sendable {
    func key(for reference: String, layer: KeyLayer) async throws -> SymmetricKey
    func existingKey(for reference: String, layer: KeyLayer) async throws -> SymmetricKey?
    func deleteKey(for reference: String, layer: KeyLayer) async throws
    func hasKey(for reference: String, layer: KeyLayer) async throws -> Bool
}
