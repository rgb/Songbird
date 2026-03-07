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
    private let database: Database

    /// The underlying DuckDB connection. Marked `nonisolated(unsafe)` because all access
    /// is serialized through this actor's custom `DispatchSerialQueue` executor.
    nonisolated(unsafe) private let connection: Connection

    private let executor: DispatchSerialQueue

    /// The storage mode for this read model store.
    public let storageMode: StorageMode

    private var isTiered: Bool

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    /// Creates a new read model store.
    ///
    /// - Parameters:
    ///   - path: File path for persistent storage. Pass `nil` (default) for
    ///     an in-memory database, suitable for testing.
    ///   - storageMode: Storage mode (default: `.duckdb`). Use `.tiered` for
    ///     hot/cold DuckLake/Parquet archival.
    public init(path: String? = nil, storageMode: StorageMode = .duckdb) throws {
        self.executor = DispatchSerialQueue(label: "songbird.read-model-store")
        self.storageMode = storageMode
        self.isTiered = storageMode.isTiered
        if case .tiered(let config) = storageMode {
            self.coldSchemaName = config.schemaName
        } else {
            self.coldSchemaName = DuckLakeDefaults.schemaName
        }
        if let path {
            self.database = try Database(store: .file(at: URL(fileURLWithPath: path)))
        } else {
            self.database = try Database(store: .inMemory)
        }
        self.connection = try database.connect()
        if case .tiered(let config) = storageMode {
            try Self.attachDuckLake(
                connection: connection, config: config, schemaName: coldSchemaName
            )
        }
    }

    /// The DuckDB schema name for the cold tier.
    let coldSchemaName: String

    private static func attachDuckLake(
        connection: Connection, config: DuckLakeConfig, schemaName: String
    ) throws {
        try connection.execute("INSTALL ducklake")
        try connection.execute("LOAD ducklake")
        if case .s3(let s3Config) = config.backend {
            try configureS3(connection: connection, s3Config: s3Config)
        }
        let catalogPath = escapeSQLString(config.catalogPath)
        let dataPath = escapeSQLString(config.dataPath)
        let escapedSchema = escapeSQLIdentifier(schemaName)
        try connection.execute(
            "ATTACH 'ducklake:\(catalogPath)' AS \"\(escapedSchema)\" (DATA_PATH '\(dataPath)')"
        )
    }

    /// Installs the `httpfs` extension and configures DuckDB S3 settings.
    ///
    /// Only non-nil fields in the `S3Config` are set; omitted fields fall back
    /// to DuckDB defaults (typically AWS environment variables).
    ///
    /// - Parameters:
    ///   - connection: The DuckDB connection to configure.
    ///   - s3Config: S3 configuration with optional overrides.
    static func configureS3(connection: Connection, s3Config: S3Config) throws {
        try connection.execute("INSTALL httpfs")
        try connection.execute("LOAD httpfs")

        if let region = s3Config.region {
            try connection.execute("SET s3_region = '\(escapeSQLString(region))'")
        }
        if let accessKeyId = s3Config.accessKeyId {
            try connection.execute("SET s3_access_key_id = '\(escapeSQLString(accessKeyId))'")
        }
        if let secretAccessKey = s3Config.secretAccessKey {
            try connection.execute("SET s3_secret_access_key = '\(escapeSQLString(secretAccessKey))'")
        }
        if let endpoint = s3Config.endpoint {
            try connection.execute("SET s3_endpoint = '\(escapeSQLString(endpoint))'")
            try connection.execute("SET s3_url_style = 'path'")
        }
        if !s3Config.useSsl {
            try connection.execute("SET s3_use_ssl = false")
        }
    }

    /// Enables tiered mode for testing without requiring DuckLake.
    /// Call after attaching an in-memory database using the store's `coldSchemaName` via:
    /// `try store.withConnection { conn in try conn.execute("ATTACH ':memory:' AS \(store.coldSchemaName)") }`
    func enableTieredModeForTesting() {
        isTiered = true
    }

    // MARK: - Migrations

    private var migrations: [Migration] = []

    // MARK: - Table Registration

    private var _registeredTables: [String] = []

    /// The list of table names registered for tiered storage management.
    public var registeredTables: [String] { _registeredTables }

    /// Registers a table name for tiered storage management.
    ///
    /// In tiered mode, registered tables get cold-tier mirrors and UNION ALL views
    /// created during `migrate()`. Call this before `migrate()` for each table
    /// that should participate in tiering.
    ///
    /// In `.duckdb` mode, this is a no-op for cold-tier setup but still tracks
    /// the table name, allowing projectors to be written mode-agnostically.
    public func registerTable(_ name: String) {
        guard !_registeredTables.contains(name) else { return }
        _registeredTables.append(name)
    }

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

        if isTiered {
            try createColdTierMirrors()
        }
    }

    /// Creates cold-tier mirror tables and UNION ALL views for each registered table.
    ///
    /// For each registered table, creates an empty mirror in the cold schema with
    /// identical column structure, then creates a view (`v_<table>`) that spans
    /// both the hot and cold tiers via `UNION ALL`.
    private func createColdTierMirrors() throws {
        let escapedSchema = escapeSQLIdentifier(coldSchemaName)
        for table in _registeredTables {
            let escapedTable = escapeSQLIdentifier(table)
            let escapedViewName = escapeSQLIdentifier("v_\(table)")
            // Create cold-tier mirror with identical schema (empty)
            try connection.execute(
                "CREATE TABLE IF NOT EXISTS \"\(escapedSchema)\".\"\(escapedTable)\" AS SELECT * FROM \"\(escapedTable)\" WHERE FALSE"
            )
            // Create UNION ALL view spanning both tiers
            try connection.execute(
                "CREATE OR REPLACE VIEW \"\(escapedViewName)\" AS SELECT * FROM \"\(escapedTable)\" UNION ALL SELECT * FROM \"\(escapedSchema)\".\"\(escapedTable)\""
            )
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

// MARK: - Tiering

extension ReadModelStore {
    /// Moves old projection rows from the hot tier to the cold tier.
    ///
    /// For each registered table, rows with `recorded_at` older than `thresholdDays`
    /// are copied to the cold tier (DuckLake/Parquet) and deleted from the hot tier.
    ///
    /// Returns 0 immediately in `.duckdb` mode.
    ///
    /// - Parameter thresholdDays: Rows older than this many days are moved.
    /// - Returns: Total number of rows moved across all registered tables.
    @discardableResult
    public func tierProjections(olderThan thresholdDays: Int) throws -> Int {
        guard isTiered else { return 0 }

        guard thresholdDays > 0 else { return 0 }

        let whereClause = "\"recorded_at\" < CURRENT_TIMESTAMP::TIMESTAMP - INTERVAL '\(thresholdDays) days'"
        var totalMoved = 0
        let escapedSchema = escapeSQLIdentifier(coldSchemaName)

        for table in _registeredTables {
            let escapedTable = escapeSQLIdentifier(table)
            let hotTable = "\"\(escapedTable)\""
            let coldTable = "\"\(escapedSchema)\".\"\(escapedTable)\""

            let countResult = try connection.query(
                "SELECT COUNT(*) FROM \(hotTable) WHERE \(whereClause)"
            )
            let moveCount = Int(countResult.scalarInt64() ?? 0)
            guard moveCount > 0 else { continue }

            // INSERT and DELETE are not wrapped in a single transaction because DuckDB
            // does not support cross-database transactions (hot and cold are separate
            // attached databases). If the process crashes between INSERT and DELETE,
            // the UNION ALL view will show duplicate rows. These duplicates persist
            // until a manual cleanup is performed (e.g., DROP and re-tier). For most
            // read-model use cases, duplicates are tolerable since projections are
            // rebuildable. Consider adding deduplication if exact-once matters.
            try connection.execute(
                "INSERT INTO \(coldTable) SELECT * FROM \(hotTable) WHERE \(whereClause)"
            )
            try connection.execute(
                "DELETE FROM \(hotTable) WHERE \(whereClause)"
            )

            totalMoved += moveCount
        }

        return totalMoved
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
            try Task.checkCancellation()
            let batch = try await store.readAll(from: position, maxCount: batchSize)
            guard !batch.isEmpty else { break }
            for record in batch {
                for projector in projectors {
                    try await projector.apply(record)
                }
            }
            guard let lastEvent = batch.last else { break }
            position = lastEvent.globalPosition + 1
        }
    }
}
