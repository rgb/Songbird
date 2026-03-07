import Dispatch
import Foundation
import Songbird
import SQLite

public enum SQLiteSnapshotStoreError: Error {
    case corruptedRow(column: String, streamName: String)
}

/// A SQLite-backed snapshot store that persists aggregate state checkpoints.
///
/// Uses a single `snapshots` table with the stream name as the primary key.
/// Only the latest snapshot per stream is kept (upsert on save).
public actor SQLiteSnapshotStore: SnapshotStore {
    /// The underlying SQLite connection. Marked `nonisolated(unsafe)` because all access
    /// is serialized through this actor's custom `DispatchSerialQueue` executor, ensuring
    /// that only one thread accesses the connection at a time.
    private nonisolated(unsafe) let db: Connection
    private let executor: DispatchSerialQueue


    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    public init(path: String) throws {
        self.executor = DispatchSerialQueue(label: "songbird.sqlite-snapshot-store")
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
            CREATE TABLE IF NOT EXISTS snapshots (
                stream_name TEXT PRIMARY KEY,
                state       BLOB NOT NULL,
                version     INTEGER NOT NULL,
                updated_at  TEXT NOT NULL
            )
        """)
    }

    // MARK: - SnapshotStore

    public func saveData(
        _ data: Data,
        version: Int64,
        for stream: StreamName
    ) async throws {
        let now = Date.now.formatted(.iso8601)
        try db.run(
            """
            INSERT INTO snapshots (stream_name, state, version, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(stream_name) DO UPDATE SET
                state = excluded.state,
                version = excluded.version,
                updated_at = excluded.updated_at
            """,
            stream.description, Blob(bytes: [UInt8](data)), version, now
        )
    }

    public func loadData(
        for stream: StreamName
    ) async throws -> (data: Data, version: Int64)? {
        let rows = try db.prepare(
            "SELECT state, version FROM snapshots WHERE stream_name = ? LIMIT 1",
            stream.description
        )

        for row in rows {
            guard let blob = row[0] as? Blob else {
                throw SQLiteSnapshotStoreError.corruptedRow(column: "state", streamName: stream.description)
            }
            guard let version = row[1] as? Int64 else {
                throw SQLiteSnapshotStoreError.corruptedRow(column: "version", streamName: stream.description)
            }
            let data = Data(blob.bytes)
            return (data, version)
        }
        return nil
    }
}
