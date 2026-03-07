import Logging

/// Background service that periodically migrates old projection rows from the
/// hot tier (DuckDB native) to the cold tier (DuckLake/Parquet).
///
/// Usage:
/// ```swift
/// let tiering = TieringService(readModel: store, thresholdDays: 30)
/// let task = Task { await tiering.run() }
/// // ... on shutdown:
/// await tiering.stop()
/// task.cancel()
/// ```
public actor TieringService {
    private let logger = Logger(label: "songbird.tiering-service")
    private let readModel: ReadModelStore
    private let thresholdDays: Int
    private let interval: Duration
    private var isRunning = false

    /// Creates a tiering service.
    ///
    /// - Parameters:
    ///   - readModel: The read model store to tier.
    ///   - thresholdDays: Rows older than this are moved to cold tier (default: 30).
    ///   - interval: Time between tiering passes (default: 1 hour).
    public init(
        readModel: ReadModelStore,
        thresholdDays: Int = 30,
        interval: Duration = .seconds(3600)
    ) {
        self.readModel = readModel
        self.thresholdDays = thresholdDays
        self.interval = interval
    }

    /// Runs the tiering loop until `stop()` is called or the task is cancelled.
    public func run() async {
        isRunning = true
        while isRunning && !Task.isCancelled {
            do {
                try await readModel.tierProjections(olderThan: thresholdDays)
            } catch {
                logger.warning("Tiering pass failed", metadata: ["error": "\(error)"])
            }
            do {
                try await Task.sleep(for: interval)
            } catch {
                break  // Cancelled during sleep — exit gracefully
            }
        }
    }

    /// Stops the tiering loop.
    public func stop() {
        isRunning = false
    }

    /// Runs a single tiering pass. Useful for CLI tools and testing.
    ///
    /// - Returns: Number of rows moved from hot to cold tier.
    @discardableResult
    public func tierOnce() async throws -> Int {
        try await readModel.tierProjections(olderThan: thresholdDays)
    }
}
