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

/// Executes a command via an `AggregateRepository` and enqueues all resulting events
/// to the projection pipeline.
///
/// This is the command-handling write operation for Songbird route handlers. It loads the
/// aggregate, validates and executes the command (with optimistic concurrency), then hands
/// the resulting events to the projection pipeline.
///
/// - Parameters:
///   - command: The command to execute.
///   - id: The aggregate entity ID.
///   - metadata: Event metadata (trace ID, causation, etc.).
///   - handler: The `CommandHandler` type that validates and produces events.
///   - repository: The aggregate repository to load state and append events.
///   - services: The `SongbirdServices` container.
/// - Returns: The recorded events as persisted by the store.
@discardableResult
public func executeAndProject<H: CommandHandler>(
    _ command: H.Cmd,
    on id: String,
    metadata: EventMetadata,
    using handler: H.Type,
    repository: AggregateRepository<H.Agg>,
    services: SongbirdServices
) async throws -> [RecordedEvent] {
    let recorded = try await repository.execute(
        command,
        on: id,
        metadata: metadata,
        using: handler
    )
    for event in recorded {
        await services.projectionPipeline.enqueue(event)
    }
    return recorded
}
