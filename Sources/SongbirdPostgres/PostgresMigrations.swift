import Logging
import PostgresMigrations
import PostgresNIO

/// Registers and applies Songbird database migrations for PostgreSQL.
///
/// Usage:
/// ```swift
/// try await SongbirdPostgresMigrations.apply(client: client, logger: logger)
/// ```
public enum SongbirdPostgresMigrations {
    /// Applies all Songbird migrations to the database.
    public static func apply(client: PostgresClient, logger: Logger) async throws {
        let migrations = DatabaseMigrations()
        await register(in: migrations)
        try await migrations.apply(client: client, logger: logger, dryRun: false)
    }

    /// Registers all Songbird migrations without applying them.
    /// Useful if the caller wants to combine Songbird migrations with application-specific ones.
    public static func register(in migrations: DatabaseMigrations) async {
        await migrations.add(CreateEventsTables())
    }
}

struct CreateEventsTables: DatabaseMigration {
    func apply(connection: PostgresConnection, logger: Logger) async throws {
        try await connection.query("""
            CREATE TABLE IF NOT EXISTS events (
                global_position  BIGSERIAL PRIMARY KEY,
                stream_name      TEXT NOT NULL,
                stream_category  TEXT NOT NULL,
                position         BIGINT NOT NULL,
                event_type       TEXT NOT NULL,
                data             JSONB NOT NULL,
                metadata         JSONB NOT NULL,
                event_id         UUID NOT NULL UNIQUE,
                timestamp        TIMESTAMPTZ NOT NULL,
                event_hash       TEXT,

                UNIQUE (stream_name, position)
            )
            """,
            logger: logger
        )
        try await connection.query(
            "CREATE INDEX IF NOT EXISTS idx_events_stream ON events(stream_name, position)",
            logger: logger
        )
        try await connection.query(
            "CREATE INDEX IF NOT EXISTS idx_events_category ON events(stream_category, global_position)",
            logger: logger
        )
        try await connection.query("""
            CREATE TABLE IF NOT EXISTS subscriber_positions (
                subscriber_id    TEXT PRIMARY KEY,
                global_position  BIGINT NOT NULL,
                updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
            """,
            logger: logger
        )
        try await connection.query("""
            CREATE TABLE IF NOT EXISTS snapshots (
                stream_name  TEXT PRIMARY KEY,
                state        JSONB NOT NULL,
                version      BIGINT NOT NULL,
                updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
            """,
            logger: logger
        )
    }

    func revert(connection: PostgresConnection, logger: Logger) async throws {
        try await connection.query("DROP TABLE IF EXISTS snapshots", logger: logger)
        try await connection.query("DROP TABLE IF EXISTS subscriber_positions", logger: logger)
        try await connection.query("DROP TABLE IF EXISTS events", logger: logger)
    }

    var name: String { "CreateEventsTables" }
    var group: DatabaseMigrationGroup { .default }
}
