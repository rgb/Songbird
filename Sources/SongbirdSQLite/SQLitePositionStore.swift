import Dispatch
import Foundation
import Songbird
import SQLite

public actor SQLitePositionStore: PositionStore {
    /// The underlying SQLite connection. Marked `nonisolated(unsafe)` because all access
    /// is serialized through this actor's custom `DispatchSerialQueue` executor, ensuring
    /// that only one thread accesses the connection at a time.
    nonisolated(unsafe) let db: Connection
    private let executor: DispatchSerialQueue


    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    public init(path: String) throws {
        self.executor = DispatchSerialQueue(label: "songbird.sqlite-position-store")
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
        try db.execute("PRAGMA foreign_keys = ON")
    }

    // MARK: - Migrations

    private static func migrate(_ db: Connection) throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS positions (
                subscriber_id   TEXT PRIMARY KEY,
                global_position INTEGER NOT NULL,
                updated_at      TEXT NOT NULL
            )
        """)
    }

    // MARK: - PositionStore

    public func load(subscriberId: String) async throws -> Int64? {
        let result = try db.scalar(
            "SELECT global_position FROM positions WHERE subscriber_id = ?",
            subscriberId
        )
        return result as? Int64
    }

    public func save(subscriberId: String, globalPosition: Int64) async throws {
        let now = Date.now.formatted(.iso8601)
        try db.run(
            """
            INSERT INTO positions (subscriber_id, global_position, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(subscriber_id) DO UPDATE SET
                global_position = excluded.global_position,
                updated_at = excluded.updated_at
            """,
            subscriberId, globalPosition, now
        )
    }
}
