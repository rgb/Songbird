@_exported import Smew
import Dispatch
import Foundation
import Songbird

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
