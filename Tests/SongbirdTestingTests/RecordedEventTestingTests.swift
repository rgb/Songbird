import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

// Reusable test event for SongbirdTesting tests
enum TestWidgetEvent: Event {
    case created(name: String)
    case renamed(newName: String)

    var eventType: String {
        switch self {
        case .created: "WidgetCreated"
        case .renamed: "WidgetRenamed"
        }
    }
}

@Suite("RecordedEvent+Testing")
struct RecordedEventTestingTests {

    @Test func encodesTypedEventToRecordedEvent() throws {
        let event = TestWidgetEvent.created(name: "Sprocket")
        let recorded = try RecordedEvent(event: event)

        #expect(recorded.eventType == "WidgetCreated")
        // Round-trip: decode back to typed event
        let decoded = try recorded.decode(TestWidgetEvent.self).event
        #expect(decoded == TestWidgetEvent.created(name: "Sprocket"))
    }

    @Test func usesProvidedStreamName() throws {
        let stream = StreamName(category: "widget", id: "w-1")
        let recorded = try RecordedEvent(
            event: TestWidgetEvent.created(name: "Gear"),
            streamName: stream
        )
        #expect(recorded.streamName == stream)
    }

    @Test func usesProvidedPositions() throws {
        let recorded = try RecordedEvent(
            event: TestWidgetEvent.created(name: "Cog"),
            position: 5,
            globalPosition: 42
        )
        #expect(recorded.position == 5)
        #expect(recorded.globalPosition == 42)
    }

    @Test func usesProvidedMetadata() throws {
        let meta = EventMetadata(traceId: "trace-1", userId: "user-1")
        let recorded = try RecordedEvent(
            event: TestWidgetEvent.created(name: "Bolt"),
            metadata: meta
        )
        #expect(recorded.metadata == meta)
    }

    @Test func defaultsAreReasonable() throws {
        let recorded = try RecordedEvent(event: TestWidgetEvent.renamed(newName: "Widget2"))
        #expect(recorded.position == 0)
        #expect(recorded.globalPosition == 0)
        #expect(recorded.streamName == StreamName(category: "test", id: "1"))
        #expect(recorded.metadata == EventMetadata())
    }
}
