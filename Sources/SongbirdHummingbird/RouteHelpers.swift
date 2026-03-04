import Songbird

/// Appends a single event to the event store and enqueues it to the projection pipeline.
///
/// This is the fundamental write operation for Songbird route handlers. It atomically persists
/// the event (with optimistic concurrency control via `expectedVersion`) and then hands it to
/// the projection pipeline for asynchronous read-model updates.
///
/// - Parameters:
///   - event: The domain event to append.
///   - stream: The target stream name.
///   - metadata: Event metadata (trace ID, causation, etc.).
///   - expectedVersion: Optional optimistic concurrency check. Pass `nil` to skip.
///   - services: The `SongbirdServices` container.
/// - Returns: The `RecordedEvent` as persisted by the store.
@discardableResult
public func appendAndProject(
    _ event: some Event,
    to stream: StreamName,
    metadata: EventMetadata,
    expectedVersion: Int64? = nil,
    services: SongbirdServices
) async throws -> RecordedEvent {
    let recorded = try await services.eventStore.append(
        event,
        to: stream,
        metadata: metadata,
        expectedVersion: expectedVersion
    )
    await services.projectionPipeline.enqueue(recorded)
    return recorded
}
