import Foundation
import Testing

@testable import Songbird

struct CounterIncremented: Event {
    static let eventType = "CounterIncremented"
    let amount: Int
}

struct CounterDecremented: Event {
    static let eventType = "CounterDecremented"
    let amount: Int
    let reason: String
}

@Suite("Event")
struct EventTests {
    @Test func eventTypeIsAccessible() {
        #expect(CounterIncremented.eventType == "CounterIncremented")
        #expect(CounterDecremented.eventType == "CounterDecremented")
    }

    @Test func eventIsCodable() throws {
        let event = CounterIncremented(amount: 5)
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(CounterIncremented.self, from: data)
        #expect(event == decoded)
    }

    @Test func eventIsEquatable() {
        let a = CounterIncremented(amount: 5)
        let b = CounterIncremented(amount: 5)
        let c = CounterIncremented(amount: 10)
        #expect(a == b)
        #expect(a != c)
    }
}

@Suite("EventMetadata")
struct EventMetadataTests {
    @Test func defaultsToNil() {
        let meta = EventMetadata()
        #expect(meta.traceId == nil)
        #expect(meta.causationId == nil)
        #expect(meta.correlationId == nil)
        #expect(meta.userId == nil)
    }

    @Test func initWithValues() {
        let meta = EventMetadata(
            traceId: "trace-1",
            causationId: "cause-1",
            correlationId: "corr-1",
            userId: "user-1"
        )
        #expect(meta.traceId == "trace-1")
        #expect(meta.causationId == "cause-1")
        #expect(meta.correlationId == "corr-1")
        #expect(meta.userId == "user-1")
    }

    @Test func codableRoundTrip() throws {
        let meta = EventMetadata(traceId: "trace-1", userId: "user-1")
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(EventMetadata.self, from: data)
        #expect(meta == decoded)
    }

    @Test func equalityDiffersOnSingleField() {
        let a = EventMetadata(traceId: "t1", userId: "u1")
        let b = EventMetadata(traceId: "t1", userId: "u2")
        #expect(a != b)
    }
}

@Suite("RecordedEvent")
struct RecordedEventTests {
    @Test func decodesToTypedEnvelope() throws {
        let event = CounterIncremented(amount: 5)
        let data = try JSONEncoder().encode(event)
        let stream = StreamName(category: "counter", id: "abc")
        let now = Date()
        let id = UUID()

        let recorded = RecordedEvent(
            id: id,
            streamName: stream,
            position: 0,
            globalPosition: 42,
            eventType: CounterIncremented.eventType,
            data: data,
            metadata: EventMetadata(traceId: "t1"),
            timestamp: now
        )

        let envelope = try recorded.decode(CounterIncremented.self)
        #expect(envelope.id == id)
        #expect(envelope.streamName == stream)
        #expect(envelope.position == 0)
        #expect(envelope.globalPosition == 42)
        #expect(envelope.event == event)
        #expect(envelope.metadata.traceId == "t1")
        #expect(envelope.timestamp == now)
    }

    @Test func decodeThrowsForWrongType() throws {
        let event = CounterIncremented(amount: 5)
        let data = try JSONEncoder().encode(event)

        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "counter", id: "abc"),
            position: 0,
            globalPosition: 0,
            eventType: CounterIncremented.eventType,
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        #expect(throws: (any Error).self) {
            _ = try recorded.decode(CounterDecremented.self)
        }
    }

    @Test func decodeThrowsForCorruptedJSON() {
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "counter", id: "abc"),
            position: 0,
            globalPosition: 0,
            eventType: CounterIncremented.eventType,
            data: Data("not valid json".utf8),
            metadata: EventMetadata(),
            timestamp: Date()
        )

        #expect(throws: (any Error).self) {
            _ = try recorded.decode(CounterIncremented.self)
        }
    }
}

@Suite("EventEnvelope")
struct EventEnvelopeTests {
    @Test func preservesAllFields() {
        let id = UUID()
        let stream = StreamName(category: "counter", id: "x")
        let now = Date()
        let meta = EventMetadata(traceId: "t1", userId: "u1")
        let event = CounterIncremented(amount: 7)

        let envelope = EventEnvelope(
            id: id,
            streamName: stream,
            position: 3,
            globalPosition: 42,
            event: event,
            metadata: meta,
            timestamp: now
        )

        #expect(envelope.id == id)
        #expect(envelope.streamName == stream)
        #expect(envelope.position == 3)
        #expect(envelope.globalPosition == 42)
        #expect(envelope.event == event)
        #expect(envelope.event.amount == 7)
        #expect(envelope.metadata.traceId == "t1")
        #expect(envelope.metadata.userId == "u1")
        #expect(envelope.timestamp == now)
    }
}
