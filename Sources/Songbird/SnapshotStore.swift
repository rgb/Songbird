import Foundation

/// A store for aggregate state snapshots, used to optimize loading of aggregates
/// with long event histories.
///
/// Snapshots are checkpoints of an aggregate's state at a known stream version.
/// When loading an aggregate, the repository checks for a snapshot first, then
/// folds only the events after the snapshot version — skipping the full replay.
///
/// Only the latest snapshot per stream is meaningful. Implementations may keep
/// history, but `load` always returns the most recent one.
///
/// Conformers implement `saveData` and `loadData`, which work with raw `Data`.
/// Callers use the typed `save(_:version:for:)` and `load(for:)` extension
/// methods, which handle JSON encoding/decoding of the aggregate state.
///
/// ```swift
/// // Save a snapshot after folding events
/// try await snapshotStore.save(state, version: 42, for: stream)
///
/// // Load the latest snapshot (returns nil if none exists)
/// if let snapshot: (MyAggregate.State, Int64) = try await snapshotStore.load(for: stream) {
///     // Resume folding from snapshot.version + 1
/// }
/// ```
public protocol SnapshotStore: Sendable {
    /// Saves raw snapshot data at the given stream version.
    ///
    /// Replaces any existing snapshot for the same stream. The `version` is the
    /// stream position of the last event folded into this state.
    func saveData(
        _ data: Data,
        version: Int64,
        for stream: StreamName
    ) async throws

    /// Loads the latest raw snapshot data for a stream.
    ///
    /// Returns `nil` if no snapshot exists. The returned `version` is the stream
    /// position of the last event that was folded into the state — the caller
    /// should read events from `version + 1` onward.
    func loadData(
        for stream: StreamName
    ) async throws -> (data: Data, version: Int64)?
}

extension SnapshotStore {
    /// Saves a snapshot of an aggregate's state at the given stream version.
    ///
    /// Encodes the state as JSON and delegates to `saveData`.
    public func save<State: Codable & Sendable>(
        _ state: State,
        version: Int64,
        for stream: StreamName
    ) async throws {
        let data = try JSONEncoder().encode(state)
        try await saveData(data, version: version, for: stream)
    }

    /// Loads the latest snapshot for an aggregate stream.
    ///
    /// Decodes the stored JSON data into the requested `State` type.
    /// Returns `nil` if no snapshot exists.
    public func load<State: Codable & Sendable>(
        for stream: StreamName
    ) async throws -> (state: State, version: Int64)? {
        guard let entry = try await loadData(for: stream) else { return nil }
        let state = try JSONDecoder().decode(State.self, from: entry.data)
        return (state, entry.version)
    }
}

/// Controls when the `AggregateRepository` automatically saves snapshots.
public enum SnapshotPolicy: Sendable, Equatable {
    /// No automatic snapshotting. Use `saveSnapshot(id:)` for explicit saves.
    case none
    /// Save a snapshot every N events since the last snapshot (or since the beginning).
    case everyNEvents(Int)
}
