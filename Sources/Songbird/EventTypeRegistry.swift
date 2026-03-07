import Foundation
import Synchronization

public enum EventTypeRegistryError: Error, Equatable {
    case unregisteredEventType(String)
}

/// `EventTypeRegistry` is safe to read and write from any isolation domain.
///
/// All mutable state (`decoders`, `upcasts`) is protected by a `Mutex`.
/// Every read and write acquires the lock first, ensuring thread-safe access
/// from any isolation domain. The class is `final` to prevent subclasses
/// from breaking this invariant.
///
/// **Important:** All registration (`register`, `registerUpcast`) should happen
/// at startup before any calls to `decode`. The registry does not guarantee
/// atomicity between registration and concurrent decoding.
public final class EventTypeRegistry: Sendable {
    private struct State: Sendable {
        var decoders: [String: @Sendable (Data) throws -> any Event] = [:]
        var upcasts: [String: @Sendable (any Event) -> any Event] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    public func register<E: Event>(_ type: E.Type, eventTypes: [String]) {
        state.withLock { state in
            for eventType in eventTypes {
                state.decoders[eventType] = { data in
                    try JSONDecoder().decode(E.self, from: data)
                }
            }
        }
    }

    /// Registers an upcast transform between two consecutive event versions.
    ///
    /// This does three things:
    /// 1. Registers a decoder for the old event type string so stored events can be deserialized
    /// 2. Stores the upcast function keyed by the old event type string
    /// 3. Validates that `NewEvent.version == OldEvent.version + 1`
    ///
    /// The `oldEventType` parameter is the string that appears in the `eventType` column of
    /// stored events for the old version. This is needed because `eventType` is an instance
    /// property on `Event` — we can't get it from the metatype alone.
    ///
    /// ```swift
    /// registry.registerUpcast(
    ///     from: OrderPlaced_v1.self,
    ///     to: OrderPlaced_v2.self,
    ///     upcast: OrderPlacedUpcast_v1_v2(),
    ///     oldEventType: "OrderPlaced_v1"
    /// )
    /// ```
    public func registerUpcast<U: EventUpcast>(
        from oldType: U.OldEvent.Type,
        to newType: U.NewEvent.Type,
        upcast: U,
        oldEventType: String
    ) {
        precondition(
            U.NewEvent.version == U.OldEvent.version + 1,
            "Upcast version mismatch: \(U.OldEvent.self) is version \(U.OldEvent.version), " +
            "\(U.NewEvent.self) is version \(U.NewEvent.version), expected \(U.OldEvent.version + 1)"
        )

        state.withLock { state in
            // Register decoder for the old event type string
            state.decoders[oldEventType] = { data in
                try JSONDecoder().decode(U.OldEvent.self, from: data)
            }

            // Store the upcast transform keyed by the old event type string
            state.upcasts[oldEventType] = { @Sendable (event: any Event) -> any Event in
                guard let oldEvent = event as? U.OldEvent else {
                    // Registry misconfiguration: the decoder produced a type that doesn't match the upcast.
                    // This is a programming error, but we return the event unchanged rather than crashing.
                    return event
                }
                return upcast.upcast(oldEvent)
            }
        }
    }

    public func decode(_ recorded: RecordedEvent) throws -> any Event {
        let (decoder, allUpcasts) = state.withLock { state in
            (state.decoders[recorded.eventType], state.upcasts)
        }

        guard let decoder else {
            throw EventTypeRegistryError.unregisteredEventType(recorded.eventType)
        }

        var event = try decoder(recorded.data)

        // Walk the upcast chain until no more upcasts exist.
        // We snapshot the upcasts dictionary once above to avoid repeated locking.
        var currentEventType = recorded.eventType
        var visited: Set<String> = [currentEventType]
        while true {
            guard let upcastFn = allUpcasts[currentEventType] else { break }
            event = upcastFn(event)
            currentEventType = event.eventType
            guard visited.insert(currentEventType).inserted else {
                preconditionFailure("Upcast cycle detected at event type '\(currentEventType)'")
            }
        }

        return event
    }
}
