import Foundation
import Testing

@testable import Songbird
@testable import SongbirdTesting

// Test projector that records applied events
final class RecordingProjector: Projector, @unchecked Sendable {
    let projectorId: String
    private(set) var appliedEvents: [RecordedEvent] = []

    init(id: String = "recording") {
        self.projectorId = id
    }

    func apply(_ event: RecordedEvent) async throws {
        appliedEvents.append(event)
    }
}

// Test projector that only handles specific event types
final class FilteringProjector: Projector, @unchecked Sendable {
    let projectorId = "filtering"
    let acceptedTypes: Set<String>
    private(set) var appliedEvents: [RecordedEvent] = []

    init(acceptedTypes: Set<String>) {
        self.acceptedTypes = acceptedTypes
    }

    func apply(_ event: RecordedEvent) async throws {
        if acceptedTypes.contains(event.eventType) {
            appliedEvents.append(event)
        }
    }
}

// Test projector that throws on specific events
final class FailingProjector: Projector, @unchecked Sendable {
    let projectorId = "failing"
    let failOnType: String
    private(set) var appliedEvents: [RecordedEvent] = []

    init(failOnType: String) {
        self.failOnType = failOnType
    }

    func apply(_ event: RecordedEvent) async throws {
        if event.eventType == failOnType {
            throw ProjectorTestError.intentionalFailure
        }
        appliedEvents.append(event)
    }
}

enum ProjectorTestError: Error {
    case intentionalFailure
}

// Helper to create a RecordedEvent
func makeRecordedEvent(
    globalPosition: Int64,
    eventType: String = "TestEvent",
    streamName: StreamName = StreamName(category: "test", id: "1")
) -> RecordedEvent {
    RecordedEvent(
        id: UUID(),
        streamName: streamName,
        position: globalPosition,
        globalPosition: globalPosition,
        eventType: eventType,
        data: Data("{}".utf8),
        metadata: EventMetadata(),
        timestamp: Date()
    )
}

@Suite("ProjectionPipeline")
struct ProjectionPipelineTests {

    // MARK: - Basic Dispatch

    @Test func dispatchesEventsToRegisteredProjector() async throws {
        let projector = RecordingProjector()
        let pipeline = ProjectionPipeline()
        await pipeline.register(projector)

        let task = Task { await pipeline.run() }

        await pipeline.enqueue(makeRecordedEvent(globalPosition: 0))
        await pipeline.enqueue(makeRecordedEvent(globalPosition: 1))
        try await pipeline.waitForIdle()

        #expect(projector.appliedEvents.count == 2)

        await pipeline.stop()
        await task.value
    }

    @Test func dispatchesToMultipleProjectors() async throws {
        let p1 = RecordingProjector(id: "p1")
        let p2 = RecordingProjector(id: "p2")
        let pipeline = ProjectionPipeline()
        await pipeline.register(p1)
        await pipeline.register(p2)

        let task = Task { await pipeline.run() }

        await pipeline.enqueue(makeRecordedEvent(globalPosition: 0))
        try await pipeline.waitForIdle()

        #expect(p1.appliedEvents.count == 1)
        #expect(p2.appliedEvents.count == 1)

        await pipeline.stop()
        await task.value
    }

    @Test func projectorsCanFilterEvents() async throws {
        let allEvents = RecordingProjector(id: "all")
        let onlyDeposits = FilteringProjector(acceptedTypes: ["Deposited"])
        let pipeline = ProjectionPipeline()
        await pipeline.register(allEvents)
        await pipeline.register(onlyDeposits)

        let task = Task { await pipeline.run() }

        await pipeline.enqueue(makeRecordedEvent(globalPosition: 0, eventType: "Deposited"))
        await pipeline.enqueue(makeRecordedEvent(globalPosition: 1, eventType: "Withdrawn"))
        await pipeline.enqueue(makeRecordedEvent(globalPosition: 2, eventType: "Deposited"))
        try await pipeline.waitForIdle()

        #expect(allEvents.appliedEvents.count == 3)
        #expect(onlyDeposits.appliedEvents.count == 2)

        await pipeline.stop()
        await task.value
    }

