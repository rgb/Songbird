/// An actor that runs an `Injector` by consuming its event sequence, appending each event
/// to the event store, and calling `didAppend` with the result.
///
/// The runner:
/// 1. Calls `injector.events()` to get the async sequence
/// 2. For each `InboundEvent`, appends it to the store with `expectedVersion: nil`
/// 3. Calls `injector.didAppend(_:result:)` with `.success` or `.failure`
/// 4. Exits when the sequence finishes (finite) or the enclosing `Task` is cancelled
///
/// Append errors do not stop the runner — they are passed back to the injector via
/// `didAppend` so the injector can decide how to handle them (retry, dead-letter, log, etc.).
///
/// Usage:
/// ```swift
/// let runner = InjectorRunner(injector: sqsInjector, store: eventStore)
///
/// let task = Task { try await runner.run() }
///
/// // Later: cancel stops the sequence loop (if the sequence respects cancellation)
/// task.cancel()
/// ```
public actor InjectorRunner<I: Injector> {
    private let injector: I
    private let store: any EventStore

    public init(injector: I, store: any EventStore) {
        self.injector = injector
        self.store = store
    }

    // MARK: - Lifecycle

    /// Starts the runner. Returns when the injector's sequence finishes.
    /// Throws if the sequence itself throws a terminal error.
    public func run() async throws {
        for try await inbound in injector.events() {
            let result: Result<RecordedEvent, any Error>
            do {
                let recorded = try await store.append(
                    inbound.event,
                    to: inbound.stream,
                    metadata: inbound.metadata,
                    expectedVersion: nil
                )
                result = .success(recorded)
            } catch {
                result = .failure(error)
            }
            await injector.didAppend(inbound, result: result)
        }
    }
}
