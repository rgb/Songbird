import Songbird

public actor PlaybackInjector: Injector {
    public let injectorId = "Playback"

    private nonisolated let _events: AsyncStream<InboundEvent>
    private let continuation: AsyncStream<InboundEvent>.Continuation

    /// Events that were successfully appended, tracked for observability.
    public private(set) var appendedCount: Int = 0

    public init() {
        let (stream, continuation) = AsyncStream.makeStream(of: InboundEvent.self)
        self._events = stream
        self.continuation = continuation
    }

    public nonisolated func events() -> AsyncStream<InboundEvent> {
        _events
    }

    public func didAppend(
        _ event: InboundEvent,
        result: Result<RecordedEvent, any Error>
    ) async {
        if case .success = result {
            appendedCount += 1
        }
    }

    /// Called by the HTTP route to inject a playback event.
    public func inject(_ event: InboundEvent) {
        continuation.yield(event)
    }
}
