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
    public enum Backend: Sendable {
        /// Local filesystem storage.
        case local
        /// S3-compatible object storage (AWS S3, rustfs, Garage, MinIO, R2).
        case s3(S3Config)
    }

    /// Path to the DuckLake metadata catalog database.
    public let catalogPath: String

    /// Directory path for Parquet data files.
    public let dataPath: String

    /// Storage backend.
    public let backend: Backend

    /// Schema name for the cold tier in DuckDB (default: "lake").
    public let schemaName: String

    /// Creates a DuckLake configuration.
    ///
    /// - Parameters:
    ///   - catalogPath: Path to the DuckLake metadata catalog database.
    ///   - dataPath: Directory for Parquet data files.
    ///   - backend: Storage backend (default: `.local`).
    ///   - schemaName: Schema name for the cold tier (default: `"lake"`).
    public init(
        catalogPath: String,
        dataPath: String,
        backend: Backend = .local,
        schemaName: String = "lake"
    ) {
        self.catalogPath = catalogPath
        self.dataPath = dataPath
        self.backend = backend
        self.schemaName = schemaName
    }
}