    // MARK: - Error Handling

    @Test func projectionErrorDoesNotStopPipeline() async throws {
        let failing = FailingProjector(failOnType: "Bad")
        let recording = RecordingProjector()
        let pipeline = ProjectionPipeline()
        await pipeline.register(failing)
        await pipeline.register(recording)

        let task = Task { await pipeline.run() }

        await pipeline.enqueue(makeRecordedEvent(globalPosition: 0, eventType: "Good"))
        await pipeline.enqueue(makeRecordedEvent(globalPosition: 1, eventType: "Bad"))
        await pipeline.enqueue(makeRecordedEvent(globalPosition: 2, eventType: "Good"))
        try await pipeline.waitForIdle()

        // Recording projector got all 3 events despite failing projector throwing on "Bad"
        #expect(recording.appliedEvents.count == 3)
        // Failing projector got the 2 "Good" events
        #expect(failing.appliedEvents.count == 2)

        await pipeline.stop()
        await task.value
    }

    // MARK: - Waiter Pattern

    @Test func waitForProjectionReturnsImmediatelyWhenAlreadyProjected() async throws {
        let pipeline = ProjectionPipeline()
        await pipeline.register(RecordingProjector())
        let task = Task { await pipeline.run() }

        await pipeline.enqueue(makeRecordedEvent(globalPosition: 0))
        try await pipeline.waitForIdle()

        // This should return immediately since position 0 is already projected
        try await pipeline.waitForProjection(upTo: 0)

        await pipeline.stop()
        await task.value
    }

    @Test func waitForIdleWithNoEventsReturnsImmediately() async throws {
        let pipeline = ProjectionPipeline()
        // Nothing enqueued, should return immediately
        try await pipeline.waitForIdle()
    }

    @Test func waitForProjectionTimesOut() async throws {
        let pipeline = ProjectionPipeline()
        // Don't start run() -- nothing will ever be projected

        await #expect(throws: ProjectionPipelineError.self) {
            try await pipeline.waitForProjection(upTo: 99, timeout: .milliseconds(50))
        }
    }

    // MARK: - Position Tracking

    @Test func currentPositionTracksProjectedEvents() async throws {
        let pipeline = ProjectionPipeline()
        await pipeline.register(RecordingProjector())
        let task = Task { await pipeline.run() }

        let initialPos = await pipeline.currentPosition
        #expect(initialPos == -1)

        await pipeline.enqueue(makeRecordedEvent(globalPosition: 0))
        await pipeline.enqueue(makeRecordedEvent(globalPosition: 1))
        await pipeline.enqueue(makeRecordedEvent(globalPosition: 2))
        try await pipeline.waitForIdle()

        let finalPos = await pipeline.currentPosition
        #expect(finalPos == 2)

        await pipeline.stop()
        await task.value
    }

    // MARK: - Stop

    @Test func stopCausesRunToExit() async throws {
        let pipeline = ProjectionPipeline()
        await pipeline.register(RecordingProjector())
        let task = Task { await pipeline.run() }

        await pipeline.enqueue(makeRecordedEvent(globalPosition: 0))
        try await pipeline.waitForIdle()

        await pipeline.stop()
        await task.value  // Should complete without hanging
    }

    @Test func stopResumesWaiters() async throws {
        let pipeline = ProjectionPipeline()
        let task = Task { await pipeline.run() }

        // Start waiting for a position that will never be projected
        let waiterTask = Task {
            try await pipeline.waitForProjection(upTo: 99, timeout: .seconds(30))
        }

        // Give the waiter time to register
        try await Task.sleep(for: .milliseconds(50))

        // Stop should resume the waiter
        await pipeline.stop()
        await task.value

        // Waiter should complete without throwing
        try await waiterTask.value
    }
}
