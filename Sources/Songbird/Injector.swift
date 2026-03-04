import Foundation

/// An inbound event arriving from an external source via an `Injector`.
///
/// Carries the typed event payload, the target stream, and metadata to be written
/// to the event store when the injector appends it.
public struct InboundEvent: Sendable {
    /// The domain event payload to append.
    public let event: any Event
    /// The target stream to append the event to.
    public let stream: StreamName
    /// Metadata to attach to the appended event.
    public let metadata: EventMetadata

    public init(event: any Event, stream: StreamName, metadata: EventMetadata) {
        self.event = event
        self.stream = stream
        self.metadata = metadata
    }
}

/// A boundary component for inbound side effects — pulling events from external sources
/// (webhooks, message queues, polling APIs, etc.) and injecting them into the event store.
///
/// Injectors are the inbound counterpart to `Gateway` (outbound). They produce an async
/// sequence of `InboundEvent` values and receive a callback after each append attempt,
/// allowing them to acknowledge messages or track failures.
///
/// Usage:
/// ```swift
/// actor SQSInjector: Injector {
///     let injectorId = "sqs-injector"
///
///     func events() -> AsyncThrowingStream<InboundEvent, Error> {
///         AsyncThrowingStream { continuation in
///             // poll SQS, yield InboundEvent values
///         }
///     }
///
///     func didAppend(_ event: InboundEvent, result: Result<RecordedEvent, any Error>) async {
///         if case .success = result {
///             // delete from SQS
///         }
///     }
/// }
/// ```
public protocol Injector: Sendable {
    /// The sequence type produced by `events()`. Must be an async throwing sequence of `InboundEvent`.
    associatedtype EventSequence: AsyncSequence & Sendable where EventSequence.Element == InboundEvent

    /// Unique identifier for this injector instance.
    var injectorId: String { get }

    /// Returns an async sequence of inbound events to inject into the store.
    ///
    /// The sequence may be finite (for batch import) or infinite (for continuous polling).
    /// `InjectorRunner.run()` returns when this sequence finishes.
    ///
    /// Must be `nonisolated` on actor conformances so that the runner can call it
    /// without entering the actor's executor.
    nonisolated func events() -> EventSequence

    /// Called by the runner after each append attempt, whether it succeeded or failed.
    ///
    /// Use this to acknowledge messages, track failures, or implement retry logic.
    /// Must be idempotent — the same event may be delivered more than once.
    func didAppend(_ event: InboundEvent, result: Result<RecordedEvent, any Error>) async
}
