import Foundation
import PostgresNIO
import Songbird

public struct PostgresPositionStore: PositionStore, Sendable {
    private let client: PostgresClient

    public init(client: PostgresClient) {
        self.client = client
    }

    public func load(subscriberId: String) async throws -> Int64? {
        let rows = try await client.query(
            "SELECT global_position FROM subscriber_positions WHERE subscriber_id = \(subscriberId)"
        )
        for try await (position,) in rows.decode((Int64,).self) {
            return position
        }
        return nil
    }

    public func save(subscriberId: String, globalPosition: Int64) async throws {
        try await client.query("""
            INSERT INTO subscriber_positions (subscriber_id, global_position, updated_at)
            VALUES (\(subscriberId), \(globalPosition), NOW())
            ON CONFLICT (subscriber_id) DO UPDATE SET
                global_position = EXCLUDED.global_position,
                updated_at = NOW()
            """)
    }
}
