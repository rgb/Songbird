import Foundation
import Testing

@testable import Songbird

// MARK: - Test Event Types

enum ReactionTestEvent: Event {
    case occurred(id: String, value: Int)

    var eventType: String {
        switch self {
        case .occurred: "Occurred"
        }
    }
}

enum ReactionOutputEvent: Event {
    case reacted(id: String, doubled: Int)

    var eventType: String {
        switch self {
        case .reacted: "Reacted"
        }
    }
}

// MARK: - Test State

struct ReactionTestState: Sendable, Equatable {
    var total: Int
}

// MARK: - Test Reactors

/// Minimal reactor: implements 3 required methods, relies on defaults for decode and react.
enum OnOccurred: EventReaction {
    typealias PMState = ReactionTestState
    typealias Input = ReactionTestEvent

    static let eventTypes = ["Occurred"]

    static func route(_ event: ReactionTestEvent) -> String? {
        switch event {
        case .occurred(let id, _): id
        }
    }

    static func apply(_ state: ReactionTestState, _ event: ReactionTestEvent) -> ReactionTestState {
        switch event {
        case .occurred(_, let value): ReactionTestState(total: state.total + value)
        }
    }
}

/// Reactor that overrides react to produce output events.
enum OnOccurredWithReaction: EventReaction {
    typealias PMState = ReactionTestState
    typealias Input = ReactionTestEvent

    static let eventTypes = ["Occurred"]

    static func route(_ event: ReactionTestEvent) -> String? {
        switch event {
        case .occurred(let id, _): id
        }
    }

    static func apply(_ state: ReactionTestState, _ event: ReactionTestEvent) -> ReactionTestState {
        switch event {
        case .occurred(_, let value): ReactionTestState(total: state.total + value)
        }
    }

    static func react(_ state: ReactionTestState, _ event: ReactionTestEvent) -> [any Event] {
        switch event {
        case .occurred(let id, let value):
            [ReactionOutputEvent.reacted(id: id, doubled: value * 2)]
        }
    }
}

/// Reactor that returns nil from route to signal "not interested".
enum OnOccurredSkipper: EventReaction {
    typealias PMState = ReactionTestState
    typealias Input = ReactionTestEvent

    static let eventTypes = ["Occurred"]

    static func route(_ event: ReactionTestEvent) -> String? {
        switch event {
        case .occurred(let id, _):
            id.hasPrefix("skip-") ? nil : id
        }
    }

    static func apply(_ state: ReactionTestState, _ event: ReactionTestEvent) -> ReactionTestState {
        switch event {
        case .occurred(_, let value): ReactionTestState(total: state.total + value)
        }
    }
}

// MARK: - Tests

@Suite("EventReaction")
struct EventReactionTests {

    // MARK: - Protocol Conformance

    @Test func eventTypesReturnsRegisteredTypes() {
        #expect(OnOccurred.eventTypes == ["Occurred"])
    }

    @Test func routeReturnsEntityId() {
        let event = ReactionTestEvent.occurred(id: "entity-1", value: 10)
        #expect(OnOccurred.route(event) == "entity-1")
    }

    @Test func applyFoldsState() {
        let initial = ReactionTestState(total: 0)
        let event = ReactionTestEvent.occurred(id: "e1", value: 5)
        let result = OnOccurred.apply(initial, event)
        #expect(result == ReactionTestState(total: 5))
    }

    // MARK: - Default Implementations

