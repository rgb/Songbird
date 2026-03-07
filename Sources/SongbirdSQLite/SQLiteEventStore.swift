import CryptoKit
import Dispatch
import Foundation
import Songbird
import SQLite

public enum SQLiteEventStoreError: Error {
    case corruptedRow(column: String, globalPosition: Int64?)
    case encodingFailed
}

public actor SQLiteEventStore: EventStore {
    /// The underlying SQLite connection. Marked `nonisolated(unsafe)` because all access
    /// is serialized through this actor's custom `DispatchSerialQueue` executor, ensuring
    /// that only one thread accesses the connection at a time.
    nonisolated(unsafe) let db: Connection
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()
    private let executor: DispatchSerialQueue

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    public init(path: String, registry: EventTypeRegistry = .init()) throws {
        self.executor = DispatchSerialQueue(label: "songbird.sqlite-event-store")
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

    private static func schemaVersion(_ db: Connection) throws -> Int {
        guard let tableExists = try db.scalar(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='schema_version'"
        ) as? Int64 else {
            return 0
        }
        if tableExists == 0 { return 0 }
        guard let version = try db.scalar("SELECT version FROM schema_version") as? Int64 else {
            throw SQLiteEventStoreError.corruptedRow(column: "version", globalPosition: nil)
        }
        return Int(version)
    }

    private static func migrate(_ db: Connection) throws {
        let version = try schemaVersion(db)
        if version < 1 { try migrateToV1(db) }
    }

    private static func migrateToV1(_ db: Connection) throws {
        try db.execute("""
            CREATE TABLE schema_version (version INTEGER NOT NULL);
            INSERT INTO schema_version VALUES (1);

            CREATE TABLE events (
                global_position  INTEGER PRIMARY KEY AUTOINCREMENT,
                stream_name      TEXT NOT NULL,
                stream_category  TEXT NOT NULL,
                position         INTEGER NOT NULL,
                event_type       TEXT NOT NULL,
                data             TEXT NOT NULL,
                metadata         TEXT NOT NULL,
                event_id         TEXT NOT NULL,
                timestamp        TEXT NOT NULL,
                event_hash       TEXT
            );

            CREATE INDEX idx_events_stream ON events(stream_name, position);
            CREATE INDEX idx_events_category ON events(stream_category, global_position);
            CREATE UNIQUE INDEX idx_events_event_id ON events(event_id);
        """)
    }

    // MARK: - Append

    public func append(
        _ event: some Event,
        to stream: StreamName,
        metadata: EventMetadata,
        expectedVersion: Int64?
    ) async throws -> RecordedEvent {
        let streamStr = stream.description
        let category = stream.category

        var result: RecordedEvent?

        try db.transaction(.immediate) {
            // Optimistic concurrency check (inside IMMEDIATE transaction — write-locked)
            let currentVersion = try currentStreamVersion(streamStr)
            if let expected = expectedVersion, expected != currentVersion {
                throw VersionConflictError(
                    streamName: stream,
                    expectedVersion: expected,
                    actualVersion: currentVersion
                )
            }

            let position = currentVersion + 1
            let eventId = UUID()
            let now = Date()
            let iso8601 = now.formatted(.iso8601)
            let eventData = try jsonEncoder.encode(event)
            guard let eventDataString = String(data: eventData, encoding: .utf8) else {
                throw SQLiteEventStoreError.encodingFailed
            }
            let metadataData = try jsonEncoder.encode(metadata)
            guard let metadataString = String(data: metadataData, encoding: .utf8) else {
                throw SQLiteEventStoreError.encodingFailed
            }
            let eventType = event.eventType

            // Hash chain
            let previousHash = try lastEventHash() ?? "genesis"
            let hashInput = "\(previousHash)\0\(eventType)\0\(streamStr)\0\(eventDataString)\0\(iso8601)"
            let eventHash = SHA256.hash(data: Data(hashInput.utf8))
                .map { String(format: "%02x", $0) }
                .joined()

            try db.run("""
                INSERT INTO events (stream_name, stream_category, position, event_type, data, metadata, event_id, timestamp, event_hash)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, streamStr, category, position, eventType, eventDataString, metadataString, eventId.uuidString, iso8601, eventHash)

            let globalPosition = db.lastInsertRowid - 1  // 0-based (AUTOINCREMENT starts at 1)

            result = RecordedEvent(
                id: eventId,
                streamName: stream,
                position: position,
                globalPosition: globalPosition,
                eventType: eventType,
                data: eventData,
                metadata: metadata,
                timestamp: now
            )
        }

        guard let result else {
            // This should never happen -- the transaction either throws or assigns result.
            throw SQLiteEventStoreError.encodingFailed
        }
        return result
    }

    // MARK: - Read Stream

    public func readStream(
        _ stream: StreamName,
        from position: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        let rows = try db.prepare("""
            SELECT global_position, stream_name, stream_category, position, event_type, data, metadata, event_id, timestamp
            FROM events
            WHERE stream_name = ? AND position >= ?
            ORDER BY position ASC
            LIMIT ?
        """, stream.description, position, maxCount)

        return try rows.map { row in try recordedEvent(from: row) }
    }

    // MARK: - Read Categories

    public func readCategories(
        _ categories: [String],
        from globalPosition: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        let rows: Statement
        if categories.isEmpty {
            rows = try db.prepare("""
                SELECT global_position, stream_name, stream_category, position, event_type, data, metadata, event_id, timestamp
                FROM events
                WHERE global_position >= ?
                ORDER BY global_position ASC
                LIMIT ?
            """, globalPosition + 1, maxCount)
        } else if categories.count == 1 {
            rows = try db.prepare("""
                SELECT global_position, stream_name, stream_category, position, event_type, data, metadata, event_id, timestamp
                FROM events
                WHERE stream_category = ? AND global_position >= ?
                ORDER BY global_position ASC
                LIMIT ?
            """, categories[0], globalPosition + 1, maxCount)
        } else {
            let placeholders = categories.map { _ in "?" }.joined(separator: ", ")
            let bindings: [Binding?] = categories.map { $0 as Binding? } + [(globalPosition + 1) as Binding?, maxCount as Binding?]
            rows = try db.prepare("""
                SELECT global_position, stream_name, stream_category, position, event_type, data, metadata, event_id, timestamp
                FROM events
                WHERE stream_category IN (\(placeholders)) AND global_position >= ?
                ORDER BY global_position ASC
                LIMIT ?
            """, bindings)
        }

        return try rows.map { row in try recordedEvent(from: row) }
    }

    // MARK: - Read Last Event

    public func readLastEvent(
        in stream: StreamName
    ) async throws -> RecordedEvent? {
        let rows = try db.prepare("""
            SELECT global_position, stream_name, stream_category, position, event_type, data, metadata, event_id, timestamp
            FROM events
            WHERE stream_name = ?
            ORDER BY position DESC
            LIMIT 1
        """, stream.description)

        for row in rows {
            return try recordedEvent(from: row)
        }
        return nil
    }

    // MARK: - Stream Version

    public func streamVersion(
        _ stream: StreamName
    ) async throws -> Int64 {
        try currentStreamVersion(stream.description)
    }

    // MARK: - Chain Verification

    public func verifyChain(batchSize: Int = 1000) async throws -> ChainVerificationResult {
        var previousHash = "genesis"
        var verified = 0
        var lastGlobalPosition: Int64 = 0  // AUTOINCREMENT starts at 1, so 0 means "before first"

        while true {
            try Task.checkCancellation()
            let rows = try db.prepare("""
                SELECT global_position, event_type, stream_name, data, timestamp, event_hash
                FROM events
                WHERE global_position > ?
                ORDER BY global_position ASC
                LIMIT ?
            """, lastGlobalPosition, batchSize)

            var batchCount = 0
            for row in rows {
                batchCount += 1
                guard let globalPos = row[0] as? Int64,
                      let eventType = row[1] as? String,
                      let streamName = row[2] as? String,
                      let data = row[3] as? String,
                      let timestamp = row[4] as? String
                else {
                    throw SQLiteEventStoreError.corruptedRow(column: "chain_verification", globalPosition: nil)
                }
                let storedHash = row[5] as? String
                lastGlobalPosition = globalPos

                let hashInput = "\(previousHash)\0\(eventType)\0\(streamName)\0\(data)\0\(timestamp)"
                let computedHash = SHA256.hash(data: Data(hashInput.utf8))
                    .map { String(format: "%02x", $0) }
                    .joined()

                if let storedHash, storedHash != computedHash {
                    return ChainVerificationResult(
                        intact: false,
                        eventsVerified: verified,
                        brokenAtSequence: globalPos - 1
                    )
                }

                previousHash = storedHash ?? computedHash
                verified += 1
            }

            if batchCount < batchSize { break }

            // Yield between batches to avoid monopolizing the executor during
            // long chain verifications.
            await Task.yield()
        }

        return ChainVerificationResult(intact: true, eventsVerified: verified)
    }

    // MARK: - Test Support

    #if DEBUG
    /// Execute raw SQL. **Test-only** — used for scenarios like corrupting data
    /// to test chain verification. Not available in release builds.
    public func rawExecute(_ sql: String) throws {
        try db.execute(sql)
    }
    #endif

    // MARK: - Private Helpers

    private func currentStreamVersion(_ streamName: String) throws -> Int64 {
        let result = try db.scalar("""
            SELECT MAX(position) FROM events WHERE stream_name = ?
        """, streamName)
        if let maxPos = result as? Int64 {
            return maxPos
        }
        return -1
    }

    private func lastEventHash() throws -> String? {
        let result = try db.scalar("""
            SELECT event_hash FROM events ORDER BY global_position DESC LIMIT 1
        """)
        return result as? String
    }

    private func recordedEvent(from row: [Binding?]) throws -> RecordedEvent {
        guard let autoincPos = row[0] as? Int64 else {
            throw SQLiteEventStoreError.corruptedRow(column: "global_position", globalPosition: nil)
        }
        let globalPosition = autoincPos - 1  // 0-based

        guard let streamStr = row[1] as? String else {
            throw SQLiteEventStoreError.corruptedRow(column: "stream_name", globalPosition: autoincPos)
        }
        guard let category = row[2] as? String else {
            throw SQLiteEventStoreError.corruptedRow(column: "stream_category", globalPosition: autoincPos)
        }
        guard let position = row[3] as? Int64 else {
            throw SQLiteEventStoreError.corruptedRow(column: "position", globalPosition: autoincPos)
        }
        guard let eventType = row[4] as? String else {
            throw SQLiteEventStoreError.corruptedRow(column: "event_type", globalPosition: autoincPos)
        }
        guard let dataStr = row[5] as? String else {
            throw SQLiteEventStoreError.corruptedRow(column: "data", globalPosition: autoincPos)
        }
        guard let metadataStr = row[6] as? String else {
            throw SQLiteEventStoreError.corruptedRow(column: "metadata", globalPosition: autoincPos)
        }
        guard let eventIdStr = row[7] as? String else {
            throw SQLiteEventStoreError.corruptedRow(column: "event_id", globalPosition: autoincPos)
        }
        guard let timestampStr = row[8] as? String else {
            throw SQLiteEventStoreError.corruptedRow(column: "timestamp", globalPosition: autoincPos)
        }

        let stream = StreamName(category: category, id: extractId(from: streamStr, category: category))
        let eventData = Data(dataStr.utf8)
        let metadata = try jsonDecoder.decode(EventMetadata.self, from: Data(metadataStr.utf8))

        guard let eventId = UUID(uuidString: eventIdStr) else {
            throw SQLiteEventStoreError.corruptedRow(column: "event_id", globalPosition: autoincPos)
        }
        guard let timestamp = try? Date(timestampStr, strategy: .iso8601) else {
            throw SQLiteEventStoreError.corruptedRow(column: "timestamp", globalPosition: autoincPos)
        }

        return RecordedEvent(
            id: eventId,
            streamName: stream,
            position: position,
            globalPosition: globalPosition,
            eventType: eventType,
            data: eventData,
            metadata: metadata,
            timestamp: timestamp
        )
    }

    private func extractId(from streamName: String, category: String) -> String? {
        let prefix = category + "-"
        if streamName.hasPrefix(prefix) && streamName.count > prefix.count {
            return String(streamName.dropFirst(prefix.count))
        }
        return nil
    }
}
