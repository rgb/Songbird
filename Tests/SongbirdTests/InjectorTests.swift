import Foundation
import Testing

@testable import Songbird

private struct ExternalEvent: Event {
    var eventType: String { "ExternalEvent" }
}

private actor TestInjector: Injector {
    let injectorId = "test-injector"
    private(set) var appendResults: [Result<RecordedEvent, any Error>] = []

    nonisolated func events() -> AsyncThrowingStream<InboundEvent, Error> {
        AsyncThrowingStream<InboundEvent, Error> { continuation in
            continuation.yield(InboundEvent(
                event: ExternalEvent(),
                stream: StreamName(category: "external", id: "1"),
                metadata: EventMetadata()
            ))
            continuation.finish()
        }
    }

    func didAppend(_ event: InboundEvent, result: Result<RecordedEvent, any Error>) {
        appendResults.append(result)
    }
}

@Suite("Injector")
struct InjectorTests {
    @Test func injectorHasId() {
        let injector = TestInjector()
        #expect(injector.injectorId == "test-injector")
    }

    @Test func inboundEventHoldsValues() {
        let event = InboundEvent(
            event: ExternalEvent(),
            stream: StreamName(category: "external", id: "1"),
            metadata: EventMetadata()
        )
        #expect(event.stream.category == "external")
        #expect(event.stream.id == "1")
    }
}