    @Test func defaultDecodeWorksForCodableEvent() throws {
        let event = ReactionTestEvent.occurred(id: "e1", value: 42)
        let data = try JSONEncoder().encode(event)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "test", id: "e1"),
            position: 0,
            globalPosition: 0,
            eventType: "Occurred",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )
        let decoded = try OnOccurred.decode(recorded)
        #expect(decoded == event)
    }

    @Test func defaultReactReturnsEmptyArray() {
        let state = ReactionTestState(total: 10)
        let event = ReactionTestEvent.occurred(id: "e1", value: 5)
        let output = OnOccurred.react(state, event)
        #expect(output.isEmpty)
    }

    // MARK: - Overridden react

    @Test func overriddenReactProducesOutputEvents() {
        let state = ReactionTestState(total: 10)
        let event = ReactionTestEvent.occurred(id: "e1", value: 7)
        let output = OnOccurredWithReaction.react(state, event)
        #expect(output.count == 1)
        let reacted = output[0] as? ReactionOutputEvent
        #expect(reacted == ReactionOutputEvent.reacted(id: "e1", doubled: 14))
    }

    // MARK: - Route returning nil

    @Test func routeReturnsNilForSkippedEvents() {
        let event = ReactionTestEvent.occurred(id: "skip-123", value: 1)
        #expect(OnOccurredSkipper.route(event) == nil)
    }

    @Test func routeReturnsIdForNonSkippedEvents() {
        let event = ReactionTestEvent.occurred(id: "entity-1", value: 1)
        #expect(OnOccurredSkipper.route(event) == "entity-1")
    }

    // MARK: - AnyReaction Type Erasure

    @Test func anyReactionTryRouteReturnsRouteForMatchingEventType() throws {
        let event = ReactionTestEvent.occurred(id: "e1", value: 10)
        let data = try JSONEncoder().encode(event)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "test", id: "e1"),
            position: 0,
            globalPosition: 0,
            eventType: "Occurred",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let anyReaction = AnyReaction<ReactionTestState>(
            eventTypes: OnOccurred.eventTypes,
            categories: ["test"],
            tryRoute: { recorded in
                guard OnOccurred.eventTypes.contains(recorded.eventType) else { return nil }
                let event = try OnOccurred.decode(recorded)
                return OnOccurred.route(event)
            },
            handle: { state, recorded in
                let event = try OnOccurred.decode(recorded)
                let newState = OnOccurred.apply(state, event)
                let output = OnOccurred.react(newState, event)
                return (newState, output)
            }
        )

        let route = try anyReaction.tryRoute(recorded)
        #expect(route == "e1")
    }

    @Test func anyReactionTryRouteReturnsNilForNonMatchingEventType() throws {
        let event = ReactionTestEvent.occurred(id: "e1", value: 10)
        let data = try JSONEncoder().encode(event)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "test", id: "e1"),
            position: 0,
            globalPosition: 0,
            eventType: "SomeOtherType",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let anyReaction = AnyReaction<ReactionTestState>(
            eventTypes: OnOccurred.eventTypes,
            categories: ["test"],
            tryRoute: { recorded in
                guard OnOccurred.eventTypes.contains(recorded.eventType) else { return nil }
                let event = try OnOccurred.decode(recorded)
                return OnOccurred.route(event)
            },
            handle: { state, recorded in
                let event = try OnOccurred.decode(recorded)
                let newState = OnOccurred.apply(state, event)
                let output = OnOccurred.react(newState, event)
                return (newState, output)
            }
        )

        let route = try anyReaction.tryRoute(recorded)
        #expect(route == nil)
    }

    @Test func anyReactionHandleReturnsNewStateAndOutput() throws {
        let event = ReactionTestEvent.occurred(id: "e1", value: 10)
        let data = try JSONEncoder().encode(event)
        let recorded = RecordedEvent(
            id: UUID(),
            streamName: StreamName(category: "test", id: "e1"),
            position: 0,
            globalPosition: 0,
            eventType: "Occurred",
            data: data,
            metadata: EventMetadata(),
            timestamp: Date()
        )

        let anyReaction = AnyReaction<ReactionTestState>(
            eventTypes: OnOccurredWithReaction.eventTypes,
            categories: ["test"],
            tryRoute: { recorded in
                guard OnOccurredWithReaction.eventTypes.contains(recorded.eventType) else {
                    return nil
                }
                let event = try OnOccurredWithReaction.decode(recorded)
                return OnOccurredWithReaction.route(event)
            },
            handle: { state, recorded in
                let event = try OnOccurredWithReaction.decode(recorded)
                let newState = OnOccurredWithReaction.apply(state, event)
                let output = OnOccurredWithReaction.react(newState, event)
                return (newState, output)
            }
        )

        let initialState = ReactionTestState(total: 5)
        let (newState, output) = try anyReaction.handle(initialState, recorded)
        #expect(newState == ReactionTestState(total: 15))
        #expect(output.count == 1)
        #expect(
            (output[0] as? ReactionOutputEvent) == ReactionOutputEvent.reacted(
                id: "e1", doubled: 20))
    }
}
