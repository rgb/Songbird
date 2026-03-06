import Foundation

public enum EventTypeRegistryError: Error, Equatable {
    case unregisteredEventType(String)
}

/// `@unchecked Sendable` is justified because all mutable state (`decoders`, `upcasts`)
/// is protected by an `NSLock`. Every read and write acquires the lock first, ensuring
/// thread-safe access from any isolation domain. The class is `final` to prevent subclasses
/// from breaking this invariant.
public final class EventTypeRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var decoders: [String: @Sendable (Data) throws -> any Event] = [:]
    private var upcasts: [String: @Sendable (any Event) -> any Event] = [:]

    public init() {}

    public func register<E: Event>(_ type: E.Type, eventTypes: [String]) {
        lock.lock()
        defer { lock.unlock() }
        for eventType in eventTypes {
            decoders[eventType] = { data in
                try JSONDecoder().decode(E.self, from: data)
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

        lock.lock()
        defer { lock.unlock() }

        // Register decoder for the old event type string
        decoders[oldEventType] = { data in
            try JSONDecoder().decode(U.OldEvent.self, from: data)
        }

        // Store the upcast transform keyed by the old event type string
        upcasts[oldEventType] = { @Sendable (event: any Event) -> any Event in
            guard let oldEvent = event as? U.OldEvent else {
                // Registry misconfiguration: the decoder produced a type that doesn't match the upcast.
                // This is a programming error, but we return the event unchanged rather than crashing.
                return event
            }
            return upcast.upcast(oldEvent)
        }
    }

    public func decode(_ recorded: RecordedEvent) throws -> any Event {
        lock.lock()
        let decoder = decoders[recorded.eventType]
        lock.unlock()

        guard let decoder else {
            throw EventTypeRegistryError.unregisteredEventType(recorded.eventType)
        }

        var event = try decoder(recorded.data)

        // Walk the upcast chain until no more upcasts exist.
        // After each upcast, look up the next using the new event's eventType.
        lock.lock()
        var nextUpcast = upcasts[recorded.eventType]
        lock.unlock()

        while let upcastFn = nextUpcast {
            event = upcastFn(event)

            let newEventType = event.eventType
            lock.lock()
            nextUpcast = upcasts[newEventType]
            lock.unlock()
        }

        return event
    }
}
