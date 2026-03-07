import CryptoKit
import Foundation
import Logging
import PostgresNIO
import Songbird

public enum PostgresStoreError: Error {
    case encodingFailed
    case corruptedTimestamp(String)
    case corruptedData(String)
    case keyNotFoundAfterInsert(reference: String, layer: String)
}

/// Default values for PostgreSQL event store configuration.
public enum PostgresDefaults {
    /// The default PostgreSQL NOTIFY channel used for event notifications.
    public static let notifyChannel = "songbird_events"

    /// The default fallback poll interval for LISTEN/NOTIFY-based subscriptions.
    public static let fallbackPollInterval: Duration = .seconds(5)
}

public struct PostgresEventStore: EventStore, Sendable {
    private let client: PostgresClient
    private let logger = Logger(label: "songbird.postgres")
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()
    public let notifyChannel: String

    public init(client: PostgresClient, notifyChannel: String = PostgresDefaults.notifyChannel) {
        self.client = client
        self.notifyChannel = notifyChannel
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

        let eventData = try jsonEncoder.encode(event)
        guard let eventDataString = String(data: eventData, encoding: .utf8) else {
            throw PostgresStoreError.encodingFailed
        }
        let metadataData = try jsonEncoder.encode(metadata)
        guard let metadataString = String(data: metadataData, encoding: .utf8) else {
            throw PostgresStoreError.encodingFailed
        }

        var globalPosition: Int64 = 0
        var position: Int64 = 0
        var normalizedTimestamp = ""

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
                let previousHash = try await self.lastEventHash(connection: connection) ?? HashChain.genesisSeed

                let insertRows = try await connection.query("""
                    INSERT INTO events (stream_name, stream_category, position, event_type, data, metadata, event_id, timestamp)
                    VALUES (\(streamStr), \(category), \(position), \(eventType), \(eventDataString)::jsonb, \(metadataString)::jsonb, \(eventId), \(now))
                    RETURNING global_position, data::text, to_char(timestamp AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                    """,
                    logger: logger
                )
                var normalizedData = ""
                for try await (gp, dataText, ts) in insertRows.decode((Int64, String, String).self) {
                    globalPosition = gp - 1  // 0-based (BIGSERIAL starts at 1)
                    normalizedData = dataText
                    normalizedTimestamp = ts
                }

                guard !normalizedData.isEmpty else {
                    throw PostgresStoreError.corruptedData(
                        "INSERT RETURNING returned no rows for stream '\(streamStr)'"
                    )
                }

                let eventHash = Self.computeEventHash(
                    previousHash: previousHash, eventType: eventType,
                    streamName: streamStr, data: normalizedData, timestamp: normalizedTimestamp
                )

                try await connection.query(
                    "UPDATE events SET event_hash = \(eventHash) WHERE global_position = \(globalPosition + 1)",
                    logger: logger
                )

                // Notify listeners
                let channel = self.notifyChannel
                try await connection.query(
                    "SELECT pg_notify(\(channel), \(String(globalPosition)))",
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

        guard let returnedTimestamp = try? Date(normalizedTimestamp, strategy: .iso8601) else {
            throw PostgresStoreError.corruptedTimestamp(normalizedTimestamp)
        }

        return RecordedEvent(
            id: eventId,
            streamName: stream,
            position: position,
            globalPosition: globalPosition,
            eventType: eventType,
            data: eventData,
            metadata: metadata,
            timestamp: returnedTimestamp
        )
    }

    // MARK: - Read Stream

    public func readStream(
        _ stream: StreamName,
        from position: Int64,
        maxCount: Int
    ) async throws -> [RecordedEvent] {
        precondition(maxCount > 0, "maxCount must be positive")
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
        precondition(maxCount > 0, "maxCount must be positive")
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
        precondition(batchSize > 0, "batchSize must be positive")
        var previousHash = HashChain.genesisSeed
        var verified = 0
        var lastGlobalPosition: Int64 = 0  // BIGSERIAL starts at 1, so 0 means "before first"

        while true {
            try Task.checkCancellation()
            let rows = try await client.query("""
                SELECT global_position, event_type, stream_name, data::text, to_char(timestamp AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), event_hash
                FROM events
                WHERE global_position > \(lastGlobalPosition)
                ORDER BY global_position ASC
                LIMIT \(batchSize)
                """)

            var batchCount = 0
            for try await (globalPos, eventType, streamName, dataStr, timestamp, storedHash)
                in rows.decode((Int64, String, String, String, String, String?).self)
            {
                batchCount += 1
                lastGlobalPosition = globalPos

                let computedHash = Self.computeEventHash(
                    previousHash: previousHash, eventType: eventType,
                    streamName: streamName, data: dataStr, timestamp: timestamp
                )

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
            await Task.yield()
        }

        return ChainVerificationResult(intact: true, eventsVerified: verified)
    }

    // MARK: - Test Support

    #if DEBUG
    /// Execute raw SQL. **Test-only** — used for scenarios like corrupting data
    /// to test chain verification. Not available in release builds.
    public func rawExecute(_ sql: String) async throws {
        try await client.query(PostgresQuery(unsafeSQL: sql))
    }
    #endif

    // MARK: - Private Helpers

    private static func computeEventHash(
        previousHash: String, eventType: String,
        streamName: String, data: String, timestamp: String
    ) -> String {
        let hashInput = "\(previousHash)\0\(eventType)\0\(streamName)\0\(data)\0\(timestamp)"
        return SHA256.hash(data: Data(hashInput.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

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
        let metadata = try jsonDecoder.decode(EventMetadata.self, from: Data(metadataStr.utf8))

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
