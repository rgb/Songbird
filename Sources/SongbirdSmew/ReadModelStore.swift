@_exported import Smew
import Dispatch
import Foundation
import Songbird

/// A migration closure that receives a DuckDB `Connection` and creates or
/// modifies read model tables.
public typealias Migration = @Sendable (Connection) throws -> Void

/// A DuckDB-backed read model store for materialized projections.
///
/// Owns a Smew `Database` and `Connection`, serializing all access through a
/// custom executor. Projectors hold a reference to the store and use
/// `withConnection` for writes, while route handlers use the query helpers
/// for reads.
///
/// ```swift
/// let readModel = try ReadModelStore()
/// try await readModel.withConnection { conn in
///     try conn.execute("INSERT INTO orders ...")
/// }
/// let orders: [Order] = try await readModel.query(Order.self) {
///     "SELECT * FROM orders WHERE status = \(param: "active")"
/// }
/// ```
public actor ReadModelStore {
    public let database: Database

    /// The underlying DuckDB connection. All access is serialized through this
    /// actor's custom `DispatchSerialQueue` executor.
    let connection: Connection

    private let executor: DispatchSerialQueue

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    /// Creates a new read model store.
    ///
    /// - Parameter path: File path for persistent storage. Pass `nil` (default) for
    ///   an in-memory database, suitable for testing.
    public init(path: String? = nil) throws {
        self.executor = DispatchSerialQueue(label: "songbird.read-model-store")
        if let path {
            self.database = try Database(store: .file(at: URL(fileURLWithPath: path)))
        } else {
            self.database = try Database(store: .inMemory)
        }
        self.connection = try database.connect()
    }

    // MARK: - Migrations

    private var migrations: [Migration] = []

    /// Registers a migration to run during `migrate()`.
    ///
    /// Migrations execute in registration order. Each migration receives the
    /// underlying DuckDB `Connection` and should create/alter tables as needed.
    /// Since read models are rebuildable from events, destructive operations
    /// (DROP + CREATE) are safe.
    public func registerMigration(_ migration: @escaping Migration) {
        migrations.append(migration)
    }

    /// Runs all pending migrations.
    ///
    /// Tracks the current schema version in a `schema_version` table. Each
    /// migration runs in a transaction with its version bump, ensuring atomicity.
    /// Call once at startup after registering all migrations.
    public func migrate() throws {
        try ensureSchemaVersionTable()
        let currentVersion = try schemaVersion()
        for (index, migration) in migrations.enumerated() {
            let version = index + 1
            if version > currentVersion {
                try connection.withTransaction {
                    try migration(connection)
                    try connection.execute(
                        "UPDATE schema_version SET version = \(param: Int64(version))"
                    )
                }
            }
        }
    }

    private func ensureSchemaVersionTable() throws {
        try connection.execute(
            "CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)"
        )
        let count = try connection.query("SELECT COUNT(*) FROM schema_version").scalarInt64() ?? 0
        if count == 0 {
            try connection.execute("INSERT INTO schema_version VALUES (0)")
        }
    }

    private func schemaVersion() throws -> Int {
        Int(try connection.query("SELECT version FROM schema_version").scalarInt64() ?? 0)
    }

    // MARK: - Connection Access

    /// Provides direct access to the underlying Smew `Connection`.
    ///
    /// Use this for raw SQL execution, `Appender`-based bulk inserts, or any
    /// operation not covered by the query helpers.
    public func withConnection<T: Sendable>(
        _ body: (Connection) throws -> T
    ) throws -> T {
        try body(connection)
    }
}

private let snakeCaseDecoder = RowDecoder(keyDecodingStrategy: .convertFromSnakeCase)

// MARK: - Query Helpers

extension ReadModelStore {
    /// Executes a query built with `@QueryBuilder` and decodes all rows.
    ///
    /// Uses `RowDecoder(.convertFromSnakeCase)` so DuckDB `snake_case` columns
    /// map automatically to Swift `camelCase` properties.
    public func query<T: Decodable>(
        _ type: T.Type,
        @QueryBuilder _ build: () -> QueryFragment
    ) throws -> [T] {
        try connection.query(build).decode(type, using: snakeCaseDecoder)
    }

    /// Executes a query and decodes the first row, or returns `nil`.
    public func queryFirst<T: Decodable>(
        _ type: T.Type,
        @QueryBuilder _ build: () -> QueryFragment
    ) throws -> T? {
        try connection.query(build).decodeFirst(type, using: snakeCaseDecoder)
    }
}

// MARK: - Rebuild

extension ReadModelStore {
    /// Rebuilds the read model by replaying all events from the store.
    ///
    /// Reads events in batches by global position and applies each to every
    /// projector. Projectors that need bulk performance can use `Appender`
    /// internally via their reference to this store's `withConnection`.
    ///
    /// - Parameters:
    ///   - store: The event store to read from.
    ///   - projectors: The projectors to apply events to.
    ///   - batchSize: Number of events to read per batch (default 1000).
    public func rebuild(
        from store: any EventStore,
        projectors: [any Projector],
        batchSize: Int = 1000
    ) async throws {
        var position: Int64 = 0
        while true {
            let batch = try await store.readAll(from: position, maxCount: batchSize)
            guard !batch.isEmpty else { break }
            for record in batch {
                for projector in projectors {
                    try await projector.apply(record)
                }
            }
            position = batch.last!.globalPosition + 1
        }
    }
}
