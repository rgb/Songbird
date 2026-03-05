/// Configuration for S3-compatible object storage backends.
///
/// All fields are optional. When `nil`, DuckDB falls back to its defaults,
/// which typically read from standard AWS environment variables
/// (`AWS_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`).
///
/// Set `endpoint` for S3-compatible stores like MinIO, Garage, rustfs, or
/// Cloudflare R2.
///
/// ```swift
/// let s3 = S3Config(
///     region: "us-east-1",
///     endpoint: "localhost:9000",
///     useSsl: false
/// )
/// let config = DuckLakeConfig(
///     catalogPath: "s3://bucket/catalog.duckdb",
///     dataPath: "s3://bucket/parquet/",
///     backend: .s3(s3)
/// )
/// ```
public struct S3Config: Sendable {
    /// AWS region (e.g. `"us-east-1"`). When `nil`, uses the `AWS_REGION`
    /// environment variable.
    public let region: String?

    /// AWS access key ID. When `nil`, uses the `AWS_ACCESS_KEY_ID`
    /// environment variable.
    public let accessKeyId: String?

    /// AWS secret access key. When `nil`, uses the `AWS_SECRET_ACCESS_KEY`
    /// environment variable.
    public let secretAccessKey: String?

    /// Custom endpoint for S3-compatible stores (e.g. `"localhost:9000"`).
    /// When `nil`, uses the default AWS S3 endpoint.
    public let endpoint: String?

    /// Whether to use SSL/TLS for connections. Defaults to `true`.
    public let useSsl: Bool

    /// Creates an S3 configuration.
    ///
    /// - Parameters:
    ///   - region: AWS region. `nil` defers to `AWS_REGION` env var.
    ///   - accessKeyId: Access key ID. `nil` defers to `AWS_ACCESS_KEY_ID` env var.
    ///   - secretAccessKey: Secret access key. `nil` defers to `AWS_SECRET_ACCESS_KEY` env var.
    ///   - endpoint: Custom S3-compatible endpoint. `nil` uses default AWS.
    ///   - useSsl: Use SSL/TLS (default: `true`).
    public init(
        region: String? = nil,
        accessKeyId: String? = nil,
        secretAccessKey: String? = nil,
        endpoint: String? = nil,
        useSsl: Bool = true
    ) {
        self.region = region
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.endpoint = endpoint
        self.useSsl = useSsl
    }
}
