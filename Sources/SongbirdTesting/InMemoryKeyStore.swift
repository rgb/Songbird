import CryptoKit
import Songbird

public actor InMemoryKeyStore: KeyStore {
    private var keys: [String: SymmetricKey] = [:]

    public init() {}

    public func key(for reference: String, layer: KeyLayer, expiresAfter: Duration? = nil) async throws -> SymmetricKey {
        let id = storageKey(reference, layer)
        if let existing = keys[id] { return existing }
        let key = SymmetricKey(size: .bits256)
        keys[id] = key
        return key
    }

    public func existingKey(for reference: String, layer: KeyLayer) async throws -> SymmetricKey? {
        keys[storageKey(reference, layer)]
    }

    public func deleteKey(for reference: String, layer: KeyLayer) async throws {
        keys.removeValue(forKey: storageKey(reference, layer))
    }

    public func hasKey(for reference: String, layer: KeyLayer) async throws -> Bool {
        keys[storageKey(reference, layer)] != nil
    }

    private func storageKey(_ reference: String, _ layer: KeyLayer) -> String {
        "\(reference):\(layer.rawValue)"
    }
}
