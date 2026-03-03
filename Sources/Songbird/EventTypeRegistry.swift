import Foundation

public enum EventTypeRegistryError: Error {
    case unregisteredEventType(String)
}

/// `@unchecked Sendable` is justified because all mutable state (`decoders`) is protected
/// by an `NSLock`. Every read and write acquires the lock first, ensuring thread-safe access
/// from any isolation domain. The class is `final` to prevent subclasses from breaking this
/// invariant.
public final class EventTypeRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var decoders: [String: @Sendable (Data) throws -> any Event] = [:]

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

    public func decode(_ recorded: RecordedEvent) throws -> any Event {
        lock.lock()
        let decoder = decoders[recorded.eventType]
        lock.unlock()

        guard let decoder else {
            throw EventTypeRegistryError.unregisteredEventType(recorded.eventType)
        }
        return try decoder(recorded.data)
    }
}
