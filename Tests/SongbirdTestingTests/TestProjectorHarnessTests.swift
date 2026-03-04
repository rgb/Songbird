import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

@Suite("TestProjectorHarness")
struct TestProjectorHarnessTests {

    @Test func feedsTypedEventsToProjector() async throws {
        let projector = RecordingProjector()
        var harness = TestProjectorHarness(projector: projector)

        try await harness.given(TestWidgetEvent.created(name: "A"))
        try await harness.given(TestWidgetEvent.renamed(newName: "B"))

        let events = await projector.appliedEvents
        #expect(events.count == 2)
        #expect(events[0].eventType == "WidgetCreated")
        #expect(events[1].eventType == "WidgetRenamed")
    }

    @Test func incrementsGlobalPositionAutomatically() async throws {
        let projector = RecordingProjector()
        var harness = TestProjectorHarness(projector: projector)

        try await harness.given(TestWidgetEvent.created(name: "A"))
        try await harness.given(TestWidgetEvent.created(name: "B"))
        try await harness.given(TestWidgetEvent.created(name: "C"))

        let events = await projector.appliedEvents
        #expect(events[0].globalPosition == 0)
        #expect(events[1].globalPosition == 1)
        #expect(events[2].globalPosition == 2)
        #expect(harness.globalPosition == 3)
    }

    @Test func usesProvidedStreamName() async throws {
        let projector = RecordingProjector()
        var harness = TestProjectorHarness(projector: projector)

        let stream = StreamName(category: "widget", id: "w-1")
        try await harness.given(TestWidgetEvent.created(name: "A"), streamName: stream)

        let events = await projector.appliedEvents
        #expect(events[0].streamName == stream)
    }

    @Test func usesProvidedMetadata() async throws {
        let projector = RecordingProjector()
        var harness = TestProjectorHarness(projector: projector)

        let meta = EventMetadata(traceId: "trace-1")
        try await harness.given(TestWidgetEvent.created(name: "A"), metadata: meta)

        let events = await projector.appliedEvents
        #expect(events[0].metadata == meta)
    }

    @Test func roundTripsTypedEvents() async throws {
        let projector = RecordingProjector()
        var harness = TestProjectorHarness(projector: projector)

        try await harness.given(TestWidgetEvent.created(name: "Sprocket"))

        let events = await projector.appliedEvents
        let decoded = try events[0].decode(TestWidgetEvent.self).event
        #expect(decoded == TestWidgetEvent.created(name: "Sprocket"))
    }
}
