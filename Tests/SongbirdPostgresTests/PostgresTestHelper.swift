import Foundation
import Logging
import PostgresNIO
@testable import SongbirdPostgres

enum PostgresTestHelper {
    /// Default test configuration — connects to localhost:5432 with songbird/songbird credentials.
    /// Override via environment variables: POSTGRES_HOST, POSTGRES_PORT, POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB.
    static func makeConfiguration(database: String? = nil) -> PostgresClient.Configuration {
        let host = ProcessInfo.processInfo.environment["POSTGRES_HOST"] ?? "localhost"
        let port = Int(ProcessInfo.processInfo.environment["POSTGRES_PORT"] ?? "5432") ?? 5432
        let username = ProcessInfo.processInfo.environment["POSTGRES_USER"] ?? "songbird"
        let password = ProcessInfo.processInfo.environment["POSTGRES_PASSWORD"] ?? "songbird"
        let db = database ?? ProcessInfo.processInfo.environment["POSTGRES_DB"] ?? "songbird_test"
        return PostgresClient.Configuration(
            host: host, port: port,
            username: username, password: password,
            database: db, tls: .disable
        )
    }

    /// Runs a test block with a connected PostgresClient that has migrations applied.
    /// The client is started in a background task and cancelled after the block completes.
    static func withTestClient(
        _ body: @Sendable (PostgresClient) async throws -> Void
    ) async throws {
        let logger = Logger(label: "songbird.test")
        let config = makeConfiguration()
        let client = PostgresClient(configuration: config)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }

            // Run migrations before test code
            try await SongbirdPostgresMigrations.apply(client: client, logger: logger)

            // Run the test body
            try await body(client)

            // Cancel the client task
            group.cancelAll()
        }
    }

    /// Cleans all Songbird tables (events, subscriber_positions, snapshots) for test isolation.
    /// Call this at the start of each test to ensure a clean state.
    static func cleanTables(client: PostgresClient) async throws {
        try await client.query("TRUNCATE events RESTART IDENTITY CASCADE")
        try await client.query("TRUNCATE subscriber_positions")
        try await client.query("TRUNCATE snapshots")
    }
}
