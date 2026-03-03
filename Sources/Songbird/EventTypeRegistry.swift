import Foundation

public enum EventTypeRegistryError: Error {
    case unregisteredEventType(String)
}

public final class EventTypeRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var decoders: [String: @Sendable (Data) throws -> any Event] = [:]

    public init() {}

    public func register<E: Event>(_ type: E.Type) {
        lock.lock()
        defer { lock.unlock() }
        decoders[E.eventType] = { data in
            try JSONDecoder().decode(E.self, from: data)
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
