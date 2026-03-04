/// Controls how the read model store manages projection data.
///
/// - `duckdb`: All data stays in native DuckDB (default, current behavior).
/// - `tiered`: Hot DuckDB for recent data + cold DuckLake/Parquet for historical data.
public enum StorageMode: Sendable {
    /// Native DuckDB file storage (default). No tiering.
    case duckdb
    /// Hot DuckDB + Cold DuckLake/Parquet tiered storage.
    case tiered(DuckLakeConfig)
}

extension StorageMode {
    /// Whether this mode uses tiered storage.
    var isTiered: Bool {
        if case .tiered = self { return true }
        return false
    }
}
