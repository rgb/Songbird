import CryptoKit
import Foundation
import Songbird
import SQLite

public actor SQLiteEventStore: EventStore {
    nonisolated(unsafe) let db: Connection
    private let registry: EventTypeRegistry

    public init(path: String, registry: EventTypeRegistry) throws {
        if path == ":memory:" {
            self.db = try Connection(.inMemory)
        } else {
            self.db = try Connection(path)
        }
        self.registry = registry
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
        let tableExists = try db.scalar(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='schema_version'"
        ) as! Int64
        if tableExists == 0 { return 0 }
        return try Int(db.scalar("SELECT version FROM schema_version") as! Int64)
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

        // Optimistic concurrency check
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
        let iso8601 = ISO8601DateFormatter().string(from: now)
        let eventData = try JSONEncoder().encode(event)
        let eventDataString = String(data: eventData, encoding: .utf8)!
        let metadataData = try JSONEncoder().encode(metadata)
        let metadataString = String(data: metadataData, encoding: .utf8)!
        let eventType = type(of: event).eventType

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

        return RecordedEvent(
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

    // MARK: - Read Category

    public func readCategory(
        _ category: String,
        from globalPosition: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        let rows = try db.prepare("""
            SELECT global_position, stream_name, stream_category, position, event_type, data, metadata, event_id, timestamp
            FROM events
            WHERE stream_category = ? AND (global_position - 1) >= ?
            ORDER BY global_position ASC
            LIMIT ?
        """, category, globalPosition, maxCount)

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

    public func verifyChain(batchSize: Int = 1000) throws -> ChainVerificationResult {
        var previousHash = "genesis"
        var verified = 0
        var offset = 0

        while true {
            let rows = try db.prepare("""
                SELECT global_position, event_type, stream_name, data, timestamp, event_hash
                FROM events
                ORDER BY global_position ASC
                LIMIT ? OFFSET ?
            """, batchSize, offset)

            var batchCount = 0
            for row in rows {
                batchCount += 1
                let globalPos = row[0] as! Int64
                let eventType = row[1] as! String
                let streamName = row[2] as! String
                let data = row[3] as! String
                let timestamp = row[4] as! String
                let storedHash = row[5] as? String

                let hashInput = "\(previousHash)\0\(eventType)\0\(streamName)\0\(data)\0\(timestamp)"
                let computedHash = SHA256.hash(data: Data(hashInput.utf8))
                    .map { String(format: "%02x", $0) }
                    .joined()

                if let storedHash, storedHash != computedHash {
                    return ChainVerificationResult(
                        intact: false,
                        eventsVerified: verified,
                        brokenAtSequence: globalPos
                    )
                }

                previousHash = storedHash ?? computedHash
                verified += 1
            }

            if batchCount < batchSize { break }
            offset += batchSize
        }

        return ChainVerificationResult(intact: true, eventsVerified: verified)
    }

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
        let autoincPos = row[0] as! Int64
        let globalPosition = autoincPos - 1  // 0-based
        let streamStr = row[1] as! String
        let category = row[2] as! String
        let position = row[3] as! Int64
        let eventType = row[4] as! String
        let dataStr = row[5] as! String
        let metadataStr = row[6] as! String
        let eventIdStr = row[7] as! String
        let timestampStr = row[8] as! String

        let stream = StreamName(category: category, id: extractId(from: streamStr, category: category))
        let eventData = Data(dataStr.utf8)
        let metadata = try JSONDecoder().decode(EventMetadata.self, from: Data(metadataStr.utf8))
        let eventId = UUID(uuidString: eventIdStr)!
        let timestamp = ISO8601DateFormatter().date(from: timestampStr) ?? Date()

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
