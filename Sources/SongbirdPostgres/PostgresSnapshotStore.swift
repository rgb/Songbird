import Foundation
import PostgresNIO
import Songbird

public struct PostgresSnapshotStore: SnapshotStore, Sendable {
    private let client: PostgresClient

    public init(client: PostgresClient) {
        self.client = client
    }

    public func saveData(
        _ data: Data,
        version: Int64,
        for stream: StreamName
    ) async throws {
        let streamStr = stream.description
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw PostgresStoreError.encodingFailed
        }
        try await client.query("""
            INSERT INTO snapshots (stream_name, state, version, updated_at)
            VALUES (\(streamStr), \(jsonString)::jsonb, \(version), NOW())
            ON CONFLICT (stream_name) DO UPDATE SET
                state = EXCLUDED.state,
                version = EXCLUDED.version,
                updated_at = NOW()
            """)
    }

    public func loadData(
        for stream: StreamName
    ) async throws -> (data: Data, version: Int64)? {
        let streamStr = stream.description
        let rows = try await client.query(
            "SELECT state::text, version FROM snapshots WHERE stream_name = \(streamStr) LIMIT 1"
        )
        for try await (stateStr, version) in rows.decode((String, Int64).self) {
            let data = Data(stateStr.utf8)
            return (data, version)
        }
        return nil
    }
}
