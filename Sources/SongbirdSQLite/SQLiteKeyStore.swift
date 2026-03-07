import CryptoKit
import Dispatch
import Foundation
import Songbird
import SQLite

public enum SQLiteKeyStoreError: Error {
    case corruptedRow(column: String, reference: String)
}

/// A SQLite-backed key store that persists AES-256 encryption keys.
///
/// Uses an `encryption_keys` table with a composite primary key of `(reference, layer)`.
/// Keys are stored as raw byte BLOBs and reconstructed as `SymmetricKey` on read.
public actor SQLiteKeyStore: KeyStore {
    /// The underlying SQLite connection. Marked `nonisolated(unsafe)` because all access
    /// is serialized through this actor's custom `DispatchSerialQueue` executor, ensuring
    /// that only one thread accesses the connection at a time.
    nonisolated(unsafe) let db: Connection
    private let executor: DispatchSerialQueue
    private let iso8601Formatter = ISO8601DateFormatter()

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    public init(path: String) throws {
        self.executor = DispatchSerialQueue(label: "songbird.sqlite-key-store")
        if path == ":memory:" {
            self.db = try Connection(.inMemory)
        } else {
            self.db = try Connection(path)
        }
        try Self.configurePragmas(db)
        try Self.migrate(db)
    }

    // MARK: - Pragmas

    private static func configurePragmas(_ db: Connection) throws {
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("PRAGMA synchronous = NORMAL")
    }

    // MARK: - Migrations

    private static func migrate(_ db: Connection) throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS encryption_keys (
                reference   TEXT NOT NULL,
                layer       TEXT NOT NULL,
                key_data    BLOB NOT NULL,
                created_at  TEXT NOT NULL,
                expires_at  TEXT,
                PRIMARY KEY (reference, layer)
            )
        """)
    }

    // MARK: - KeyStore

    public func key(for reference: String, layer: KeyLayer, expiresAfter: Duration? = nil) async throws -> SymmetricKey {
        if let existing = try await existingKey(for: reference, layer: layer) {
            return existing
        }

        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        let now = Date()
        let nowStr = iso8601Formatter.string(from: now)
        let expiresAtStr: String? = expiresAfter.map { duration in
            let (seconds, attoseconds) = duration.components
            let totalSeconds = Double(seconds) + Double(attoseconds) / 1e18
            return iso8601Formatter.string(from: now + totalSeconds)
        }

        // Delete any expired key so the INSERT below can succeed.
        try db.run(
            "DELETE FROM encryption_keys WHERE reference = ? AND layer = ? AND expires_at IS NOT NULL AND expires_at <= ?",
            reference, layer.rawValue, nowStr
        )

        // Use INSERT OR IGNORE to handle concurrent inserts safely.
        // If another caller inserted between our SELECT and INSERT,
        // this is a no-op and we fall through to re-read.
        try db.run(
            """
            INSERT OR IGNORE INTO encryption_keys (reference, layer, key_data, created_at, expires_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            reference, layer.rawValue, Blob(bytes: [UInt8](keyData)), nowStr, expiresAtStr
        )

        // Re-read to handle the race: if our INSERT was a no-op,
        // this returns the key the other caller inserted.
        if let existing = try await existingKey(for: reference, layer: layer) {
            return existing
        }

        preconditionFailure("Key not found after INSERT OR IGNORE for reference '\(reference)', layer '\(layer.rawValue)'")
    }

    public func existingKey(for reference: String, layer: KeyLayer) async throws -> SymmetricKey? {
        let nowStr = iso8601Formatter.string(from: Date())
        let rows = try db.prepare(
            "SELECT key_data FROM encryption_keys WHERE reference = ? AND layer = ? AND (expires_at IS NULL OR expires_at > ?) LIMIT 1",
            reference, layer.rawValue, nowStr
        )

        for row in rows {
            guard let blob = row[0] as? Blob else {
                throw SQLiteKeyStoreError.corruptedRow(column: "key_data", reference: reference)
            }
            return SymmetricKey(data: Data(blob.bytes))
        }
        return nil
    }

    public func deleteKey(for reference: String, layer: KeyLayer) async throws {
        try db.run(
            "DELETE FROM encryption_keys WHERE reference = ? AND layer = ?",
            reference, layer.rawValue
        )
    }

    public func hasKey(for reference: String, layer: KeyLayer) async throws -> Bool {
        let nowStr = iso8601Formatter.string(from: Date())
        let rows = try db.prepare(
            "SELECT COUNT(*) FROM encryption_keys WHERE reference = ? AND layer = ? AND (expires_at IS NULL OR expires_at > ?)",
            reference, layer.rawValue, nowStr
        )

        for row in rows {
            guard let count = row[0] as? Int64 else {
                throw SQLiteKeyStoreError.corruptedRow(column: "count", reference: reference)
            }
            return count > 0
        }
        return false
    }

    // MARK: - Test Support

    #if DEBUG
    /// Execute raw SQL. **Test-only** — used for scenarios like backdating
    /// expiry timestamps. Not available in release builds.
    public func rawExecute(_ sql: String, _ bindings: Binding?...) throws {
        try db.run(sql, bindings)
    }
    #endif
}
