import CryptoKit
import Foundation
import Logging
import PostgresNIO
import Songbird

public enum PostgresEventStoreError: Error {
    case encodingFailed
}

public struct PostgresEventStore: EventStore, Sendable {
    private let client: PostgresClient
    private let registry: EventTypeRegistry
    private let logger = Logger(label: "songbird.postgres")

    public init(client: PostgresClient, registry: EventTypeRegistry) {
        self.client = client
        self.registry = registry
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
        let eventType = event.eventType
        let eventId = UUID()
        let now = Date()

        let eventData = try JSONEncoder().encode(event)
        guard let eventDataString = String(data: eventData, encoding: .utf8) else {
            throw PostgresEventStoreError.encodingFailed
        }
        let metadataData = try JSONEncoder().encode(metadata)
        guard let metadataString = String(data: metadataData, encoding: .utf8) else {
            throw PostgresEventStoreError.encodingFailed
        }

        var globalPosition: Int64 = 0
        var position: Int64 = 0

        do {
            try await client.withTransaction(logger: logger) { connection in
                // Version check
                let currentVersion = try await self.currentStreamVersion(connection: connection, streamName: streamStr)
                if let expected = expectedVersion, expected != currentVersion {
                    throw VersionConflictError(
                        streamName: stream,
                        expectedVersion: expected,
                        actualVersion: currentVersion
                    )
                }

                position = currentVersion + 1

                // Hash chain: insert first, then compute hash from JSONB-normalized data
                let previousHash = try await self.lastEventHash(connection: connection) ?? "genesis"

                let insertRows = try await connection.query("""
                    INSERT INTO events (stream_name, stream_category, position, event_type, data, metadata, event_id, timestamp)
                    VALUES (\(streamStr), \(category), \(position), \(eventType), \(eventDataString)::jsonb, \(metadataString)::jsonb, \(eventId), \(now))
                    RETURNING global_position, data::text, to_char(timestamp AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                    """,
                    logger: logger
                )
                var normalizedData = ""
                var normalizedTimestamp = ""
                for try await (gp, dataText, ts) in insertRows.decode((Int64, String, String).self) {
                    globalPosition = gp - 1  // 0-based (BIGSERIAL starts at 1)
                    normalizedData = dataText
                    normalizedTimestamp = ts
                }

                let hashInput = "\(previousHash)\0\(eventType)\0\(streamStr)\0\(normalizedData)\0\(normalizedTimestamp)"
                let eventHash = SHA256.hash(data: Data(hashInput.utf8))
                    .map { String(format: "%02x", $0) }
                    .joined()

                try await connection.query(
                    "UPDATE events SET event_hash = \(eventHash) WHERE global_position = \(globalPosition + 1)",
                    logger: logger
                )

                // Notify listeners
                try await connection.query(
                    "SELECT pg_notify('songbird_events', \(String(globalPosition)))",
                    logger: logger
                )
            }
        } catch let txError as PostgresTransactionError {
            // Unwrap VersionConflictError from the transaction wrapper
            if let versionError = txError.closureError as? VersionConflictError {
                throw versionError
            }
            // Unique constraint violation on (stream_name, position) means a concurrent append
            if let psqlError = txError.closureError as? PSQLError,
               psqlError.serverInfo?[.sqlState] == "23505"
            {
                let actualVersion = try await currentStreamVersion(streamName: streamStr)
                throw VersionConflictError(
                    streamName: stream,
                    expectedVersion: expectedVersion ?? -1,
                    actualVersion: actualVersion
                )
            }
            throw txError
        } catch let error as PSQLError {
            if error.serverInfo?[.sqlState] == "23505" {
                let actualVersion = try await currentStreamVersion(streamName: streamStr)
                throw VersionConflictError(
                    streamName: stream,
                    expectedVersion: expectedVersion ?? -1,
                    actualVersion: actualVersion
                )
            }
            throw error
        }

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
        let streamStr = stream.description
        let rows = try await client.query("""
            SELECT global_position, stream_name, stream_category, position, event_type, data::text, metadata::text, event_id, timestamp
            FROM events
            WHERE stream_name = \(streamStr) AND position >= \(position)
            ORDER BY position ASC
            LIMIT \(maxCount)
            """)

        var results: [RecordedEvent] = []
        for try await (gp, sn, sc, pos, et, dataStr, metaStr, eid, ts)
            in rows.decode((Int64, String, String, Int64, String, String, String, UUID, Date).self)
        {
            results.append(try recordedEvent(
                globalPosition: gp, streamName: sn, streamCategory: sc,
                position: pos, eventType: et, dataStr: dataStr,
                metadataStr: metaStr, eventId: eid, timestamp: ts
            ))
        }
        return results
    }

    // MARK: - Read Categories

