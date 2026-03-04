import Foundation
import Songbird

/// An in-memory snapshot store for testing. Stores snapshots in a dictionary
/// keyed by `StreamName`. Each entry holds raw data and the version.
public actor InMemorySnapshotStore: SnapshotStore {
    private var snapshots: [StreamName: (data: Data, version: Int64)] = [:]

    public init() {}

    public func saveData(
        _ data: Data,
        version: Int64,
        for stream: StreamName
    ) async throws {
        snapshots[stream] = (data, version)
    }

    public func loadData(
        for stream: StreamName
    ) async throws -> (data: Data, version: Int64)? {
        snapshots[stream]
    }
}
