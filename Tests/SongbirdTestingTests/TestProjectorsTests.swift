import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

@Suite("TestProjectors")
struct TestProjectorsTests {

    // MARK: - RecordingProjector

    @Test func recordingProjectorRecordsAllEvents() async throws {
        let projector = RecordingProjector()
        let event = try RecordedEvent(event: TestWidgetEvent.created(name: "A"))
        try await projector.apply(event)
        let events = await projector.appliedEvents
        #expect(events.count == 1)
    }

    @Test func recordingProjectorUsesDefaultId() async {
        let projector = RecordingProjector()
        let id = await projector.projectorId
        #expect(id == "recording")
    }

    @Test func recordingProjectorUsesCustomId() async {
        let projector = RecordingProjector(id: "custom")
        let id = await projector.projectorId
        #expect(id == "custom")
    }

    // MARK: - FilteringProjector

    @Test func filteringProjectorRecordsOnlyMatchingTypes() async throws {
        let projector = FilteringProjector(acceptedTypes: ["WidgetCreated"])
        let created = try RecordedEvent(event: TestWidgetEvent.created(name: "A"))
        let renamed = try RecordedEvent(event: TestWidgetEvent.renamed(newName: "B"))
        try await projector.apply(created)
        try await projector.apply(renamed)
        let events = await projector.appliedEvents
        #expect(events.count == 1)
        #expect(events[0].eventType == "WidgetCreated")
    }

    @Test func filteringProjectorHasDefaultId() async {
        let projector = FilteringProjector(acceptedTypes: [])
        let id = await projector.projectorId
        #expect(id == "filtering")
    }

    // MARK: - FailingProjector

    @Test func failingProjectorThrowsOnMatchingType() async throws {
        let projector = FailingProjector(failOnType: "WidgetRenamed")
        let renamed = try RecordedEvent(event: TestWidgetEvent.renamed(newName: "X"))
        await #expect(throws: FailingProjectorError.self) {
            try await projector.apply(renamed)
        }
    }

    @Test func failingProjectorRecordsNonMatchingEvents() async throws {
        let projector = FailingProjector(failOnType: "WidgetRenamed")
        let created = try RecordedEvent(event: TestWidgetEvent.created(name: "Y"))
        try await projector.apply(created)
        let events = await projector.appliedEvents
        #expect(events.count == 1)
    }
}