    public func readCategories(
        _ categories: [String],
        from globalPosition: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        let adjustedPosition = globalPosition + 1  // Convert 0-based to 1-based BIGSERIAL

        let rows: PostgresRowSequence
        if categories.isEmpty {
            rows = try await client.query("""
                SELECT global_position, stream_name, stream_category, position, event_type, data::text, metadata::text, event_id, timestamp
                FROM events
                WHERE global_position >= \(adjustedPosition)
                ORDER BY global_position ASC
                LIMIT \(maxCount)
                """)
        } else if categories.count == 1 {
            rows = try await client.query("""
                SELECT global_position, stream_name, stream_category, position, event_type, data::text, metadata::text, event_id, timestamp
                FROM events
                WHERE stream_category = \(categories[0]) AND global_position >= \(adjustedPosition)
                ORDER BY global_position ASC
                LIMIT \(maxCount)
                """)
        } else {
            rows = try await client.query("""
                SELECT global_position, stream_name, stream_category, position, event_type, data::text, metadata::text, event_id, timestamp
                FROM events
                WHERE stream_category = ANY(\(categories)) AND global_position >= \(adjustedPosition)
                ORDER BY global_position ASC
                LIMIT \(maxCount)
                """)
        }

        var results: [RecordedEvent] = []
        for try await (gp, sn, sc, pos, et, dataStr, metaStr, eid, ts)
            in rows.decode((Int64, String, String, Int64, String, String, String, UUID, Date).self)
        {
            results.append(try recordedEvent(
                globalPosition: gp, streamName: sn, streamCategory: sc,
                position: pos, eventType: et, dataStr: dataStr,
                metadataStr: metaStr, eventId: eid, timestamp: ts
            ))
        }
        return results
    }

    // MARK: - Read Last Event

    public func readLastEvent(
        in stream: StreamName
    ) async throws -> RecordedEvent? {
        let streamStr = stream.description
        let rows = try await client.query("""
            SELECT global_position, stream_name, stream_category, position, event_type, data::text, metadata::text, event_id, timestamp
            FROM events
            WHERE stream_name = \(streamStr)
            ORDER BY position DESC
            LIMIT 1
            """)

        for try await (gp, sn, sc, pos, et, dataStr, metaStr, eid, ts)
            in rows.decode((Int64, String, String, Int64, String, String, String, UUID, Date).self)
        {
            return try recordedEvent(
                globalPosition: gp, streamName: sn, streamCategory: sc,
                position: pos, eventType: et, dataStr: dataStr,
                metadataStr: metaStr, eventId: eid, timestamp: ts
            )
        }
        return nil
    }

    // MARK: - Stream Version

    public func streamVersion(
        _ stream: StreamName
    ) async throws -> Int64 {
        try await currentStreamVersion(streamName: stream.description)
    }

    // MARK: - Chain Verification

    public func verifyChain(batchSize: Int = 1000) async throws -> ChainVerificationResult {
        var previousHash = "genesis"
        var verified = 0
        var offset = 0

        while true {
            let rows = try await client.query("""
                SELECT global_position, event_type, stream_name, data::text, to_char(timestamp AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), event_hash
                FROM events
                ORDER BY global_position ASC
                LIMIT \(batchSize) OFFSET \(offset)
                """)

            var batchCount = 0
            for try await (globalPos, eventType, streamName, dataStr, timestamp, storedHash)
                in rows.decode((Int64, String, String, String, String, String?).self)
            {
                batchCount += 1

                let hashInput = "\(previousHash)\0\(eventType)\0\(streamName)\0\(dataStr)\0\(timestamp)"
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

            await Task.yield()
        }

        return ChainVerificationResult(intact: true, eventsVerified: verified)
    }

    // MARK: - Test Support

    /// Execute raw SQL. Intended for test scenarios (e.g., corrupting data to test chain verification).
    public func rawExecute(_ sql: String) async throws {
        try await client.query(PostgresQuery(unsafeSQL: sql))
    }

    // MARK: - Private Helpers

    private func currentStreamVersion(streamName: String) async throws -> Int64 {
        let rows = try await client.query(
            "SELECT MAX(position) FROM events WHERE stream_name = \(streamName)"
        )
        for try await (maxPos,) in rows.decode((Int64?,).self) {
            if let maxPos { return maxPos }
        }
        return -1
    }

    private func currentStreamVersion(connection: PostgresConnection, streamName: String) async throws -> Int64 {
        let rows = try await connection.query(
            "SELECT MAX(position) FROM events WHERE stream_name = \(streamName)",
            logger: logger
        )
        for try await (maxPos,) in rows.decode((Int64?,).self) {
            if let maxPos { return maxPos }
        }
        return -1
    }

    private func lastEventHash(connection: PostgresConnection) async throws -> String? {
        let rows = try await connection.query(
            "SELECT event_hash FROM events ORDER BY global_position DESC LIMIT 1",
            logger: logger
        )
        for try await (hash,) in rows.decode((String?,).self) {
            return hash
        }
        return nil
    }

    private func recordedEvent(
        globalPosition gp: Int64,
        streamName sn: String,
        streamCategory sc: String,
        position: Int64,
        eventType: String,
        dataStr: String,
        metadataStr: String,
        eventId: UUID,
        timestamp: Date
    ) throws -> RecordedEvent {
        let stream = StreamName(category: sc, id: extractId(from: sn, category: sc))
        let eventData = Data(dataStr.utf8)
        let metadata = try JSONDecoder().decode(EventMetadata.self, from: Data(metadataStr.utf8))

        return RecordedEvent(
            id: eventId,
            streamName: stream,
            position: position,
            globalPosition: gp - 1,  // 0-based (BIGSERIAL starts at 1)
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
