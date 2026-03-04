/// Configuration for DuckLake cold-tier storage.
///
/// DuckLake stores data as Parquet files, with a metadata catalog tracking
/// file locations and schema. The `catalogPath` is the DuckLake metadata
/// database, and `dataPath` is the directory where Parquet files are written.
///
/// ```swift
/// let config = DuckLakeConfig(
///     catalogPath: "/data/lake-catalog.duckdb",
///     dataPath: "/data/parquet/"
/// )
/// ```
public struct DuckLakeConfig: Sendable {
    /// Storage backend for Parquet data files.
    public enum Backend: String, Sendable {
        /// Local filesystem storage.
        case local
        // Future: case s3, gcs, azure
    }

    /// Path to the DuckLake metadata catalog database.
    public let catalogPath: String

    /// Directory path for Parquet data files.
    public let dataPath: String

    /// Storage backend (currently only local).
    public let backend: Backend

    /// Creates a DuckLake configuration.
    ///
    /// - Parameters:
    ///   - catalogPath: Path to the DuckLake metadata catalog database.
    ///   - dataPath: Directory for Parquet data files.
    ///   - backend: Storage backend (default: `.local`).
    public init(catalogPath: String, dataPath: String, backend: Backend = .local) {
        self.catalogPath = catalogPath
        self.dataPath = dataPath
        self.backend = backend
    }
}
