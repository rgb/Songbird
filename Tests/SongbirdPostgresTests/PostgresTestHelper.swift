import Foundation
import Logging
import PostgresNIO
import TestContainers
@testable import SongbirdPostgres

/// Manages a Postgres test container that starts lazily on first use and lives for the process duration.
private actor ContainerState {
    private var host: String?
    private var port: Int?
    private var started = false
    private var migrated = false

    func ensureStarted() async throws {
        guard !started else { return }

        let (stream, continuation) = AsyncStream<(String, Int)>.makeStream()

        // Launch container in a detached task — lives for the process duration.
        // withPostgresContainer handles cleanup when the task is cancelled at process exit.
        Task.detached {
            let postgres = PostgresContainer()
                .withDatabase("songbird_test")
                .withUsername("songbird")
                .withPassword("songbird")
            try await withPostgresContainer(postgres) { container in
                let mappedPort = try await container.port()
                let mappedHost = container.host()
                continuation.yield((mappedHost, mappedPort))
                continuation.finish()
                // Keep the container alive until the process exits
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(3600))
                }
            }
        }

        // Wait for connection info from the container
        for await (h, p) in stream {
            self.host = h
            self.port = p
            break
        }
        started = true
    }

    func ensureMigrated() async throws {
        guard !migrated else { return }
        let config = makeConfiguration()
        let logger = Logger(label: "songbird.test.migrations")
        let client = PostgresClient(configuration: config)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            try await SongbirdPostgresMigrations.apply(client: client, logger: logger)
            group.cancelAll()
        }
        migrated = true
    }

    func makeConfiguration() -> PostgresClient.Configuration {
        guard let host, let port else {
            fatalError("Container not started — call ensureStarted() first")
        }
        return PostgresClient.Configuration(
            host: host, port: port,
            username: "songbird", password: "songbird",
            database: "songbird_test", tls: .disable
        )
    }
}

enum PostgresTestHelper {
    private static let containerState = ContainerState()

    /// Runs a test block with a connected PostgresClient backed by a Docker container.
    /// The container starts lazily on first call and is reused across all tests.
    /// Migrations are applied once.
    static func withTestClient(
        _ body: @Sendable (PostgresClient) async throws -> Void
    ) async throws {
        try await containerState.ensureStarted()
        try await containerState.ensureMigrated()

        let config = await containerState.makeConfiguration()
        let client = PostgresClient(configuration: config)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            try await body(client)
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
